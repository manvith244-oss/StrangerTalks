defmodule StrangertalksNew.SafetyEventsTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.SafetyEvents
  alias Decimal

  @valid_time DateTime.from_naive!(~N[2026-07-03 12:00:00.000000], "Etc/UTC")

  @base_attrs %{
    event_status: :OPEN,
    event_type: :REPORT,
    severity_level: :HIGH,
    related_event_count: 0,
    participant_report_count: 0,
    participant_block_count: 0,
    created_at: @valid_time,
    updated_at: @valid_time,
    confidence_score: "0.8500",
    safety_summary: %{"reason" => "pattern_detected"}
  }

  setup do
    # 1. Root Dependency: Participants
    {:ok, p_a} = StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})
    {:ok, p_b} = StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    # 2. Match Dependency
    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        door_type: :JUST_TALK,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        compatibility_score: "0.9500",
        opportunity_score: "0.8000",
        scarcity_adjustment: "0.1000",
        conversation_temperature: "0.5000",
        mutual_participation_score: "0.7000",
        conversation_health_score: "0.9000",
        match_quality_score: "0.8800",
        created_at: @valid_time,
        queue_entry_time: @valid_time,
        match_found_time: @valid_time,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: true,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false,
        learning_version: "v1"
      })

    # 3. Conversation Dependency
    {:ok, conv} =
      StrangertalksNew.Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        conversation_status: :ACTIVE,
        created_at: @valid_time,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        participation_balance_score: "0.0000",
        message_exchange_rate: 0.0,
        conversation_depth_score: "0.0000",
        conversation_temperature: "0.5000",
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        bridge_effectiveness_score: "0.0000",
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        conversation_success_score: "0.0000",
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        safety_score: "0.0000",
        learning_processed: false,
        learning_version: "v1",
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    # 4. Relationship Dependency (Fixed Validation Constraints)
    {:ok, rel} =
      StrangertalksNew.Relationships.create_relationship(%{
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        match_id: match.match_id,
        conversation_id: conv.conversation_id,
        relationship_status: :ACTIVE,
        created_at: @valid_time,
        updated_at: @valid_time,
        first_conversation_at: @valid_time,
        origin_door_type: :JUST_TALK,
        origin_conversation_id: conv.conversation_id,
        origin_match_id: match.match_id,
        participant_a_accepted: true,
        participant_b_accepted: true,
        reconnection_priority: 0,
        relationship_strength_score: "0.0000",
        relationship_probability: "0.0000",
        relationship_temperature: "0.0000",
        atmosphere_history: %{},
        relationship_summary: %{},
        continuation_probability: "0.0000",
        # Fails validation if explicitly set to false during required validation checks
        reconnect_eligible: true,
        learning_version: "v1"
      })

    %{p_a: p_a, p_b: p_b, match: match, conv: conv, rel: rel}
  end

  test "create_safety_event/1 with valid attributes inserts successfully",
       %{p_a: p_a, p_b: p_b, match: match, conv: conv, rel: rel} do
    attrs =
      Map.merge(@base_attrs, %{
        reporting_participant_id: p_a.participant_id,
        target_participant_id: p_b.participant_id,
        match_id: match.match_id,
        conversation_id: conv.conversation_id,
        relationship_id: rel.relationship_id
      })

    assert {:ok, %StrangertalksNew.SafetyEvent{} = safety_event} =
             SafetyEvents.create_safety_event(attrs)

    assert safety_event.event_status == :OPEN
    assert Decimal.equal?(safety_event.confidence_score, Decimal.new("0.8500"))
  end

  test "create_safety_event/1 fails when required fields are missing" do
    assert {:error, changeset} = SafetyEvents.create_safety_event(%{})
    assert errors_on(changeset).event_status == ["can't be blank"]
    assert errors_on(changeset).event_type == ["can't be blank"]
  end

  test "create_safety_event/1 enforces confidence_score validation range" do
    invalid_low_attrs = Map.put(@base_attrs, :confidence_score, "-0.0100")
    assert {:error, changeset} = SafetyEvents.create_safety_event(invalid_low_attrs)
    assert errors_on(changeset).confidence_score == ["must be between 0.0 and 1.0"]

    invalid_high_attrs = Map.put(@base_attrs, :confidence_score, "1.0001")
    assert {:error, changeset} = SafetyEvents.create_safety_event(invalid_high_attrs)
    assert errors_on(changeset).confidence_score == ["must be between 0.0 and 1.0"]
  end

  test "create_safety_event/1 validates enums correctly" do
    invalid_enum_attrs = Map.put(@base_attrs, :event_status, :INVALID_STATUS)
    assert {:error, changeset} = SafetyEvents.create_safety_event(invalid_enum_attrs)
    assert errors_on(changeset).event_status == ["is invalid"]
  end

  test "get_safety_event/1 returns the correct safety record", %{p_a: p_a} do
    attrs = Map.put(@base_attrs, :reporting_participant_id, p_a.participant_id)
    {:ok, safety_event} = SafetyEvents.create_safety_event(attrs)

    fetched = SafetyEvents.get_safety_event(safety_event.safety_event_id)
    assert fetched.safety_event_id == safety_event.safety_event_id
  end

  test "change_safety_event/2 returns a valid baseline modifications changeset" do
    {:ok, safety_event} = SafetyEvents.create_safety_event(@base_attrs)
    changeset = SafetyEvents.change_safety_event(safety_event, %{event_status: :UNDER_REVIEW})
    assert changeset.valid?
  end
end
