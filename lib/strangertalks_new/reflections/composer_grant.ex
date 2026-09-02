defmodule StrangertalksNew.Reflections.ComposerGrant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:grant_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "composer_grants" do
    belongs_to :owner, StrangertalksNew.Participant,
      foreign_key: :owner_participant_id,
      references: :participant_id

    field :secret_verifier, :binary
    field :opened_at, :utc_datetime_usec
    field :source_conversation_id, :binary_id
    field :source_client_message_id, :string
    field :source_epoch_id, :binary_id
    field :selection_start_grapheme, :integer
    field :selection_end_grapheme, :integer
    field :expected_source_revision, :integer
    field :terminal_excerpt_hmac, :binary
    field :terminal_expires_at, :utc_datetime_usec
    field :state, :string, default: "OPEN"
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :secret_verifier,
      :opened_at,
      :source_conversation_id,
      :source_client_message_id,
      :source_epoch_id,
      :selection_start_grapheme,
      :selection_end_grapheme,
      :expected_source_revision,
      :terminal_excerpt_hmac,
      :terminal_expires_at,
      :state,
      :created_at,
      :updated_at
    ])
    |> validate_required([:secret_verifier, :opened_at, :state, :created_at, :updated_at])
  end
end
