defmodule StrangertalksNew.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:message_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    belongs_to :conversation, StrangertalksNew.Conversation,
      foreign_key: :conversation_id,
      references: :conversation_id,
      type: :binary_id

    belongs_to :sender, StrangertalksNew.Participant,
      foreign_key: :sender_id,
      references: :participant_id,
      type: :binary_id

    field :content, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :is_edited, :boolean, default: false
    field :edit_count, :integer, default: 0
    field :expected_sequence_id, :integer
  end

  @required_fields [:conversation_id, :sender_id, :content, :expected_sequence_id]
  @optional_fields [:created_at, :updated_at, :is_edited, :edit_count]

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sender_id)
  end
end
