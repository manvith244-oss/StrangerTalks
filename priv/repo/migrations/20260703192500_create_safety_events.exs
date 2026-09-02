defmodule StrangertalksNew.Repo.Migrations.CreateSafetyEvents do
  use Ecto.Migration

  def change do
    create table(:safety_events, primary_key: false) do
      add :safety_event_id, :binary_id, primary_key: true

      # Enums
      add :event_status, :string, null: false
      add :event_type, :string, null: false
      add :severity_level, :string, null: false
      add :report_category, :string, null: true
      add :block_reason, :string, null: true
      add :exit_context, :string, null: true
      add :flag_reason, :string, null: true
      add :review_outcome, :string, null: true
      add :action_type, :string, null: true
      add :visibility_level, :string, null: false, default: "SAFETY_TEAM_ONLY"

      # Foreign Keys
      add :reporting_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: true

      add :target_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: true

      add :affected_participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: true

      add :conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: true

      add :match_id,
          references(:matches, column: :match_id, type: :binary_id, on_delete: :nothing),
          null: true

      add :relationship_id,
          references(:relationships,
            column: :relationship_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: true

      # Core Primitive Fields
      add :report_description, :text, null: true
      add :block_created, :boolean, null: false, default: false
      add :emergency_exit_triggered, :boolean, null: false, default: false
      add :automated_flag, :boolean, null: false, default: false
      add :confidence_score, :decimal, precision: 5, scale: 4, null: true
      add :review_required, :boolean, null: false, default: false
      add :action_taken, :boolean, null: false, default: false
      add :related_event_count, :integer, null: false, default: 0
      add :participant_report_count, :integer, null: false, default: 0
      add :participant_block_count, :integer, null: false, default: 0
      add :contains_sensitive_data, :boolean, null: false, default: false
      add :learning_processed, :boolean, null: false, default: false
      add :learning_version, :string, null: true
      add :safety_summary, :jsonb, null: false, default: fragment("'{}'::jsonb")

      # Microsecond Precision Timestamps
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :report_submitted_at, :utc_datetime_usec, null: true
      add :block_timestamp, :utc_datetime_usec, null: true
      add :exit_timestamp, :utc_datetime_usec, null: true
      add :review_started_at, :utc_datetime_usec, null: true
      add :review_completed_at, :utc_datetime_usec, null: true
      add :action_timestamp, :utc_datetime_usec, null: true
    end

    # Required & Additional Indexes
    create index(:safety_events, [:event_type])
    create index(:safety_events, [:event_status])
    create index(:safety_events, [:created_at])
    create index(:safety_events, [:target_participant_id])
    create index(:safety_events, [:severity_level])
    create index(:safety_events, [:review_required])
    create index(:safety_events, [:automated_flag])
    create index(:safety_events, [:confidence_score])

    # CHECK Constraints for String Enums
    create constraint(:safety_events, :event_status_check,
             check: "event_status IN ('OPEN', 'UNDER_REVIEW', 'RESOLVED', 'DISMISSED')"
           )

    create constraint(:safety_events, :event_type_check,
             check:
               "event_type IN ('REPORT', 'BLOCK', 'RELATIONSHIP_CLOSURE', 'EMERGENCY_EXIT', 'SAFETY_FLAG', 'SYSTEM_REVIEW', 'AUTOMATED_DETECTION')"
           )

    create constraint(:safety_events, :severity_level_check,
             check: "severity_level IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')"
           )

    create constraint(:safety_events, :report_category_check,
             check:
               "report_category IS NULL OR report_category IN ('HARASSMENT', 'ABUSIVE_LANGUAGE', 'SEXUAL_MISCONDUCT', 'THREAT', 'SPAM', 'IMPERSONATION', 'OTHER')"
           )

    create constraint(:safety_events, :block_reason_check,
             check:
               "block_reason IS NULL OR block_reason IN ('PERSONAL_BOUNDARY', 'SAFETY_CONCERN', 'HARASSMENT', 'OTHER')"
           )

    create constraint(:safety_events, :exit_context_check,
             check:
               "exit_context IS NULL OR exit_context IN ('CONVERSATION', 'RELATIONSHIP', 'MATCHING')"
           )

    create constraint(:safety_events, :flag_reason_check,
             check:
               "flag_reason IS NULL OR flag_reason IN ('ABUSE_PATTERN', 'MULTIPLE_REPORTS', 'SAFETY_THRESHOLD', 'SPAM_PATTERN', 'UNUSUAL_BEHAVIOR')"
           )

    create constraint(:safety_events, :review_outcome_check,
             check:
               "review_outcome IS NULL OR review_outcome IN ('NO_ACTION', 'WARNING', 'RESTRICTION', 'SUSPENSION', 'PERMANENT_BAN')"
           )

    create constraint(:safety_events, :action_type_check,
             check:
               "action_type IS NULL OR action_type IN ('NONE', 'MATCH_RESTRICTION', 'TEMPORARY_RESTRICTION', 'SUSPENSION', 'PERMANENT_BAN')"
           )

    create constraint(:safety_events, :visibility_level_check,
             check: "visibility_level IN ('PRIVATE', 'SAFETY_TEAM_ONLY', 'SYSTEM_ONLY')"
           )

    # Confidence Score Domain Constraint
    create constraint(:safety_events, :confidence_score_range,
             check:
               "confidence_score IS NULL OR (confidence_score >= 0.0 AND confidence_score <= 1.0)"
           )
  end
end
