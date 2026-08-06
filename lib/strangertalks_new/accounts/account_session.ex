defmodule StrangertalksNew.Accounts.AccountSession do
  use Ecto.Schema
  @primary_key {:account_session_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "account_sessions" do
    belongs_to :account, StrangertalksNew.Accounts.PrivateAccount, references: :account_id
    field :session_token_hash, :binary
    field :created_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end
end
