defmodule StrangertalksNew.Accounts.GoogleAccountLink do
  use Ecto.Schema
  @primary_key {:google_account_link_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "google_account_links" do
    belongs_to :account, StrangertalksNew.Accounts.PrivateAccount, references: :account_id
    field :provider_subject_hash, :binary
    field :encrypted_refresh_token, :binary
    field :refresh_token_iv, :binary
    field :refresh_token_tag, :binary
    field :token_key_version, :integer
    field :granted_scopes, {:array, :string}, default: []
    field :connected_at, :utc_datetime_usec
    field :refreshed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
