defmodule StrangertalksNew.SessionReconciliation do
  @moduledoc """
  Authoritative single-node V1 participant session and state reconciliation.
  Reconciles PostgreSQL durable records, OTP volatile runtime state, and active
  Conversation processes to determine canonical reality for any participant.
  """

  import Ecto.Query, warn: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  @orphaned_grace_seconds 60

  @type canonical_state :: :AVAILABLE | :QUEUED | :CONVERSATION

  @type snapshot :: %{
          participant_id: String.t(),
          canonical_state: canonical_state(),
          queue: map() | nil,
          conversation: map() | nil,
          reconciled: boolean()
        }

  @doc """
  Deterministically reconciles durable database state and live OTP state
  for a given participant UUID within an activity serialization lock.
  Returns `{:ok, snapshot}` or `{:error, domain_error_term}`.
  """
  @spec reconcile(String.t()) :: {:ok, snapshot()} | {:error, term()}
  def reconcile(participant_id) when is_binary(participant_id) do
    ParticipantActivityLock.with_participants([participant_id], fn ->
      do_reconcile(participant_id)
    end)
  end

  defp do_reconcile(participant_id) do
    query =
      from c in Conversation,
        where:
          c.conversation_status in [:PENDING, :ACTIVE, :PAUSED] and
            (c.participant_a_id == ^participant_id or c.participant_b_id == ^participant_id),
        order_by: [desc: c.created_at]

    conversations = Repo.all(query)
    {active_conversations, orphaned_count} = evaluate_conversations(conversations)
    reconciled? = orphaned_count > 0

    # Cross-layer invariant check
    _ = StrangertalksNew.StateInvariants.check_participant(participant_id)

    case active_conversations do
      [active_conv] ->
        # Invariant 1 & 6: Exactly one legitimate active/recoverable conversation.
        cleanup_queue_if_present(participant_id)

        participant_door = participant_door(active_conv, participant_id)
        match = Repo.get!(StrangertalksNew.Matching, active_conv.match_id)

        {:ok,
         %{
           participant_id: participant_id,
           canonical_state: :CONVERSATION,
           queue: nil,
           conversation: %{
             conversation_id: active_conv.conversation_id,
             door_type: Atom.to_string(participant_door),
             conversation_language: match.conversation_language,
             status: Atom.to_string(active_conv.conversation_status)
           },
           reconciled: reconciled?
         }}

      [_ | _] = multiple ->
        # Invariant 2 violation: Multiple non-terminal conversations exist.
        # Perform NO lifecycle mutation, NO queue cleanup, select NO conversation.
        require Logger

        Logger.error("Multiple active conversations invariant violation",
          invariant: :multiple_active_conversations,
          active_conversation_count: length(multiple)
        )

        {:error, :multiple_active_conversations}

      [] ->
        # No active conversation. Check volatile queue state.
        case get_queue_entry(participant_id) do
          %{door_selection: door} = entry ->
            {:ok,
             %{
               participant_id: participant_id,
               canonical_state: :QUEUED,
               queue: %{
                 door_type: Atom.to_string(door),
                 conversation_language: Map.get(entry, :conversation_language),
                 entry_time: Map.get(entry, :queue_entry_time),
                 queue_attempt_id: Map.fetch!(entry, :queue_attempt_id)
               },
               conversation: nil,
               reconciled: reconciled?
             }}

          nil ->
            {:ok,
             %{
               participant_id: participant_id,
               canonical_state: :AVAILABLE,
               queue: nil,
               conversation: nil,
               reconciled: reconciled?
             }}
        end
    end
  end

  defp participant_door(conversation, participant_id) do
    match = Repo.get!(StrangertalksNew.Matching, conversation.match_id)

    cond do
      match.participant_a_id == participant_id -> match.participant_a_door_type
      match.participant_b_id == participant_id -> match.participant_b_door_type
      true -> conversation.door_type
    end
  end

  defp evaluate_conversations(conversations) do
    Enum.reduce(conversations, {[], 0}, fn conv, {active_acc, orphan_count} ->
      if orphaned?(conv) do
        abandon_orphaned_conversation(conv)
        {active_acc, orphan_count + 1}
      else
        {[conv | active_acc], orphan_count}
      end
    end)
  end

  defp orphaned?(%Conversation{conversation_status: :PENDING} = conversation) do
    case ConversationServer.lookup(conversation.conversation_id) do
      {:ok, _pid} ->
        false

      {:error, :not_started} ->
        cutoff = DateTime.utc_now() |> DateTime.add(-@orphaned_grace_seconds, :second)
        created_at = conversation.created_at || DateTime.utc_now()
        DateTime.compare(created_at, cutoff) == :lt
    end
  end

  defp orphaned?(%Conversation{conversation_status: status} = conversation)
       when status in [:ACTIVE, :PAUSED] do
    case ConversationServer.ensure_started(conversation.conversation_id) do
      {:ok, _pid} ->
        false

      {:error, _reason} ->
        true
    end
  end

  defp orphaned?(_conversation), do: true

  defp abandon_orphaned_conversation(%Conversation{} = conversation) do
    case StrangertalksNew.ConversationLifecycle.Transitions.transition(
           conversation,
           :recovery_timeout
         ) do
      {:ok, updated} ->
        StrangertalksNew.Telemetry.execute(
          [:recovery, :orphan_resolved],
          %{count: 1},
          %{recovery_kind: :on_demand_reconciliation}
        )

        {:ok, updated}

      {:error, reason} ->
        StrangertalksNew.Telemetry.failure(
          [:recovery, :failed],
          reason,
          %{recovery_kind: :on_demand_reconciliation}
        )

        {:error, reason}
    end
  end

  defp get_queue_entry(participant_id) do
    Agent.get(QueueState, fn state -> Map.get(state, participant_id) end)
  end

  defp cleanup_queue_if_present(participant_id) do
    removed_entry =
      Agent.get_and_update(QueueState, fn state ->
        case Map.pop(state, participant_id) do
          {nil, state} -> {nil, state}
          {entry, new_state} -> {entry, new_state}
        end
      end)

    if removed_entry do
      case removed_entry do
        %{queue_entry_monotonic: started_at, door_selection: door_type}
        when is_integer(started_at) ->
          StrangertalksNew.Telemetry.execute(
            [:queue, :residence],
            %{duration: System.monotonic_time() - started_at},
            %{leave_reason: :reconciliation_cleanup, door_type: door_type}
          )

        _entry ->
          :ok
      end

      StrangertalksNew.Telemetry.execute(
        [:queue, :left],
        %{count: 1},
        %{
          leave_reason: :reconciliation_cleanup,
          door_type: removed_entry.door_selection
        }
      )
    end

    :ok
  end
end
