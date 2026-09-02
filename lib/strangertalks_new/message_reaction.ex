defmodule StrangertalksNew.MessageReaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:message_reaction_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_reactions" do
    field :emoji_unicode, :string
    field :lifecycle_action, Ecto.Enum, values: [:ATTACH, :DETACH]

    # Manual microsecond tracking fields
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    # Belongs_to definitions referencing proper target custom keys
    belongs_to :message, StrangertalksNew.Message,
      foreign_key: :message_id,
      references: :message_id

    belongs_to :participant, StrangertalksNew.Participant,
      foreign_key: :participant_id,
      references: :participant_id
  end

  def changeset(message_reaction, attrs) do
    message_reaction
    |> cast(attrs, [
      :message_id,
      :participant_id,
      :emoji_unicode,
      :lifecycle_action,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :message_id,
      :participant_id,
      :emoji_unicode,
      :lifecycle_action,
      :created_at,
      :updated_at
    ])
    |> unique_constraint([:message_id, :participant_id],
      name: :message_reactions_message_id_participant_id_index
    )
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:participant_id)
  end
end
