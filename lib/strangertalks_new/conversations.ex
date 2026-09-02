defmodule StrangertalksNew.Conversations do
  import Ecto.Query, warn: false

  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Conversation

  @terminal_statuses [:ENDED, :ABANDONED, :FAILED, :COMPLETED]

  def get_conversation(conversation_id) do
    Repo.get(Conversation, conversation_id)
  end

  def terminal_truth(conversation_id) when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> {:error, :conversation_not_found}
      conversation -> terminal_truth(conversation)
    end
  end

  def terminal_truth(%Conversation{conversation_status: status} = conversation)
      when status in @terminal_statuses do
    {:ok,
     %{
       conversation_id: conversation.conversation_id,
       conversation_status: conversation.conversation_status,
       ending_type: conversation.ending_type,
       ending_initiator: conversation.ending_initiator,
       ended_at: conversation.ended_at,
       conversation_completed: conversation.conversation_completed,
       safety_flagged: conversation.safety_flagged,
       client_event: %{
         status: "ended",
         reason: terminal_reason(conversation)
       }
     }}
  end

  def terminal_truth(%Conversation{}), do: {:error, :conversation_not_terminal}

  def create_conversation(attrs \\ %{}) do
    changeset = Conversation.changeset(%Conversation{}, attrs)
    status = Ecto.Changeset.get_field(changeset, :conversation_status)
    participant_ids = participants(changeset)

    if status in [:PENDING, :ACTIVE, :PAUSED] and length(participant_ids) == 2 do
      ParticipantActivityLock.with_participants(participant_ids, fn ->
        if participants_available?(participant_ids) do
          Repo.insert(changeset)
        else
          {:error, Ecto.Changeset.add_error(changeset, :conversation_status, "participants busy")}
        end
      end)
    else
      Repo.insert(changeset)
    end
  end

  def change_conversation(%Conversation{} = conversation, attrs \\ %{}) do
    Conversation.changeset(conversation, attrs)
  end

  defp terminal_reason(%Conversation{ending_type: :BLOCK}), do: "blocked"
  defp terminal_reason(%Conversation{ending_type: :NATURAL_END}), do: "participant_completed"

  defp terminal_reason(%Conversation{ending_type: :PARTICIPANT_LEFT}),
    do: "left_during_transition"

  defp terminal_reason(%Conversation{ending_type: :TIMEOUT}), do: "conversation_abandoned"
  defp terminal_reason(%Conversation{ending_type: :DISCONNECT}), do: "initialization_failed"
  defp terminal_reason(%Conversation{ending_type: :SAFETY_ACTION}), do: "safety_terminated"
  defp terminal_reason(%Conversation{conversation_status: :COMPLETED}), do: "completed"

  defp terminal_reason(%Conversation{ending_type: ending_type}) when not is_nil(ending_type) do
    ending_type
    |> Atom.to_string()
    |> String.downcase()
  end

  defp terminal_reason(%Conversation{conversation_status: status}) do
    status
    |> Atom.to_string()
    |> String.downcase()
  end

  defp participants(changeset) do
    [:participant_a_id, :participant_b_id]
    |> Enum.map(&Ecto.Changeset.get_field(changeset, &1))
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.uniq()
  end

  defp participants_available?(participant_ids) do
    not Enum.any?(participant_ids, &queued?/1) and
      not Repo.exists?(
        from c in Conversation,
          where:
            c.conversation_status in [:PENDING, :ACTIVE, :PAUSED] and
              (c.participant_a_id in ^participant_ids or c.participant_b_id in ^participant_ids)
      )
  end

  defp queued?(participant_id), do: Agent.get(QueueState, &Map.has_key?(&1, participant_id))
end
