defmodule StrangertalksNew.Conversations do
  alias StrangertalksNew.Repo
  alias StrangertalksNew.Conversation

  def get_conversation(conversation_id) do
    Repo.get(Conversation, conversation_id)
  end

  def create_conversation(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def change_conversation(%Conversation{} = conversation, attrs \\ %{}) do
    Conversation.changeset(conversation, attrs)
  end
end
