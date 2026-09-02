defmodule StrangertalksNew.MessageReactions do
  import Ecto.Query, warn: false
  alias StrangertalksNew.Repo
  alias StrangertalksNew.MessageReaction

  def create_message_reaction(attrs \\ %{}) do
    %MessageReaction{}
    |> MessageReaction.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:emoji_unicode, :lifecycle_action, :updated_at]},
      conflict_target: [:message_id, :participant_id],
      returning: true
    )
  end

  def get_message_reaction(id) do
    Repo.get(MessageReaction, id)
  end

  def change_message_reaction(%MessageReaction{} = message_reaction, attrs \\ %{}) do
    MessageReaction.changeset(message_reaction, attrs)
  end
end
