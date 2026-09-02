defmodule StrangertalksNew.RelationshipConsent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:relationship_consent_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "relationship_consents" do
    field :created_at, :utc_datetime_usec
    belongs_to :conversation, StrangertalksNew.Conversation, references: :conversation_id
    belongs_to :participant, StrangertalksNew.Participant, references: :participant_id
  end

  def changeset(consent, attrs) do
    consent
    |> cast(attrs, [:conversation_id, :participant_id, :created_at])
    |> validate_required([:conversation_id, :participant_id, :created_at])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:participant_id)
    |> unique_constraint([:conversation_id, :participant_id])
  end
end
