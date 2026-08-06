defmodule StrangertalksNew.Accounts.GoogleOauthAttempt do
  use Ecto.Schema
  @primary_key {:oauth_attempt_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "google_oauth_attempts" do
    field :state_hash, :binary
    field :nonce_hash, :binary
    belongs_to :participant, StrangertalksNew.Participant, references: :participant_id
    field :mode, :string
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
  end
end
