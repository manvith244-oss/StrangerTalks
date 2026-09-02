defmodule StrangertalksNew.Repo.Migrations.CreateMatches do
  use Ecto.Migration

  def change do
    create table(:matches, primary_key: false) do
      add :match_id, :binary_id, primary_key: true
      add :created_at, :utc_datetime_usec, null: false

      # Enum Fields implemented as strings for CHECK constraints
      add :door_type, :string, null: false
      add :match_status, :string, null: false
      add :match_strategy, :string, null: false
      add :failure_reason, :string, null: true

      # Foreign Keys referencing the participants table (using participant_id column)
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

      # Ephemeral and Future Unbuilt System Fields (Plain IDs, no FKs)
      add :queue_id, :binary_id, null: true
      add :atmosphere_id, :binary_id, null: true
      add :icebreaker_id, :binary_id, null: true
      add :transition_experience_id, :binary_id, null: true

      # Score Fields (Strict Precision: decimal(5,4))
      add :compatibility_score, :decimal, precision: 5, scale: 4, null: false
      add :opportunity_score, :decimal, precision: 5, scale: 4, null: false
      add :scarcity_adjustment, :decimal, precision: 5, scale: 4, null: false
      add :conversation_temperature, :decimal, precision: 5, scale: 4, null: false
      add :mutual_participation_score, :decimal, precision: 5, scale: 4, null: false
      add :conversation_health_score, :decimal, precision: 5, scale: 4, null: false
      add :match_quality_score, :decimal, precision: 5, scale: 4, null: false

      # Operational and Metric fields using continuous utc_datetime_usec strategy
      add :queue_entry_time, :utc_datetime_usec, null: false
      add :match_found_time, :utc_datetime_usec, null: false
      add :conversation_start_time, :utc_datetime_usec, null: true
      add :match_end_time, :utc_datetime_usec, null: true

      add :queue_duration_seconds, :integer, null: false
      add :conversation_duration_seconds, :integer, null: false
      add :conversation_started, :boolean, null: false
      add :conversation_completed, :boolean, null: false
      add :memory_created, :boolean, null: false
      add :relationship_created, :boolean, null: false
      add :reconnected_later, :boolean, null: false
      add :report_generated, :boolean, null: false
      add :block_generated, :boolean, null: false
      add :safety_review_required, :boolean, null: false
      add :learning_processed, :boolean, default: false, null: false
      add :learning_version, :string, null: false
    end

    # Database Level CHECK Constraints for Enum Safety
    create constraint(:matches, :door_type_check,
             check: "door_type IN ('JUST_TALK','KEEP_IT_LIGHT','EXPLORE','SOMETHING_REAL')"
           )

    create constraint(:matches, :match_status_check,
             check:
               "match_status IN ('CREATED','TRANSITIONING','ACTIVE','ENDED','FAILED','EXPIRED')"
           )

    create constraint(:matches, :match_strategy_check,
             check:
               "match_strategy IN ('COMPATIBILITY','OPPORTUNITY','SCARCITY','MANUAL_OVERRIDE')"
           )

    create constraint(:matches, :failure_reason_check,
             check:
               "failure_reason IS NULL OR failure_reason IN ('NO_RESPONSE','DISCONNECT','LEFT_DURING_TRANSITION','LEFT_IMMEDIATELY','TECHNICAL_FAILURE','SAFETY_EVENT')"
           )

    # Required Indexes
    create index(:matches, [:participant_a_id])
    create index(:matches, [:participant_b_id])
    create index(:matches, [:door_type])
    create index(:matches, [:match_status])
    create index(:matches, [:created_at])
  end
end
