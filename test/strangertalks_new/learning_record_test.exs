defmodule StrangertalksNew.LearningRecordTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.{LearningRecord, LearningRecords, Repo}

  @valid_time DateTime.from_naive!(~N[2026-07-04 12:00:00.000000], "Etc/UTC")

  setup do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, participant_b} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant.participant_id,
        participant_b_id: participant_b.participant_id,
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
        learning_processed: false
      })

    {:ok, conv} =
      StrangertalksNew.Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: participant.participant_id,
        participant_b_id: participant_b.participant_id,
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
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    %{participant: participant, match: match, conv: conv}
  end

  test "legacy participant-linked LearningRecord writer is disabled for V1", %{
    participant: participant
  } do
    assert {:error, :legacy_learning_record_write_disabled} =
             LearningRecords.create_learning_record(%{
               record_type: :READINESS_EVALUATION,
               created_at: @valid_time,
               participant_id: participant.participant_id,
               readiness_score: "5.0000",
               keystroke_latency_variance: "2.0000"
             })
  end

  test "legacy schema still accepts its historical valid shape when inspected directly", %{
    participant: p,
    match: m,
    conv: c
  } do
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

    assert {:ok, %LearningRecord{} = record} = legacy_insert(attrs)
    assert record.learning_record_id != nil
  end

  test "legacy schema required-field validation remains covered" do
    changeset = LearningRecord.changeset(%LearningRecord{}, %{})
    refute changeset.valid?
    assert errors_on(changeset).record_type == ["can't be blank"]
  end

  test "legacy schema enum validation remains covered" do
    changeset =
      LearningRecord.changeset(%LearningRecord{}, %{
        record_type: :INVALID_TYPE,
        created_at: @valid_time
      })

    refute changeset.valid?
    assert errors_on(changeset).record_type == ["is invalid"]
  end

  test "legacy schema decimal ranges remain covered" do
    changeset =
      LearningRecord.changeset(%LearningRecord{}, %{
        record_type: :ATMOSPHERE_ADAPTATION,
        created_at: @valid_time,
        readiness_score: "10.0001"
      })

    assert errors_on(changeset).readiness_score == ["must be between 0.0000 and 9.9999"]
  end

  test "legacy schema icebreaker alignment validation remains covered" do
    changeset =
      LearningRecord.changeset(%LearningRecord{}, %{
        record_type: :ICEBREAKER_LEARNING,
        created_at: @valid_time
      })

    assert errors_on(changeset).bridge_used == ["can't be blank"]
  end

  test "legacy readiness-profile validation remains covered without enabling production writes" do
    changeset =
      LearningRecord.changeset(%LearningRecord{}, %{
        record_type: :READINESS_EVALUATION,
        created_at: @valid_time
      })

    assert errors_on(changeset).readiness_score == ["can't be blank"]
  end

  test "pre-existing legacy rows retain account-erasure foreign-key nilification", %{
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

    {:ok, record} = legacy_insert(attrs)

    Repo.delete!(c)
    Repo.delete!(m)
    Repo.delete!(p)

    fetched = LearningRecords.get_learning_record(record.learning_record_id)
    assert fetched.participant_id == nil
    assert fetched.match_id == nil
    assert fetched.conversation_id == nil
  end

  test "legacy rows still expose schema changesets without reopening the writer" do
    {:ok, record} =
      legacy_insert(%{
        record_type: :ATMOSPHERE_ADAPTATION,
        created_at: @valid_time
      })

    changeset = LearningRecords.change_learning_record(record, %{outcome_signal: :ABANDONED})
    assert changeset.valid?
  end

  defp legacy_insert(attrs) do
    %LearningRecord{}
    |> LearningRecord.changeset(attrs)
    |> Repo.insert()
  end
end
