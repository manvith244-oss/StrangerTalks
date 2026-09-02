defmodule StrangertalksNew.AnalyticsRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:analytics_record_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "analytics_records" do
    field :created_at, :utc_datetime_usec
    field :analytics_period, Ecto.Enum, values: [:REALTIME, :HOURLY, :DAILY, :WEEKLY, :MONTHLY]
    field :analytics_date, :date

    field :source_type, Ecto.Enum,
      values: [
        :PARTICIPANT,
        :QUEUE,
        :MATCH,
        :CONVERSATION,
        :MEMORY,
        :RELATIONSHIP,
        :SAFETY,
        :SYSTEM
      ]

    field :source_count, :integer, default: 0

    # Participant Telemetry
    field :active_participants, :integer, default: 0
    field :new_participants, :integer, default: 0
    field :returning_participants, :integer, default: 0
    field :average_session_duration, :float, default: 0.0

    # Door Lanes
    field :just_talk_count, :integer, default: 0
    field :keep_it_light_count, :integer, default: 0
    field :explore_count, :integer, default: 0
    field :something_real_count, :integer, default: 0
    field :door_distribution, :map, default: %{}

    # Matchmaking
    field :matches_created, :integer, default: 0
    field :average_queue_time_seconds, :float, default: 0.0
    field :queue_success_rate, :decimal, default: nil
    field :match_failure_rate, :decimal, default: nil
    field :recovery_mode_activation_count, :integer, default: 0

    # Conversation Telemetry
    field :conversations_started, :integer, default: 0
    field :conversations_completed, :integer, default: 0
    field :average_conversation_duration, :float, default: 0.0
    field :average_conversation_temperature, :decimal, default: nil
    field :conversation_success_rate, :decimal, default: nil

    # Icebreaker Telemetry
    field :icebreakers_shown, :integer, default: 0
    field :icebreakers_used, :integer, default: 0
    field :icebreaker_usage_rate, :decimal, default: nil
    field :average_bridge_effectiveness, :decimal, default: nil

    # Atmosphere Telemetry
    field :atmosphere_id, :binary_id
    field :atmosphere_usage_count, :integer, default: 0
    field :atmosphere_success_rate, :decimal, default: nil
    field :atmosphere_memory_rate, :decimal, default: nil
    field :atmosphere_relationship_rate, :decimal, default: nil

    # Reflection and Memory Telemetry
    field :memories_created, :integer, default: 0
    field :memory_creation_rate, :decimal, default: nil
    field :memory_revisit_rate, :decimal, default: nil

    field :most_common_memory_type, Ecto.Enum,
      values: [:QUOTE, :REFLECTION, :MOMENT, :SHARED_MEMORY],
      default: :MOMENT

    # Connection Continuation Telemetry
    field :relationships_created, :integer, default: 0
    field :relationship_creation_rate, :decimal, default: nil
    field :relationship_reconnection_rate, :decimal, default: nil
    field :average_relationship_lifespan, :float, default: 0.0

    # Safety and Trust Telemetry
    field :reports_submitted, :integer, default: 0
    field :blocks_created, :integer, default: 0
    field :emergency_exits, :integer, default: 0
    field :safety_review_rate, :decimal, default: nil
    field :resolved_safety_events, :integer, default: 0
    field :bot_fingerprints_blocked_count, :integer, default: 0
    field :tarpit_sandboxed_sessions_count, :integer, default: 0

    # Experience Funnel Conversions
    field :landing_to_door_rate, :decimal, default: nil
    field :door_to_match_rate, :decimal, default: nil
    field :match_to_conversation_rate, :decimal, default: nil
    field :conversation_to_memory_rate, :decimal, default: nil
    field :conversation_to_relationship_rate, :decimal, default: nil

    # Platform Health and Quality Metrics
    field :platform_health_score, :decimal, default: nil
    field :connection_success_score, :decimal, default: nil
    field :participant_satisfaction_score, :decimal, default: nil
    field :trust_score, :decimal, default: nil
    field :quality_weighted_conversations_rate, :decimal, default: nil

    # Retention Tracking Matrix
    field :n_day_active_retention_rate, :decimal, default: nil
    field :rolling_retention_rate, :decimal, default: nil
    field :bracket_cohort_retention_rate, :decimal, default: nil

    # Compliance and Regional Routing Counters
    field :jurisdiction_distribution, :map, default: %{}

    # Agent Performance Accuracy Telemetry
    field :queue_agent_accuracy, :decimal, default: nil
    field :compatibility_agent_accuracy, :decimal, default: nil
    field :icebreaker_agent_accuracy, :decimal, default: nil
    field :relationship_agent_accuracy, :decimal, default: nil
    field :safety_agent_accuracy, :decimal, default: nil

    # Long-term Trends Tracking
    field :trend_category, Ecto.Enum,
      values: [:DOOR, :CONVERSATION, :ICEBREAKER, :ATMOSPHERE, :MEMORY, :RELATIONSHIP, :SAFETY],
      default: :CONVERSATION

    field :trend_direction, Ecto.Enum, values: [:UP, :DOWN, :STABLE], default: :STABLE
    field :trend_strength, :decimal, default: nil

    # Privacy Guard Rails
    field :contains_personal_data, :boolean, default: false

    field :aggregation_level, Ecto.Enum,
      values: [:ANONYMIZED, :AGGREGATED, :SYSTEM_ONLY],
      default: :AGGREGATED
  end

  def changeset(analytics_record, attrs) do
    all_fields = [
      :created_at,
      :analytics_period,
      :analytics_date,
      :source_type,
      :source_count,
      :active_participants,
      :new_participants,
      :returning_participants,
      :average_session_duration,
      :just_talk_count,
      :keep_it_light_count,
      :explore_count,
      :something_real_count,
      :door_distribution,
      :matches_created,
      :average_queue_time_seconds,
      :queue_success_rate,
      :match_failure_rate,
      :recovery_mode_activation_count,
      :conversations_started,
      :conversations_completed,
      :average_conversation_duration,
      :average_conversation_temperature,
      :conversation_success_rate,
      :icebreakers_shown,
      :icebreakers_used,
      :icebreaker_usage_rate,
      :average_bridge_effectiveness,
      :atmosphere_id,
      :atmosphere_usage_count,
      :atmosphere_success_rate,
      :atmosphere_memory_rate,
      :atmosphere_relationship_rate,
      :memories_created,
      :memory_creation_rate,
      :memory_revisit_rate,
      :most_common_memory_type,
      :relationships_created,
      :relationship_creation_rate,
      :relationship_reconnection_rate,
      :average_relationship_lifespan,
      :reports_submitted,
      :blocks_created,
      :emergency_exits,
      :safety_review_rate,
      :resolved_safety_events,
      :bot_fingerprints_blocked_count,
      :tarpit_sandboxed_sessions_count,
      :landing_to_door_rate,
      :door_to_match_rate,
      :match_to_conversation_rate,
      :conversation_to_memory_rate,
      :conversation_to_relationship_rate,
      :platform_health_score,
      :connection_success_score,
      :participant_satisfaction_score,
      :trust_score,
      :quality_weighted_conversations_rate,
      :n_day_active_retention_rate,
      :rolling_retention_rate,
      :bracket_cohort_retention_rate,
      :jurisdiction_distribution,
      :queue_agent_accuracy,
      :compatibility_agent_accuracy,
      :icebreaker_agent_accuracy,
      :relationship_agent_accuracy,
      :safety_agent_accuracy,
      :trend_category,
      :trend_direction,
      :trend_strength,
      :contains_personal_data,
      :aggregation_level
    ]

    required_fields = all_fields -- [:atmosphere_id]

    analytics_record
    |> cast(attrs, all_fields)
    |> validate_required(required_fields)
    |> validate_inclusion(:contains_personal_data, [false], message: "must always be false")
    |> validate_decimal_bounds(:queue_success_rate)
    |> validate_decimal_bounds(:match_failure_rate)
    |> validate_decimal_bounds(:average_conversation_temperature)
    |> validate_decimal_bounds(:conversation_success_rate)
    |> validate_decimal_bounds(:icebreaker_usage_rate)
    |> validate_decimal_bounds(:average_bridge_effectiveness)
    |> validate_decimal_bounds(:atmosphere_success_rate)
    |> validate_decimal_bounds(:atmosphere_memory_rate)
    |> validate_decimal_bounds(:atmosphere_relationship_rate)
    |> validate_decimal_bounds(:memory_creation_rate)
    |> validate_decimal_bounds(:memory_revisit_rate)
    |> validate_decimal_bounds(:relationship_creation_rate)
    |> validate_decimal_bounds(:relationship_reconnection_rate)
    |> validate_decimal_bounds(:safety_review_rate)
    |> validate_decimal_bounds(:landing_to_door_rate)
    |> validate_decimal_bounds(:door_to_match_rate)
    |> validate_decimal_bounds(:match_to_conversation_rate)
    |> validate_decimal_bounds(:conversation_to_memory_rate)
    |> validate_decimal_bounds(:conversation_to_relationship_rate)
    |> validate_decimal_bounds(:platform_health_score)
    |> validate_decimal_bounds(:connection_success_score)
    |> validate_decimal_bounds(:participant_satisfaction_score)
    |> validate_decimal_bounds(:trust_score)
    |> validate_decimal_bounds(:quality_weighted_conversations_rate)
    |> validate_decimal_bounds(:n_day_active_retention_rate)
    |> validate_decimal_bounds(:rolling_retention_rate)
    |> validate_decimal_bounds(:bracket_cohort_retention_rate)
    |> validate_decimal_bounds(:queue_agent_accuracy)
    |> validate_decimal_bounds(:compatibility_agent_accuracy)
    |> validate_decimal_bounds(:icebreaker_agent_accuracy)
    |> validate_relationship_agent_accuracy()
    |> validate_decimal_bounds(:safety_agent_accuracy)
    |> validate_decimal_bounds(:trend_strength)
  end

  defp validate_relationship_agent_accuracy(changeset) do
    validate_decimal_bounds(changeset, :relationship_agent_accuracy)
  end

  defp validate_decimal_bounds(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case Decimal.compare(value, Decimal.new("0.0000")) do
        :lt ->
          [{field, "cannot be less than 0.0000"}]

        _ ->
          case Decimal.compare(value, Decimal.new("1.0000")) do
            :gt -> [{field, "cannot be greater than 1.0000"}]
            _ -> []
          end
      end
    end)
  end
end
