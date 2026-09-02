defmodule StrangertalksNew.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :message_id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("gen_random_uuid()")

      add :conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :sender_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :restrict),
          null: false

      add :content, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: true
      add :is_edited, :boolean, null: false, default: false
      add :edit_count, :integer, null: false, default: 0
      add :expected_sequence_id, :integer, null: false
    end

    # Documented Performance Indexes
    create index(:messages, [:conversation_id, :created_at])
    create index(:messages, [:conversation_id, :expected_sequence_id])
  end
end
