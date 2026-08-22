defmodule StrangertalksNew.Repo.Migrations.AddRelationshipConsentsAndSafetyReviews do
  use Ecto.Migration

  def change do
    create table(:relationship_consents, primary_key: false) do
      add :relationship_consent_id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:relationship_consents, [:conversation_id, :participant_id])

    alter table(:relationships) do
      modify :learning_version, :string, null: true, from: {:string, null: false}

      modify :learning_processed, :boolean,
        null: true,
        default: nil,
        from: {:boolean, null: false, default: false}

      modify :reconnection_priority, :decimal, null: true, from: {:decimal, null: false}
      modify :relationship_strength_score, :decimal, null: true, from: {:decimal, null: false}
      modify :continuation_probability, :decimal, null: true, from: {:decimal, null: false}
      modify :relationship_temperature, :decimal, null: true, from: {:decimal, null: false}
      modify :atmosphere_history, :jsonb, null: true, from: {:jsonb, null: false}
      modify :relationship_summary, :jsonb, null: true, from: {:jsonb, null: false}
    end

    create unique_index(
             :relationships,
             [
               "LEAST(participant_a_id, participant_b_id)",
               "GREATEST(participant_a_id, participant_b_id)"
             ],
             name: :relationships_canonical_pair_index
           )

    alter table(:reports) do
      add :deduplication_key, :string, null: true
    end

    create unique_index(:reports, [:deduplication_key])

    create table(:safety_reviews, primary_key: false) do
      add :safety_review_id, :binary_id, primary_key: true

      add :report_id,
          references(:reports, column: :report_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false
      add :severity_level, :string, null: true
      add :resolution, :string, null: true
      add :review_notes, :text, null: true
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :reviewed_at, :utc_datetime_usec, null: true
    end

    create unique_index(:safety_reviews, [:report_id])

    create constraint(:safety_reviews, :safety_reviews_status_check,
             check: "status IN ('PENDING', 'IN_REVIEW', 'RESOLVED', 'DISMISSED')"
           )

    create constraint(:safety_reviews, :safety_reviews_severity_check,
             check:
               "severity_level IS NULL OR severity_level IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')"
           )
  end
end
