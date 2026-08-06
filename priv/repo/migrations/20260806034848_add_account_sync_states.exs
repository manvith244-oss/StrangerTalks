defmodule StrangertalksNew.Repo.Migrations.AddAccountSyncStates do
  use Ecto.Migration

  def up do
    create table(:account_sync_states, primary_key: false) do
      add :account_id,
          references(:private_accounts, type: :uuid, column: :account_id, on_delete: :delete_all),
          primary_key: true

      add :drive_file_id, :string
      add :last_known_revision, :bigint, null: false, default: 0
      add :encrypted_payload_sha256, :binary
      add :encrypted_byte_size, :bigint
      add :last_synced_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:account_sync_states, :account_sync_revision_nonnegative,
             check: "last_known_revision >= 0"
           )

    create constraint(:account_sync_states, :account_sync_byte_size_nonnegative,
             check: "encrypted_byte_size IS NULL OR encrypted_byte_size >= 0"
           )
  end

  def down, do: drop(table(:account_sync_states))
end
