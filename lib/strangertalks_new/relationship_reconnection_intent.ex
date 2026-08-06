defmodule StrangertalksNew.RelationshipReconnectionIntent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:reconnect_intent_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "relationship_reconnection_intents" do
    field :door_type, Ecto.Enum, values: [:JUST_TALK, :KEEP_IT_LIGHT, :EXPLORE, :SOMETHING_REAL]
    field :status, Ecto.Enum, values: [:ACTIVE, :CONSUMED, :CANCELLED, :EXPIRED]
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    belongs_to :relationship, StrangertalksNew.Relationship,
      foreign_key: :relationship_id,
      references: :relationship_id

    belongs_to :participant, StrangertalksNew.Participant,
      foreign_key: :participant_id,
      references: :participant_id
  end

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :relationship_id,
      :participant_id,
      :door_type,
      :status,
      :created_at,
      :updated_at,
      :expires_at,
      :consumed_at,
      :cancelled_at
    ])
    |> validate_required([
      :relationship_id,
      :participant_id,
      :door_type,
      :status,
      :created_at,
      :updated_at,
      :expires_at
    ])
    |> foreign_key_constraint(:relationship_id)
    |> foreign_key_constraint(:participant_id)
    |> unique_constraint([:relationship_id, :participant_id],
      name: :relationship_reconnection_intents_one_active_index
    )
  end
end
