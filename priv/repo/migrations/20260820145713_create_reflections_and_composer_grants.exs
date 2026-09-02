defmodule StrangertalksNew.Repo.Migrations.CreateReflectionsAndComposerGrants do
  use Ecto.Migration

  def change do
    create table(:reflections, primary_key: false) do
      add :reflection_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :owner_participant_id,
          references(:participants, type: :uuid, column: :participant_id, on_delete: :delete_all),
          null: false

      add :own_reflection_text, :text, null: false
      add :source_excerpt, :text
      add :revision, :integer, null: false, default: 1
      add :create_operation_id, :uuid, null: false
      add :saved_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :source_conversation_id, :uuid
      add :source_client_message_id, :string
      add :source_epoch_id, :uuid
    end

    create unique_index(:reflections, [:owner_participant_id, :create_operation_id])
    create index(:reflections, [:owner_participant_id, :saved_at])
    create index(:reflections, [:source_conversation_id, :source_client_message_id])

    create table(:composer_grants, primary_key: false) do
      add :grant_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :owner_participant_id,
          references(:participants, type: :uuid, column: :participant_id, on_delete: :delete_all),
          null: false

      add :secret_verifier, :binary, null: false
      add :opened_at, :utc_datetime_usec, null: false
      add :source_conversation_id, :uuid
      add :source_client_message_id, :string
      add :source_epoch_id, :uuid
      add :selection_start_grapheme, :integer
      add :selection_end_grapheme, :integer
      add :expected_source_revision, :integer
      add :terminal_excerpt_hmac, :binary
      add :terminal_expires_at, :utc_datetime_usec
      add :state, :string, null: false, default: "OPEN"
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:composer_grants, [:owner_participant_id, :state])
    create index(:composer_grants, [:source_conversation_id, :source_client_message_id])
  end
end
