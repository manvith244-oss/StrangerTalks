defmodule StrangertalksNew.Repo.Migrations.CreateLearningRecords do
  use Ecto.Migration

  def change do
    create table(:learning_records, primary_key: false) do
      add :learning_record_id, :binary_id, primary_key: true
      add :record_type, :string, null: false

      # Explicitly Governed Foreign Keys with Custom :nilify_all Erasure Mechanics
      add :participant_id,
          references(:participants,
            column: :participant_id,
            type: :binary_id,
            on_delete: :nilify_all
          ),
          null: true

      add :match_id,
          references(:matches, column: :match_id, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :binary_id,
            on_delete: :nilify_all
          ),
          null: true

      # Flat Data Fields
      add :bridge_used, :string, null: true
      add :bridge_category, :string, null: true
      add :bridge_effectiveness_score, :decimal, precision: 5, scale: 4, null: true
      add :complexity_level, :string, null: true
      add :atmosphere_environment, :string, null: true
      add :readiness_score, :decimal, precision: 5, scale: 4, null: true
      add :keystroke_latency_variance, :decimal, precision: 5, scale: 4, null: true
      add :outcome_signal, :string, null: true

      # Manual Timestamp Configuration (Macro timestamps() is explicitly banned)
      add :created_at, :utc_datetime_usec, null: false
    end

    # Database-level Enum CHECK Constraints
    create constraint(:learning_records, :chk_learning_records_record_type,
             check:
               "record_type IN ('ICEBREAKER_LEARNING', 'ATMOSPHERE_ADAPTATION', 'READINESS_EVALUATION')"
           )

    create constraint(:learning_records, :chk_learning_records_bridge_category,
             check:
               "bridge_category IS NULL OR bridge_category IN ('UNIVERSAL', 'CONTEXT', 'SPECIALIZED')"
           )

    create constraint(:learning_records, :chk_learning_records_complexity_level,
             check: "complexity_level IS NULL OR complexity_level IN ('LOW', 'MEDIUM', 'HIGH')"
           )

    create constraint(:learning_records, :chk_learning_records_atmosphere,
             check:
               "atmosphere_environment IS NULL OR atmosphere_environment IN ('LATE_NIGHT_LIBRARY', 'RAIN_WINDOW', 'COFFEE_SHOP', 'TRAIN_JOURNEY', 'AURORA', 'NIGHT_OBSERVATORY', 'SOFT_HORIZON')"
           )

    create constraint(:learning_records, :chk_learning_records_outcome,
             check:
               "outcome_signal IS NULL OR outcome_signal IN ('SUCCESS', 'FAILURE', 'ABANDONED', 'TIMEOUT')"
           )

    # High-Precision Score Boundaries Constraints
    create constraint(:learning_records, :chk_learning_records_effectiveness_range,
             check:
               "bridge_effectiveness_score IS NULL OR (bridge_effectiveness_score >= 0.0000 AND bridge_effectiveness_score <= 9.9999)"
           )

    create constraint(:learning_records, :chk_learning_records_readiness_range,
             check:
               "readiness_score IS NULL OR (readiness_score >= 0.0000 AND readiness_score <= 9.9999)"
           )

    create constraint(:learning_records, :chk_learning_records_keystroke_range,
             check:
               "keystroke_latency_variance IS NULL OR (keystroke_latency_variance >= 0.0000 AND keystroke_latency_variance <= 9.9999)"
           )

    # Required Operational Indexes Configuration
    create index(:learning_records, [:participant_id],
             name: :idx_learning_records_participant_id,
             where: "participant_id IS NOT NULL"
           )

    create index(:learning_records, [:match_id],
             name: :idx_learning_records_match_id,
             where: "match_id IS NOT NULL"
           )

    create index(:learning_records, [:conversation_id],
             name: :idx_learning_records_conversation_id,
             where: "conversation_id IS NOT NULL"
           )

    create index(:learning_records, ["created_at DESC"],
             name: :idx_learning_records_chronological
           )

    create index(:learning_records, [:record_type, :outcome_signal],
             name: :idx_learning_records_type_outcome,
             where: "outcome_signal IS NOT NULL"
           )

    create index(:learning_records, [:bridge_used, :bridge_effectiveness_score],
             name: :idx_learning_records_effective_bridges,
             where: "bridge_effectiveness_score IS NOT NULL"
           )
  end
end
