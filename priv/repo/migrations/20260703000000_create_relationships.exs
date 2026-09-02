defmodule StrangertalksNew.Repo.Migrations.CreateRelationships do
  use Ecto.Migration

  def change do
    create table(:relationships, primary_key: false) do
      # Custom UUID Primary Key named after the domain
      add :relationship_id, :binary_id, primary_key: true

      # Manual Timestamps (Banned macro timestamps())
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec, null: true
      add :last_conversation_at, :utc_datetime_usec, null: true
      add :last_activity_at, :utc_datetime_usec, null: true
      add :first_conversation_at, :utc_datetime_usec, null: false
      add :latest_note_at, :utc_datetime_usec, null: true
      add :closed_at, :utc_datetime_usec, null: true

      # Core Enums with String + CHECK Constraints (No Native Postgres Enums)
      add :relationship_status, :string, null: false
      add :origin_door_type, :string, null: false
      add :closure_reason, :string, null: true

      # Explicit Foreign Keys matching the domain definitions
      add :participant_a_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :participant_b_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :origin_conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :origin_match_id,
          references(:matches, column: :match_id, type: :binary_id, on_delete: :nothing),
          null: false

      # Nullable and Un-enforced structural references
      add :origin_atmosphere_id, :binary_id, null: true
      add :latest_conversation_id, :binary_id, null: true
      add :latest_memory_id, :binary_id, null: true
      add :featured_memory_id, :binary_id, null: true
      add :closed_by_participant_id, :binary_id, null: true

      # Core Booleans with explicit Defaults
      add :participant_a_accepted, :boolean, null: false
      add :participant_b_accepted, :boolean, null: false
      add :allow_reconnection, :boolean, null: false, default: true
      add :reconnection_eligible, :boolean, null: false
      add :participant_a_closed, :boolean, null: false, default: false
      add :participant_b_closed, :boolean, null: false, default: false
      add :participant_a_blocked, :boolean, null: false, default: false
      add :participant_b_blocked, :boolean, null: false, default: false
      add :learning_processed, :boolean, null: false, default: false

      # Character Attributes & Core Metrics
      add :relationship_name, :string, null: true
      add :participant_custom_name, :string, null: true
      add :most_common_atmosphere, :string, null: true
      add :learning_version, :string, null: false

      # Counters (all start at 0)
      add :conversation_count, :integer, null: false, default: 0
      add :memory_count, :integer, null: false, default: 0
      add :reconnection_count, :integer, null: false, default: 0
      add :shared_memory_count, :integer, null: false, default: 0
      add :private_note_count, :integer, null: false, default: 0

      # Precision Decimal Scores (precision: 5, scale: 4)
      add :reconnection_priority, :decimal, precision: 5, scale: 4, null: false
      add :relationship_strength_score, :decimal, precision: 5, scale: 4, null: false
      add :continuation_probability, :decimal, precision: 5, scale: 4, null: false
      add :relationship_temperature, :decimal, precision: 5, scale: 4, null: false

      # Structured JSONB Telemetry blocks
      add :atmosphere_history, :jsonb, null: false
      add :relationship_summary, :jsonb, null: false
    end

    # Database-level Enum CHECK Constraints
    create constraint(:relationships, :relationship_status_check,
             check: "relationship_status IN ('ACTIVE', 'QUIET', 'PAUSED', 'CLOSED')"
           )

    create constraint(:relationships, :origin_door_type_check,
             check:
               "origin_door_type IN ('JUST_TALK', 'KEEP_IT_LIGHT', 'EXPLORE', 'SOMETHING_REAL')"
           )

    create constraint(:relationships, :closure_reason_check,
             check:
               "closure_reason IS NULL OR closure_reason IN ('PARTICIPANT_CLOSED', 'BLOCKED', 'SAFETY_ACTION', 'INACTIVE_EXPIRATION')"
           )

    # Core Metrics Numerical Limits
    create constraint(:relationships, :relationship_strength_score_range,
             check:
               "relationship_strength_score >= 0.0000 AND relationship_strength_score <= 1.0000"
           )

    # Canonical & Performance Optimization Indexes
    create index(:relationships, [:participant_a_id])
    create index(:relationships, [:participant_b_id])
    create index(:relationships, [:relationship_status])
    create index(:relationships, [:created_at])
    create index(:relationships, [:last_activity_at])
    create index(:relationships, [:relationship_strength_score])
    create index(:relationships, [:reconnection_eligible])

    # NOTE: Future foreign keys for Memory, Relationship Note, Safety Event, and Learning Record
    # will be introduced in later vertical slices once those tables exist.
  end
end
