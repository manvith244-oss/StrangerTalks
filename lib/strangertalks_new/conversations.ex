defmodule StrangertalksNew.Conversations do
  import Ecto.Query, warn: false

  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Conversation

  def get_conversation(conversation_id) do
    Repo.get(Conversation, conversation_id)
  end

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
