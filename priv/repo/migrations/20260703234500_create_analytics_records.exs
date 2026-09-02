defmodule StrangertalksNew.Repo.Migrations.CreateAnalyticsRecords do
  use Ecto.Migration

  def change do
    create table(:analytics_records, primary_key: false) do
      add :analytics_record_id, :binary_id, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
      add :analytics_period, :string, null: false
      add :analytics_date, :date, null: false

      # Source Information
      add :source_type, :string, null: false
      add :source_count, :integer, null: false, default: 0

      # Participant Telemetry
      add :active_participants, :integer, null: false, default: 0
      add :new_participants, :integer, null: false, default: 0
      add :returning_participants, :integer, null: false, default: 0
      add :average_session_duration, :float, null: false, default: 0.0

      # Door Lanes (Participant Intent)
      add :just_talk_count, :integer, null: false, default: 0
      add :keep_it_light_count, :integer, null: false, default: 0
      add :explore_count, :integer, null: false, default: 0
      add :something_real_count, :integer, null: false, default: 0
      add :door_distribution, :jsonb, null: false, default: "{}"

      # Matchmaking Pipeline Metrics
      add :matches_created, :integer, null: false, default: 0
      add :average_queue_time_seconds, :float, null: false, default: 0.0
      add :queue_success_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :match_failure_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :recovery_mode_activation_count, :integer, null: false, default: 0

      # Conversation Telemetry
      add :conversations_started, :integer, null: false, default: 0
      add :conversations_completed, :integer, null: false, default: 0
      add :average_conversation_duration, :float, null: false, default: 0.0

      add :average_conversation_temperature, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :conversation_success_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      # Icebreaker Telemetry
      add :icebreakers_shown, :integer, null: false, default: 0
      add :icebreakers_used, :integer, null: false, default: 0
      add :icebreaker_usage_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :average_bridge_effectiveness, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      # Atmosphere Telemetry (Decoupled Logical reference - fixed null syntax error)
      add :atmosphere_id, :binary_id, null: true

      add :atmosphere_usage_count, :integer, null: false, default: 0
      add :atmosphere_success_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :atmosphere_memory_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :atmosphere_relationship_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      # Reflection and Memory Telemetry
      add :memories_created, :integer, null: false, default: 0
      add :memory_creation_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :memory_revisit_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :most_common_memory_type, :string, null: false, default: "MOMENT"

      # Connection Continuation (Relationship) Telemetry
      add :relationships_created, :integer, null: false, default: 0

      add :relationship_creation_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :relationship_reconnection_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :average_relationship_lifespan, :float, null: false, default: 0.0

      # Safety and Trust Telemetry
      add :reports_submitted, :integer, null: false, default: 0
      add :blocks_created, :integer, null: false, default: 0
      add :emergency_exits, :integer, null: false, default: 0
      add :safety_review_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :resolved_safety_events, :integer, null: false, default: 0
      add :bot_fingerprints_blocked_count, :integer, null: false, default: 0
      add :tarpit_sandboxed_sessions_count, :integer, null: false, default: 0

      # Experience Funnel Conversions
      add :landing_to_door_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000
      add :door_to_match_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :match_to_conversation_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :conversation_to_memory_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :conversation_to_relationship_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      # Platform Health and Quality Metrics
      add :platform_health_score, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :connection_success_score, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :participant_satisfaction_score, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :trust_score, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :quality_weighted_conversations_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      # Retention Tracking Matrix
      add :n_day_active_retention_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :rolling_retention_rate, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :bracket_cohort_retention_rate, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      # Compliance and Regional Routing Counters
      add :jurisdiction_distribution, :jsonb, null: false, default: "{}"

      # Agent Performance Accuracy Telemetry
      add :queue_agent_accuracy, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      add :compatibility_agent_accuracy, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :icebreaker_agent_accuracy, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :relationship_agent_accuracy, :decimal,
        precision: 5,
        scale: 4,
        null: false,
        default: 0.0000

      add :safety_agent_accuracy, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      # Long-term Trends Tracking
      add :trend_category, :string, null: false, default: "CONVERSATION"
      add :trend_direction, :string, null: false, default: "STABLE"
      add :trend_strength, :decimal, precision: 5, scale: 4, null: false, default: 0.0000

      # Privacy Guard Rails
      add :contains_personal_data, :boolean, null: false, default: false
      add :aggregation_level, :string, null: false, default: "AGGREGATED"
    end

    # Database-level CHECK Constraints for Enums
    create constraint(:analytics_records, :analytics_period_check,
             check: "analytics_period IN ('REALTIME', 'HOURLY', 'DAILY', 'WEEKLY', 'MONTHLY')"
           )

    create constraint(:analytics_records, :source_type_check,
             check:
               "source_type IN ('PARTICIPANT', 'QUEUE', 'MATCH', 'CONVERSATION', 'MEMORY', 'RELATIONSHIP', 'SAFETY', 'SYSTEM')"
           )

    create constraint(:analytics_records, :most_common_memory_type_check,
             check:
               "most_common_memory_type IN ('QUOTE', 'REFLECTION', 'MOMENT', 'SHARED_MEMORY')"
           )

    create constraint(:analytics_records, :trend_category_check,
             check:
               "trend_category IN ('DOOR', 'CONVERSATION', 'ICEBREAKER', 'ATMOSPHERE', 'MEMORY', 'RELATIONSHIP', 'SAFETY')"
           )

    create constraint(:analytics_records, :trend_direction_check,
             check: "trend_direction IN ('UP', 'DOWN', 'STABLE')"
           )

    create constraint(:analytics_records, :aggregation_level_check,
             check: "aggregation_level IN ('ANONYMIZED', 'AGGREGATED', 'SYSTEM_ONLY')"
           )

    # Absolute Value Guard rails for Privacy Enforcement
    create constraint(:analytics_records, :chk_privacy_no_personal_data,
             check: "contains_personal_data = FALSE"
           )

    # Value Bounding CHECK Constraints for DECIMAL(5,4) Rates and Scores
    create constraint(:analytics_records, :chk_queue_success_rate,
             check: "queue_success_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_match_failure_rate,
             check: "match_failure_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_avg_conv_temperature,
             check: "average_conversation_temperature BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_conv_success_rate,
             check: "conversation_success_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_icebreaker_usage_rate,
             check: "icebreaker_usage_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_avg_bridge_effectiveness,
             check: "average_bridge_effectiveness BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_atmo_success_rate,
             check: "atmosphere_success_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_atmo_memory_rate,
             check: "atmosphere_memory_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_atmo_relationship_rate,
             check: "atmosphere_relationship_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_memory_creation_rate,
             check: "memory_creation_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_memory_revisit_rate,
             check: "memory_revisit_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_relationship_creation_rate,
             check: "relationship_creation_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_relationship_reconnection_rate,
             check: "relationship_reconnection_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_safety_review_rate,
             check: "safety_review_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_landing_to_door_rate,
             check: "landing_to_door_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_door_to_match_rate,
             check: "door_to_match_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_match_to_conv_rate,
             check: "match_to_conversation_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_conv_to_memory_rate,
             check: "conversation_to_memory_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_conv_to_relationship_rate,
             check: "conversation_to_relationship_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_platform_health_score,
             check: "platform_health_score BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_connection_success_score,
             check: "connection_success_score BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_participant_satisfaction_score,
             check: "participant_satisfaction_score BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_trust_score,
             check: "trust_score BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_quality_weighted_conv_rate,
             check: "quality_weighted_conversations_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_n_day_active_ret_rate,
             check: "n_day_active_retention_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_rolling_ret_rate,
             check: "rolling_retention_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_bracket_cohort_ret_rate,
             check: "bracket_cohort_retention_rate BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_queue_agent_accuracy,
             check: "queue_agent_accuracy BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_compatibility_agent_accuracy,
             check: "compatibility_agent_accuracy BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_icebreaker_agent_accuracy,
             check: "icebreaker_agent_accuracy BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_relationship_agent_accuracy,
             check: "relationship_agent_accuracy BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_safety_agent_accuracy,
             check: "safety_agent_accuracy BETWEEN 0.0000 AND 1.0000"
           )

    create constraint(:analytics_records, :chk_trend_strength,
             check: "trend_strength BETWEEN 0.0000 AND 1.0000"
           )

    # Optimization Indexes
    create index(:analytics_records, [:analytics_record_id])
    create index(:analytics_records, [:analytics_date, :analytics_period])
    create index(:analytics_records, [:source_type])
    create index(:analytics_records, [:created_at])
    create index(:analytics_records, [:trend_category, :trend_direction])
  end
end
