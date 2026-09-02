defmodule StrangertalksNew.Reflections.Reflection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:reflection_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reflections" do
    belongs_to :owner, StrangertalksNew.Participant,
      foreign_key: :owner_participant_id,
      references: :participant_id

    field :own_reflection_text, :string
    field :source_excerpt, :string
    field :revision, :integer, default: 1
    field :create_operation_id, :binary_id
    field :saved_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :source_conversation_id, :binary_id
    field :source_client_message_id, :string
    field :source_epoch_id, :binary_id
  end

  def changeset(reflection, attrs) do
    reflection
    |> cast(attrs, [
      :own_reflection_text,
      :source_excerpt,
      :revision,
      :create_operation_id,
      :saved_at,
      :updated_at,
      :source_conversation_id,
      :source_client_message_id,
      :source_epoch_id
    ])
    |> validate_required([:own_reflection_text, :create_operation_id, :saved_at, :updated_at])
  end
end
