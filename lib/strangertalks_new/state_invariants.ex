defmodule StrangertalksNew.StateInvariants do
  @moduledoc """
  Authoritative cross-layer consistency invariant checker for StrangerTalks.
  Validates consistency across PostgreSQL durable records, OTP live processes,
  and volatile QueueState memory.
  """

  import Ecto.Query, warn: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  require Logger

  @terminal_statuses [:ENDED, :ABANDONED, :FAILED, :COMPLETED]
  @non_terminal_statuses [:PENDING, :ACTIVE, :PAUSED]

  @doc """
  Audits consistency invariants for a participant.
  Returns `:ok` or `{:violation, reason, details}`.
  """
  def check_participant(participant_id) when is_binary(participant_id) do
    query =
      from c in Conversation,
        where:
          c.conversation_status in @non_terminal_statuses and
            (c.participant_a_id == ^participant_id or c.participant_b_id == ^participant_id),
        order_by: [desc: c.created_at]

    conversations = Repo.all(query)
    queue_entry = Agent.get(QueueState, fn state -> Map.get(state, participant_id) end)

    cond do
      # Invariant 2: No more than one non-terminal conversation
      length(conversations) > 1 ->
        conv_ids = Enum.map(conversations, & &1.conversation_id)
        log_violation(:multiple_active_conversations)
        emit_violation(:participant)
        {:violation, :multiple_active_conversations, %{conversation_ids: conv_ids}}

      # Invariant 1: Queue vs Conversation exclusivity
      conversations != [] and queue_entry != nil ->
        [active | _] = conversations
        log_violation(:queue_conversation_conflict)
        emit_violation(:participant)

        {:violation, :queue_conversation_conflict,
         %{conversation_id: active.conversation_id, queue_entry: queue_entry}}

      true ->
        :ok
    end
  end

  @doc """
  Audits consistency invariants for a conversation.
  Returns `:ok` or `{:violation, reason, details}`.
  """
  def check_conversation(conversation_id) when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        # Invariant 4: Live process without DB row
        case ConversationServer.lookup(conversation_id) do
          {:ok, _pid} ->
            log_violation(:missing_durable_conversation)
            emit_violation(:conversation)
            {:violation, :missing_durable_conversation, %{conversation_id: conversation_id}}

          {:error, :not_started} ->
            :ok
        end

      %Conversation{} = conv ->
        check_conversation_struct(conv)
    end
  end

  defp check_conversation_struct(%Conversation{} = conv) do
    id = conv.conversation_id
    status = conv.conversation_status

    cond do
      # Invariant 3: Terminal DB state beats runtime
      status in @terminal_statuses ->
        case ConversationServer.lookup(id) do
          {:ok, _pid} ->
            log_violation(:terminal_process_conflict, status)
            emit_violation(:conversation)
            {:violation, :terminal_process_conflict, %{conversation_id: id, status: status}}

          {:error, :not_started} ->
            check_lifecycle_metadata(conv)
        end

      # Invariant 12: Lifecycle metadata consistency for non-terminal
      status in @non_terminal_statuses ->
        check_lifecycle_metadata(conv)

      true ->
        :ok
    end
  end

  defp check_lifecycle_metadata(
         %Conversation{conversation_status: status, ended_at: ended_at} = conv
       ) do
    id = conv.conversation_id

    cond do
      status in @terminal_statuses and is_nil(ended_at) ->
        log_violation(:missing_terminal_timestamp, status)
        emit_violation(:conversation)
        {:violation, :missing_terminal_timestamp, %{conversation_id: id, status: status}}

      status in @non_terminal_statuses and not is_nil(ended_at) ->
        log_violation(:invalid_active_ended_timestamp, status)
        emit_violation(:conversation)
        {:violation, :invalid_active_ended_timestamp, %{conversation_id: id, status: status}}

      true ->
        :ok
    end
  end

  defp log_violation(invariant, lifecycle_status \\ :unknown) do
    Logger.warning("StateInvariant violation detected",
      invariant: invariant,
      lifecycle_status: lifecycle_status,
      reason_code: "INTERNAL_ERROR"
    )
  end

  defp emit_violation(operation) do
    StrangertalksNew.Telemetry.failure(
      [:invariant, :check, :failed],
      :internal_error,
      %{operation: operation}
    )
  end
end
