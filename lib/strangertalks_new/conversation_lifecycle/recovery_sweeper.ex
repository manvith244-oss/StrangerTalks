defmodule StrangertalksNew.ConversationLifecycle.RecoverySweeper do
  @moduledoc """
  Supervised background sweeper that cleans up orphaned Conversations where
  no participant has returned to trigger on-demand SessionReconciliation.

  PENDING Conversations use an age threshold because they may still be in the
  normal match-to-Conversation handoff. ACTIVE/PAUSED Conversations already
  crossed that boundary; when their canonical ConversationServer is absent at
  sweep time they are restart orphans and must not remain durably live forever.
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

    runtime_orphan_query =
      from c in Conversation,
        where: c.conversation_status in [:ACTIVE, :PAUSED]

    Repo.all(pending_query)
    |> Enum.each(&maybe_resolve_pending_orphan(&1, cutoff_pending))

    Repo.all(runtime_orphan_query)
    |> Enum.each(&maybe_resolve_runtime_orphan/1)

    :ok
  end

  defp maybe_resolve_pending_orphan(conv, cutoff_pending) do
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
                  emit_authority_disagreement(:PENDING, :not_started, :pending_orphan)
                  resolve_orphan(current, :pending_orphan)
                else
                  :ok
                end

              _current_or_missing ->
                :ok
            end
          end
        )
    end
  end

  defp maybe_resolve_runtime_orphan(conv) do
    case ConversationServer.lookup(conv.conversation_id) do
      {:ok, _pid} ->
        :ok

      {:error, :not_started} ->
        ParticipantActivityLock.with_participants(
          [conv.participant_a_id, conv.participant_b_id],
          fn ->
            case Repo.get(Conversation, conv.conversation_id) do
              %Conversation{conversation_status: status} = current
              when status in [:ACTIVE, :PAUSED] ->
                if ConversationServer.lookup(current.conversation_id) ==
                     {:error, :not_started} do
                  emit_authority_disagreement(status, :not_started, :runtime_orphan)
                  resolve_orphan(current, :runtime_orphan)
                else
                  :ok
                end

              _current_or_missing ->
                :ok
            end
          end
        )
    end
  end

  defp resolve_orphan(conversation, recovery_kind) do
    case Transitions.transition(conversation, :recovery_timeout) do
      {:ok, _updated} ->
        # A runtime can start in the narrow interval between the final lookup
        # above and durable terminalization. Once the database transition wins,
        # terminal truth must win too: remove any runtime that registered from
        # the pre-terminal snapshot. A runtime starting after this transition
        # re-reads the terminal row in init/1 and refuses to start.
        terminate_runtime_if_running(conversation.conversation_id)

        StrangertalksNew.Telemetry.execute(
          [:recovery, :orphan_resolved],
          %{count: 1},
          %{recovery_kind: recovery_kind}
        )

        :ok

      {:error, reason} ->
        StrangertalksNew.Telemetry.failure(
          [:recovery, :failed],
          reason,
          %{recovery_kind: recovery_kind}
        )

        Logger.warning("RecoverySweeper failed to resolve orphan",
          recovery_kind: recovery_kind,
          reason_code: StrangertalksNew.DomainError.from_error(reason).code
        )

        :ok
    end
  end

  defp terminate_runtime_if_running(conversation_id) do
    case ConversationServer.lookup(conversation_id) do
      {:ok, pid} ->
        emit_authority_disagreement(:terminal, :running, :post_terminal_race)

        case DynamicSupervisor.terminate_child(
               StrangertalksNew.ConversationDynamicSupervisor,
               pid
             ) do
          :ok ->
            StrangertalksNew.Telemetry.execute(
              [:terminal, :runtime_cleanup],
              %{count: 1},
              %{terminal_reason: :recovery_timeout, cleanup_path: :recovery_sweeper}
            )

            :ok

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            StrangertalksNew.Telemetry.failure(
              [:terminal, :runtime_cleanup_failed],
              reason,
              %{cleanup_path: :recovery_sweeper}
            )

            Logger.warning("RecoverySweeper could not terminate terminal runtime",
              recovery_kind: :terminal_runtime_cleanup,
              reason_code: StrangertalksNew.DomainError.from_error(reason).code
            )

            :ok
        end

      {:error, :not_started} ->
        :ok
    end
  end

  defp emit_authority_disagreement(durable_status, runtime_status, detection_path) do
    StrangertalksNew.Telemetry.execute(
      [:terminal, :authority_disagreement],
      %{count: 1},
      %{
        durable_status: durable_status,
        runtime_status: runtime_status,
        detection_path: detection_path
      }
    )
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
