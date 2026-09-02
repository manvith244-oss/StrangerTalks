defmodule StrangertalksNew.Repo.Migrations.AddPrivateGoogleAccountContinuity do
  use Ecto.Migration

  def up do
    create table(:private_accounts, primary_key: false) do
      add :account_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :participant_id,
          references(:participants, type: :uuid, column: :participant_id, on_delete: :restrict),
          null: false

      add :last_signed_in_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:private_accounts, [:participant_id])

    create table(:google_account_links, primary_key: false) do
      add :google_account_link_id, :uuid,
        primary_key: true,
        default: fragment("gen_random_uuid()")

      add :account_id,
          references(:private_accounts, type: :uuid, column: :account_id, on_delete: :delete_all),
          null: false

      add :provider_subject_hash, :binary, null: false
      add :encrypted_refresh_token, :binary
      add :refresh_token_iv, :binary
      add :refresh_token_tag, :binary
      add :token_key_version, :integer
      add :granted_scopes, {:array, :string}, null: false, default: []
      add :connected_at, :utc_datetime_usec, null: false
      add :refreshed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:google_account_links, [:account_id])
    create unique_index(:google_account_links, [:provider_subject_hash])

    create constraint(:google_account_links, :google_refresh_token_material_consistency,
             check:
               "(encrypted_refresh_token IS NULL AND refresh_token_iv IS NULL AND refresh_token_tag IS NULL AND token_key_version IS NULL) OR (encrypted_refresh_token IS NOT NULL AND refresh_token_iv IS NOT NULL AND refresh_token_tag IS NOT NULL AND token_key_version IS NOT NULL)"
           )

    create table(:account_sessions, primary_key: false) do
      add :account_session_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :account_id,
          references(:private_accounts, type: :uuid, column: :account_id, on_delete: :delete_all),
          null: false

      add :session_token_hash, :binary, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
    end

    create unique_index(:account_sessions, [:session_token_hash])
    create index(:account_sessions, [:account_id])

    create table(:google_oauth_attempts, primary_key: false) do
      add :oauth_attempt_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :state_hash, :binary, null: false
      add :nonce_hash, :binary, null: false

      add :participant_id,
          references(:participants, type: :uuid, column: :participant_id, on_delete: :nilify_all)

      add :mode, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
    end

    create unique_index(:google_oauth_attempts, [:state_hash])

    create constraint(:google_oauth_attempts, :google_oauth_attempt_mode_check,
             check: "mode IN ('LINK_CURRENT_GUEST','SIGN_IN_EXISTING')"
           )
  end

  def down do
    drop table(:google_oauth_attempts)
    drop table(:account_sessions)
    drop table(:google_account_links)
    drop table(:private_accounts)
  end
end
