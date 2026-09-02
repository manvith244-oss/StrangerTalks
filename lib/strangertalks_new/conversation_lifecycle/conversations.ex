# filepath: lib/strangertalks_new/conversation_lifecycle/conversations.ex
defmodule StrangertalksNew.ConversationLifecycle.Conversations do
  @moduledoc """
  Exposes exactly the three mandatory public context functions defined in Section 6
  of the Engineering Constitution for managing conversation lifecycle records.
  """

  alias StrangertalksNew.Repo
  alias StrangertalksNew.Conversations, as: CanonicalConversations
  alias StrangertalksNew.Conversation

  @spec create_conversation(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create_conversation(attrs \\ %{}), do: CanonicalConversations.create_conversation(attrs)

  @spec get_conversation(binary()) :: Conversation.t() | nil
  def get_conversation(conversation_id) do
    Repo.get(Conversation, conversation_id)
  end

  @spec change_conversation(Conversation.t(), map()) :: Ecto.Changeset.t()
  def change_conversation(%Conversation{} = conversation, attrs \\ %{}) do
    Conversation.changeset(conversation, attrs)
  end
end
