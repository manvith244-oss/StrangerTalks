defmodule StrangertalksNew.AnalyticsRecordTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.AnalyticsRecords
  alias Decimal

  @valid_time DateTime.from_naive!(~N[2026-07-03 12:00:00.000000], "Etc/UTC")
  @valid_date ~D[2026-07-03]

  @base_attrs %{
    analytics_period: :DAILY,
    analytics_date: @valid_date,
    created_at: @valid_time,
    source_type: :SYSTEM,
    source_count: 100,
    active_participants: 50,
    new_participants: 20,
    returning_participants: 30,
    average_session_duration: 3600.0,
    just_talk_count: 10,
    keep_it_light_count: 15,
    explore_count: 20,
    something_real_count: 5,
    door_distribution: %{"JUST_TALK" => 10, "EXPLORE" => 20},
    matches_created: 25,
    average_queue_time_seconds: 45.3,
    queue_success_rate: "0.8500",
    match_failure_rate: "0.1500",
    recovery_mode_activation_count: 0,
    conversations_started: 20,
    conversations_completed: 18,
    average_conversation_duration: 600.0,
    average_conversation_temperature: "0.7500",
    conversation_success_rate: "0.9000",
    icebreakers_shown: 40,
    icebreakers_used: 30,
    icebreaker_usage_rate: "0.7500",
    average_bridge_effectiveness: "0.8000",
    atmosphere_usage_count: 18,
    atmosphere_success_rate: "0.8500",
    atmosphere_memory_rate: "0.4000",
    atmosphere_relationship_rate: "0.3000",
    memories_created: 15,
    memory_creation_rate: "0.5000",
    memory_revisit_rate: "0.2000",
    most_common_memory_type: :MOMENT,
    relationships_created: 12,
    relationship_creation_rate: "0.6000",
    relationship_reconnection_rate: "0.2500",
    average_relationship_lifespan: 172_800.0,
    reports_submitted: 1,
    blocks_created: 0,
    emergency_exits: 0,
    safety_review_rate: "0.0500",
    resolved_safety_events: 1,
    bot_fingerprints_blocked_count: 5,
    tarpit_sandboxed_sessions_count: 2,
    landing_to_door_rate: "0.9500",
    door_to_match_rate: "0.8000",
    match_to_conversation_rate: "0.9000",
    conversation_to_memory_rate: "0.5000",
    conversation_to_relationship_rate: "0.4000",
    platform_health_score: "0.9200",
    connection_success_score: "0.8800",
    participant_satisfaction_score: "0.8500",
    trust_score: "0.9000",
    quality_weighted_conversations_rate: "0.7800",
    n_day_active_retention_rate: "0.4500",
    rolling_retention_rate: "0.5000",
    bracket_cohort_retention_rate: "0.4800",
    jurisdiction_distribution: %{"IN" => 100},
    queue_agent_accuracy: "0.9500",
    compatibility_agent_accuracy: "0.9200",
    icebreaker_agent_accuracy: "0.8800",
    relationship_agent_accuracy: "0.9000",
    safety_agent_accuracy: "0.9800",
    trend_category: :CONVERSATION,
    trend_direction: :STABLE,
    trend_strength: "0.5000",
    contains_personal_data: false,
    aggregation_level: :AGGREGATED
  }

  test "create_analytics_record/1 with valid attributes persists successfully" do
    assert {:ok, %StrangertalksNew.AnalyticsRecord{} = record} =
             AnalyticsRecords.create_analytics_record(@base_attrs)

    assert record.analytics_period == :DAILY
    assert Decimal.equal?(record.platform_health_score, Decimal.new("0.9200"))
  end

  test "create_analytics_record/1 flags missing operational parameters" do
    assert {:error, changeset} = AnalyticsRecords.create_analytics_record(%{})
    assert errors_on(changeset).analytics_period == ["can't be blank"]
  end

  test "create_analytics_record/1 validates range metrics bounds boundaries" do
    invalid_low = Map.put(@base_attrs, :platform_health_score, "-0.0001")
    assert {:error, changeset} = AnalyticsRecords.create_analytics_record(invalid_low)
    assert errors_on(changeset).platform_health_score == ["cannot be less than 0.0000"]

    invalid_high = Map.put(@base_attrs, :platform_health_score, "1.0001")
    assert {:error, changeset} = AnalyticsRecords.create_analytics_record(invalid_high)
    assert errors_on(changeset).platform_health_score == ["cannot be greater than 1.0000"]
  end

  test "create_analytics_record/1 blocks record if personal data flag is violated" do
    invalid_privacy = Map.put(@base_attrs, :contains_personal_data, true)
    assert {:error, changeset} = AnalyticsRecords.create_analytics_record(invalid_privacy)
    assert errors_on(changeset).contains_personal_data == ["must always be false"]
  end

  test "get_analytics_record/1 fetches the correct tracking profile entry" do
    {:ok, record} = AnalyticsRecords.create_analytics_record(@base_attrs)
    fetched = AnalyticsRecords.get_analytics_record(record.analytics_record_id)
    assert fetched.analytics_record_id == record.analytics_record_id
  end

  test "change_analytics_record/2 generates a valid modification changeset context" do
    {:ok, record} = AnalyticsRecords.create_analytics_record(@base_attrs)
    changeset = AnalyticsRecords.change_analytics_record(record, %{trend_direction: :UP})
    assert changeset.valid?
  end
end
