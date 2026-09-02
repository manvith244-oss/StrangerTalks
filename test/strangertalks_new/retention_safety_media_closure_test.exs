defmodule StrangertalksNew.RetentionSafetyMediaClosureTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{ReportSafetyMedia, SafetyReview}
  alias StrangertalksNew.{Repo, Reports, RetentionCleanup, SafetyReviews}

  @now ~U[2026-08-26 12:00:00Z]

  test "only an authoritative IN_REVIEW SafetyReview extends 30-60 day raw safety media" do
    {conversation, reporter, _peer} = conversation_fixture()

    {no_review_report, no_review_media} =
      report_with_media(conversation, reporter, "no-review", days_ago(30))

    no_review = Repo.get_by!(SafetyReview, report_id: no_review_report.report_id)
    Repo.delete!(no_review)

    {_pending_report, pending_media} =
      report_with_media(conversation, reporter, "pending", days_ago(45))

    {resolved_report, resolved_media} =
      report_with_media(conversation, reporter, "resolved", days_ago(45))

    resolved_review = Repo.get_by!(SafetyReview, report_id: resolved_report.report_id)

    assert {:ok, resolved_review} =
             SafetyReviews.resolve_review(
               resolved_review.safety_review_id,
               :LOW,
               "no action",
               "retention closure fixture"
             )

    assert resolved_review.status == :RESOLVED

    {dismissed_report, dismissed_media} =
      report_with_media(conversation, reporter, "dismissed", days_ago(45))

    dismissed_review = Repo.get_by!(SafetyReview, report_id: dismissed_report.report_id)

    assert {:ok, dismissed_review} =
             SafetyReviews.dismiss_review(
               dismissed_review.safety_review_id,
               "dismissed",
               "retention closure fixture"
             )

    assert dismissed_review.status == :DISMISSED

    {active_report, active_media} =
      report_with_media(conversation, reporter, "active-45", days_ago(45))

    active_review = Repo.get_by!(SafetyReview, report_id: active_report.report_id)
    assert active_report.report_status == :SUBMITTED
    assert {:ok, active_review} = SafetyReviews.start_review(active_review.safety_review_id)
    assert active_review.status == :IN_REVIEW
    assert Repo.reload(active_report).report_status == :SUBMITTED

    {hard_max_report, hard_max_media} =
      report_with_media(conversation, reporter, "active-60", days_ago(60))

    hard_max_review = Repo.get_by!(SafetyReview, report_id: hard_max_report.report_id)
    assert hard_max_report.report_status == :SUBMITTED
    assert {:ok, hard_max_review} = SafetyReviews.start_review(hard_max_review.safety_review_id)
    assert hard_max_review.status == :IN_REVIEW
    assert Repo.reload(hard_max_report).report_status == :SUBMITTED

    assert {:ok, _} = RetentionCleanup.run(@now).safety_media

    refute Repo.get(ReportSafetyMedia, no_review_media.safety_media_id)
    refute Repo.get(ReportSafetyMedia, pending_media.safety_media_id)
    refute Repo.get(ReportSafetyMedia, resolved_media.safety_media_id)
    refute Repo.get(ReportSafetyMedia, dismissed_media.safety_media_id)
    assert Repo.get(ReportSafetyMedia, active_media.safety_media_id)
    refute Repo.get(ReportSafetyMedia, hard_max_media.safety_media_id)
  end

  defp report_with_media(conversation, reporter, label, created_at) do
    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               reporter.participant_id,
               "HARASSMENT",
               "retention-#{label}"
             )

    bytes = <<1, 2, 3, 4>>

    media =
      %ReportSafetyMedia{}
      |> ReportSafetyMedia.changeset(%{
        report_id: report.report_id,
        media_bytes: bytes,
        media_type: "image/jpeg",
        byte_size: byte_size(bytes),
        created_at: created_at
      })
      |> Repo.insert!()

    {report, media}
  end

  defp conversation_fixture do
    reporter = participant_fixture()
    peer = participant_fixture()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: @now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: reporter.participant_id,
        participant_b_id: peer.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: @now,
        match_found_time: @now,
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
        created_at: @now,
        match_id: matching.match_id,
        participant_a_id: reporter.participant_id,
        participant_b_id: peer.participant_id,
        conversation_status: :ACTIVE,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    {conversation, reporter, peer}
  end

  defp participant_fixture do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: @now,
        last_active_at: @now
      })

    participant
  end

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400, :second)
end
