defmodule StrangertalksNew.Repo.Migrations.AddParticipantCredentialVersion do
  use Ecto.Migration

  def up do
    alter table(:participants) do
      add :credential_version, :integer, null: false, default: 0
    end

    execute("""
    UPDATE participants
    SET credential_version = 1
    WHERE participant_id IN (SELECT participant_id FROM private_accounts)
    """)
  end

  def down do
    alter table(:participants) do
      remove :credential_version
    end
  end
end
