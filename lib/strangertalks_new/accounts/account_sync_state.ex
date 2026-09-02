defmodule StrangertalksNew.Accounts.AccountSyncState do
  use Ecto.Schema
  @primary_key {:account_id, :binary_id, autogenerate: false}
  schema "account_sync_states" do
    field :drive_file_id, :string
    field :last_known_revision, :integer, default: 0
    field :encrypted_payload_sha256, :binary
    field :encrypted_byte_size, :integer
    field :last_synced_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
