defmodule StrangertalksNew.RelationshipTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.Relationships
  alias StrangertalksNew.Relationship

  @valid_time DateTime.from_naive!(~N[2026-07-03 00:00:00.000000], "Etc/UTC")

  setup do
    # Instantiate Context Chains Using Existing APIs (Zero Fake UUIDs)
    {:ok, participant_a} =
      StrangertalksNew.Participants.create_participant(%{
        created_at: @valid_time
      })

    {:ok, participant_b} =
      StrangertalksNew.Participants.create_participant(%{
        created_at: @valid_time
      })

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :SOMETHING_REAL,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: @valid_time,
        queue_entry_time: @valid_time,
        match_found_time: @valid_time,
        compatibility_score: "0.9500",
        opportunity_score: "0.8500",
        scarcity_adjustment: "0.0000",
        conversation_temperature: "0.5000",
        mutual_participation_score: "0.9000",
        conversation_health_score: "0.9200",
        match_quality_score: "0.9400",
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
        created_at: @valid_time,
        door_type: :SOMETHING_REAL,
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        participation_balance_score: "0.5000",
        message_exchange_rate: 0.0,
        conversation_depth_score: "0.5000",
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
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    valid_attrs = %{
      created_at: @valid_time,
      updated_at: @valid_time,
      first_conversation_at: @valid_time,
      relationship_status: :ACTIVE,
      origin_door_type: :SOMETHING_REAL,
      participant_a_id: participant_a.participant_id,
      participant_b_id: participant_b.participant_id,
      origin_conversation_id: conversation.conversation_id,
      origin_match_id: match.match_id,
      participant_a_accepted: true,
      participant_b_accepted: true,
      allow_reconnection: true,
      reconnection_eligible: true,
      participant_a_closed: false,
      participant_b_closed: false,
      participant_a_blocked: false,
      participant_b_blocked: false,
      learning_processed: false,
      conversation_count: 1,
      memory_count: 0,
      reconnection_count: 0,
      shared_memory_count: 0,
      private_note_count: 0,
      reconnection_priority: "0.7500",
      relationship_strength_score: "0.8500",
      continuation_probability: "0.9000",
      relationship_temperature: "0.6500",
      atmosphere_history: %{"history" => []},
      relationship_summary: %{"summary" => "initial"}
    }

    {:ok, valid_attrs: valid_attrs}
  end

  test "create_relationship/1 with valid attributes persists accurately", %{valid_attrs: attrs} do
    assert {:ok, %Relationship{} = rel} = Relationships.create_relationship(attrs)
    assert rel.relationship_status == :ACTIVE
    assert rel.origin_door_type == :SOMETHING_REAL
    assert %Decimal{} = rel.relationship_strength_score
  end

  test "create_relationship/1 checks required fields validation", %{valid_attrs: attrs} do
    invalid = Map.delete(attrs, :relationship_status)
    assert {:error, changeset} = Relationships.create_relationship(invalid)
    assert "can't be blank" in errors_on(changeset).relationship_status
  end

  test "create_relationship/1 enforces explicit enum value constraint parameters", %{
    valid_attrs: attrs
  } do
    invalid = Map.put(attrs, :relationship_status, :INVALID_STATE)
    assert {:error, changeset} = Relationships.create_relationship(invalid)
    assert "is invalid" in errors_on(changeset).relationship_status
  end

  test "change_relationship/2 outputs an evaluation configuration tracking differences", %{
    valid_attrs: attrs
  } do
    {:ok, rel} = Relationships.create_relationship(attrs)
    changeset = Relationships.change_relationship(rel, %{relationship_status: :QUIET})
    assert changeset.changes == %{relationship_status: :QUIET}
  end
end
