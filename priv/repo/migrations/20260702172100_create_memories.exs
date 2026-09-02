defmodule StrangertalksNew.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def change do
    create table(:memories, primary_key: false) do
      add :memory_id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("gen_random_uuid()")

      add :created_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :memory_status, :string, null: false

      add :owner_participant_id,
          references(:participants, column: :participant_id, type: :uuid, on_delete: :restrict),
          null: false

      add :conversation_id,
          references(:conversations, column: :conversation_id, type: :uuid, on_delete: :restrict),
          null: false

      add :match_id, references(:matches, column: :match_id, type: :uuid, on_delete: :restrict),
        null: false

      add :memory_type, :string, null: false
      add :title, :string, size: 200, null: false
      add :memory_content, :text, null: false
      add :memory_summary, :text, null: true

      # Fixed ArgumentError: changed from non-existent :set_null to Ecto's canonical :nilify_all
      add :source_message_id,
          references(:messages, column: :message_id, type: :uuid, on_delete: :nilify_all),
          null: true

      add :quoted_text, :text, null: true
      add :reflection_text, :text, null: true
      add :moment_description, :text, null: true
      add :door_type, :string, null: false
      add :atmosphere_id, :uuid, null: false
      add :atmosphere_name, :string, null: false
      add :collection_id, :uuid, null: true
      add :collection_name, :string, null: true
      add :private_notes, :text, null: true
      add :notes_updated_at, :utc_datetime_usec, null: true
      add :visibility_type, :string, null: false, default: "PRIVATE"
      add :shared_relationship_id, :uuid, null: true
      add :view_count, :integer, null: false
      add :last_viewed_at, :utc_datetime_usec, null: true
      add :revisited_count, :integer, null: false
      add :memory_significance_score, :decimal, precision: 5, scale: 4, null: false
      add :memory_category, :string, null: false
      add :learning_processed, :boolean, null: false, default: false
      add :eligible_for_revisit, :boolean, null: false, default: true
      add :last_revisit_prompt_at, :utc_datetime_usec, null: true
      add :deleted_at, :utc_datetime_usec, null: true
      add :deletion_reason, :string, null: true
    end

    # Explicit Database CHECK Constraints matching Canonical Enums
    create constraint(:memories, :memory_status_check,
             check: "memory_status IN ('ACTIVE', 'ARCHIVED', 'DELETED')"
           )

    create constraint(:memories, :memory_type_check,
             check: "memory_type IN ('QUOTE', 'REFLECTION', 'MOMENT', 'SHARED_MEMORY')"
           )

    create constraint(:memories, :door_type_check,
             check: "door_type IN ('JUST_TALK', 'KEEP_IT_LIGHT', 'EXPLORE', 'SOMETHING_REAL')"
           )

    create constraint(:memories, :visibility_type_check,
             check: "visibility_type IN ('PRIVATE', 'SHARED')"
           )

    create constraint(:memories, :memory_category_check,
             check:
               "memory_category IN ('ADVICE', 'REFLECTION', 'DISCOVERY', 'COMFORT', 'HUMOR', 'CONNECTION', 'OTHER')"
           )

    create constraint(:memories, :deletion_reason_check,
             check:
               "deletion_reason IN ('PARTICIPANT_REQUEST', 'RELATIONSHIP_REMOVED', 'PRIVACY_REQUEST', 'SYSTEM_RETENTION')"
           )

    create constraint(:memories, :memory_significance_score_range_check,
             check: "memory_significance_score >= 0.0 AND memory_significance_score <= 1.0"
           )

    # Performance Index Layout
    create index(:memories, [:memory_id])
    create index(:memories, [:owner_participant_id])
    create index(:memories, [:conversation_id])
    create index(:memories, [:memory_type])
    create index(:memories, [:created_at])
    create index(:memories, [:collection_id])
    create index(:memories, [:memory_category])
    create index(:memories, [:atmosphere_name])
    create index(:memories, [:door_type])
  end
end
