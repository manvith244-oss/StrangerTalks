defmodule StrangertalksNew.LearningRecordTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.LearningRecords
  alias StrangertalksNew.Repo

  @valid_time DateTime.from_naive!(~N[2026-07-04 12:00:00.000000], "Etc/UTC")

  setup do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant.participant_id,
        participant_b_id: participant.participant_id,
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

    {:ok, conv} =
      StrangertalksNew.Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: participant.participant_id,
        participant_b_id: participant.participant_id,
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

    %{participant: participant, match: match, conv: conv}
  end

  test "valid telemetry insertion executes successfully", %{participant: p, match: m, conv: c} do
    attrs = %{
      record_type: :ICEBREAKER_LEARNING,
      created_at: @valid_time,
      participant_id: p.participant_id,
      match_id: m.match_id,
      conversation_id: c.conversation_id,
      bridge_used: "static_opt_01",
      bridge_category: :UNIVERSAL,
      bridge_effectiveness_score: "4.5000",
      complexity_level: :MEDIUM,
      atmosphere_environment: :RAIN_WINDOW,
      outcome_signal: :SUCCESS
    }

    assert {:ok, %StrangertalksNew.LearningRecord{} = record} =
             LearningRecords.create_learning_record(attrs)

    assert record.learning_record_id != nil
  end

  test "required field validations block incomplete inserts" do
    assert {:error, changeset} = LearningRecords.create_learning_record(%{})
    assert errors_on(changeset).record_type == ["can't be blank"]
  end

  # Fixed key destructuring mismatch
  test "enum structural values are validated", %{participant: _p} do
    attrs = %{record_type: :INVALID_TYPE, created_at: @valid_time}
    assert {:error, changeset} = LearningRecords.create_learning_record(attrs)
    assert errors_on(changeset).record_type == ["is invalid"]
  end

  test "decimal fields enforce precision scales and bounding ranges" do
    attrs = %{
      record_type: :ATMOSPHERE_ADAPTATION,
      created_at: @valid_time,
      readiness_score: "10.0001"
    }

    assert {:error, changeset} = LearningRecords.create_learning_record(attrs)
    assert errors_on(changeset).readiness_score == ["must be between 0.0000 and 9.9999"]
  end

  test "business validations enforce icebreaker metadata alignment" do
    attrs = %{record_type: :ICEBREAKER_LEARNING, created_at: @valid_time}
    assert {:error, changeset} = LearningRecords.create_learning_record(attrs)
    assert errors_on(changeset).bridge_used == ["can't be blank"]
  end

  test "business validations enforce readiness biometric tracking profiles" do
    attrs = %{record_type: :READINESS_EVALUATION, created_at: @valid_time}
    assert {:error, changeset} = LearningRecords.create_learning_record(attrs)
    assert errors_on(changeset).readiness_score == ["can't be blank"]
  end

  test "account erasure triggers explicit foreign key nilification", %{
    participant: p,
    match: m,
    conv: c
  } do
    attrs = %{
      record_type: :ATMOSPHERE_ADAPTATION,
      created_at: @valid_time,
      participant_id: p.participant_id,
      match_id: m.match_id,
      conversation_id: c.conversation_id
    }

    {:ok, record} = LearningRecords.create_learning_record(attrs)

    # Clear upstream relational constraint blockers to safely isolate and test the target nilify effect
    Repo.delete!(c)
    Repo.delete!(m)
    Repo.delete!(p)

    fetched = LearningRecords.get_learning_record(record.learning_record_id)
    assert fetched.participant_id == nil
    assert fetched.match_id == nil
    assert fetched.conversation_id == nil
  end

  test "change_learning_record/2 generates form changeset contexts without database runtime modifications" do
    {:ok, record} =
      LearningRecords.create_learning_record(%{
        record_type: :ATMOSPHERE_ADAPTATION,
        created_at: @valid_time
      })

    changeset = LearningRecords.change_learning_record(record, %{outcome_signal: :ABANDONED})
    assert changeset.valid?
  end
end
