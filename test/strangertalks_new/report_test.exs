defmodule StrangertalksNew.ReportTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.Reports
  alias StrangertalksNew.Report

  @valid_time DateTime.from_naive!(~N[2026-07-03 14:41:44.000000], "Etc/UTC")

  setup do
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

    {:ok, message} =
      StrangertalksNew.Messages.create_message(%{
        conversation_id: conversation.conversation_id,
        sender_id: participant_b.participant_id,
        content: "Abusive Content",
        created_at: @valid_time,
        expected_sequence_id: 1
      })

    valid_attrs = %{
      created_at: @valid_time,
      updated_at: @valid_time,
      reporting_participant_id: participant_a.participant_id,
      reported_participant_id: participant_b.participant_id,
      conversation_id: conversation.conversation_id,
      reported_message_id: message.message_id,
      report_category: :HARASSMENT,
      report_status: :SUBMITTED,
      reporter_context: "Targeted language used in session."
    }

    {:ok, valid_attrs: valid_attrs, participant_a: participant_a}
  end

  test "create_report/1 with valid attributes persists accurately", %{valid_attrs: attrs} do
    assert {:ok, %Report{} = report} = Reports.create_report(attrs)
    assert report.report_status == :SUBMITTED
    assert report.report_category == :HARASSMENT
    assert report.reported_message_id != nil
  end

  test "create_report/1 checks required fields validation", %{valid_attrs: attrs} do
    invalid = Map.delete(attrs, :report_category)
    assert {:error, changeset} = Reports.create_report(invalid)
    assert "can't be blank" in errors_on(changeset).report_category
  end

  test "create_report/1 enforces explicit enum value constraint bounds", %{valid_attrs: attrs} do
    invalid = Map.put(attrs, :report_category, :INVALID_CATEGORY)
    assert {:error, changeset} = Reports.create_report(invalid)
    assert "is invalid" in errors_on(changeset).report_category
  end

  test "create_report/1 enforces self-reporting prohibition constraint", %{
    valid_attrs: attrs,
    participant_a: participant_a
  } do
    invalid = Map.put(attrs, :reported_participant_id, participant_a.participant_id)
    assert {:error, changeset} = Reports.create_report(invalid)
    assert "cannot report yourself" in errors_on(changeset).reporting_participant_id
  end

  test "create_report/1 checks foreign key constraint bounds", %{valid_attrs: attrs} do
    invalid = Map.put(attrs, :conversation_id, Ecto.UUID.generate())
    assert {:error, changeset} = Reports.create_report(invalid)
    assert "does not exist" in errors_on(changeset).conversation_id
  end

  test "change_report/2 tracks evaluation changes state configuration", %{valid_attrs: attrs} do
    {:ok, report} = Reports.create_report(attrs)
    changeset = Reports.change_report(report, %{report_status: :UNDER_REVIEW})
    assert changeset.changes == %{report_status: :UNDER_REVIEW}
  end
end
