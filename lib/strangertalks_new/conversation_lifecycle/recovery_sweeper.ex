defmodule StrangertalksNew.ConversationLifecycle.RecoverySweeper do
  @moduledoc """
  Supervised background sweeper that cleans up orphaned Conversations where
  no participant has returned to trigger on-demand SessionReconciliation.
  """

  use GenServer

  import Ecto.Query, warn: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.Transitions
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.Repo

  require Logger

  @sweep_interval_ms 60_000
  @orphaned_pending_seconds 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_orphans()
    schedule_sweep()
    {:noreply, state}
  end

  def sweep_orphans do
    now = DateTime.utc_now()
    cutoff_pending = DateTime.add(now, -@orphaned_pending_seconds, :second)

    pending_query =
      from c in Conversation,
        where:
          c.conversation_status == :PENDING and
            c.created_at < ^cutoff_pending

    pending_orphans = Repo.all(pending_query)

    Enum.each(pending_orphans, fn conv ->
      case ConversationServer.lookup(conv.conversation_id) do
        {:ok, _pid} ->
          :ok

        {:error, :not_started} ->
          ParticipantActivityLock.with_participants(
            [conv.participant_a_id, conv.participant_b_id],
            fn ->
              case Repo.get(Conversation, conv.conversation_id) do
                %Conversation{conversation_status: :PENDING, created_at: created_at} = current
                when not is_nil(created_at) ->
                  if DateTime.compare(created_at, cutoff_pending) == :lt and
                       ConversationServer.lookup(current.conversation_id) ==
                         {:error, :not_started} do
                    resolve_orphan(current)
                  end

                _current_or_missing ->
                  :ok
              end
            end
          )
      end
    end)
  end

  defp resolve_orphan(conversation) do
    case Transitions.transition(conversation, :recovery_timeout) do
      {:ok, _updated} ->
        StrangertalksNew.Telemetry.execute(
          [:recovery, :orphan_resolved],
          %{count: 1},
          %{recovery_kind: :pending_orphan}
        )

      {:error, reason} ->
        StrangertalksNew.Telemetry.failure(
          [:recovery, :failed],
          reason,
          %{recovery_kind: :pending_orphan}
        )

        Logger.warning("RecoverySweeper failed to resolve orphan",
          recovery_kind: :pending_orphan,
          reason_code: StrangertalksNew.DomainError.from_error(reason).code
        )
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
