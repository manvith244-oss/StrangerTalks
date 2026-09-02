defmodule StrangertalksNew.Team4RetentionPrivacyClosureTest do
  use StrangertalksNew.DataCase, async: false

  import Ecto.Query

  alias StrangertalksNew.MatchingRules.BoundaryBlock
  alias StrangertalksNew.{Report, SafetyEvent, SafetyReview}

  alias StrangertalksNew.{
    MatchingRules,
    Repo,
    Reports,
    RetentionCleanup,
    SafetyEvents
  }

  @now ~U[2026-08-26 12:00:00.000000Z]
  @day 86_400

  setup do
    Agent.update(StrangertalksNew.QueueEngine.QueueState, fn _ -> %{} end)
    :ok
  end

  test "safety media honors just-before, exact, and just-after default and hard-max cutoffs" do
    before_default = age_seconds(30 * @day - 1)
    at_default = age_seconds(30 * @day)
    after_default = age_seconds(30 * @day + 1)

    assert RetentionCleanup.safety_media_disposition(before_default, false, @now) == :retain
    assert RetentionCleanup.safety_media_disposition(at_default, false, @now) == :delete
    assert RetentionCleanup.safety_media_disposition(after_default, false, @now) == :delete

    before_hard_max = age_seconds(60 * @day - 1)
    at_hard_max = age_seconds(60 * @day)
    after_hard_max = age_seconds(60 * @day + 1)

    assert RetentionCleanup.safety_media_disposition(before_hard_max, true, @now) == :retain
    assert RetentionCleanup.safety_media_disposition(at_hard_max, true, @now) == :delete
    assert RetentionCleanup.safety_media_disposition(after_hard_max, true, @now) == :delete
  end

  test "report rich evidence minimizes at exact final/open cutoffs, not one second early, and retry is idempotent" do
    {final_before, _} = report_fixture("final-before")
    {final_at, _} = report_fixture("final-at")
    {final_after, _} = report_fixture("final-after")
    {open_before, _} = report_fixture("open-before")
    {open_at, _} = report_fixture("open-at")
    {open_after, _} = report_fixture("open-after")

    set_final_report_time(final_before, age_seconds(90 * @day - 1))
    set_final_report_time(final_at, age_seconds(90 * @day))
    set_final_report_time(final_after, age_seconds(90 * @day + 1))

    set_open_report_time(open_before, age_seconds(180 * @day - 1))
    set_open_report_time(open_at, age_seconds(180 * @day))
    set_open_report_time(open_after, age_seconds(180 * @day + 1))

    assert {:ok, _} = RetentionCleanup.run(@now).reports

    assert Repo.get!(Report, final_before.report_id).reporter_context == "final-before"
    assert is_nil(Repo.get!(Report, final_at.report_id).reporter_context)
    assert is_nil(Repo.get!(Report, final_after.report_id).reporter_context)

    assert Repo.get!(Report, open_before.report_id).reporter_context == "open-before"
    assert is_nil(Repo.get!(Report, open_at.report_id).reporter_context)
    assert is_nil(Repo.get!(Report, open_after.report_id).reporter_context)

    assert Repo.get(Report, final_at.report_id)
    assert Repo.get(Report, open_at.report_id)

    assert {:ok, 0} = RetentionCleanup.run(@now).reports
  end

  test "resolved SafetyReview notes minimize at the exact 90-day cutoff and retry is idempotent" do
    {_report_before, review_before} = report_fixture("review-before")
    {_report_at, review_at} = report_fixture("review-at")
    {_report_after, review_after} = report_fixture("review-after")

    set_review_time(review_before, "review-before", age_seconds(90 * @day - 1))
    set_review_time(review_at, "review-at", age_seconds(90 * @day))
    set_review_time(review_after, "review-after", age_seconds(90 * @day + 1))

    assert {:ok, _} = RetentionCleanup.run(@now).safety_reviews

    assert Repo.get!(SafetyReview, review_before.safety_review_id).review_notes == "review-before"
    assert is_nil(Repo.get!(SafetyReview, review_at.safety_review_id).review_notes)
    assert is_nil(Repo.get!(SafetyReview, review_after.safety_review_id).review_notes)

    assert {:ok, 0} = RetentionCleanup.run(@now).safety_reviews
  end

  test "resolved SafetyEvent rich narrative minimizes at 180 days without erasing continuing authority" do
    before = safety_event_fixture("event-before", age_seconds(180 * @day - 1))
    at = safety_event_fixture("event-at", age_seconds(180 * @day))
    after_cutoff = safety_event_fixture("event-after", age_seconds(180 * @day + 1))

    assert {:ok, _} = RetentionCleanup.run(@now).safety_events

    retained = Repo.get!(SafetyEvent, before.safety_event_id)
    assert retained.report_description == "event-before"
    assert retained.safety_summary == %{"private" => "event-before"}
    assert retained.contains_sensitive_data

    for event <- [at, after_cutoff] do
      minimized = Repo.get!(SafetyEvent, event.safety_event_id)
      assert is_nil(minimized.report_description)
      assert minimized.safety_summary == %{}
      refute minimized.contains_sensitive_data
      assert minimized.action_type == :MATCH_RESTRICTION
      assert minimized.action_taken
    end

    assert {:ok, 0} = RetentionCleanup.run(@now).safety_events
  end

  test "BoundaryBlock cleanup honors cutoff, never removes active authority, and preserves inactive history required by an open safety event" do
    {active_a, active_b} = block_fixture()
    {before_a, before_b} = block_fixture()
    {at_a, at_b} = block_fixture()
    {after_a, after_b} = block_fixture()
    {protected_a, protected_b} = block_fixture()

    set_block(active_a, active_b, true, age_seconds(365 * @day))
    set_block(before_a, before_b, false, age_seconds(30 * @day - 1))
    set_block(at_a, at_b, false, age_seconds(30 * @day))
    set_block(after_a, after_b, false, age_seconds(30 * @day + 1))
    set_block(protected_a, protected_b, false, age_seconds(30 * @day))

    protected_event =
      safety_event_fixture("block-protection", @now, %{
        event_status: :OPEN,
        action_type: :NONE,
        action_taken: false,
        reporting_participant_id: protected_a.participant_id,
        target_participant_id: protected_b.participant_id
      })

    assert {:ok, _} = RetentionCleanup.run(@now).boundary_blocks

    assert block_exists?(active_a, active_b)
    assert block_exists?(before_a, before_b)
    refute block_exists?(at_a, at_b)
    refute block_exists?(after_a, after_b)
    assert block_exists?(protected_a, protected_b)

    Repo.update_all(
      from(event in SafetyEvent, where: event.safety_event_id == ^protected_event.safety_event_id),
      set: [event_status: :RESOLVED, review_completed_at: @now, updated_at: @now]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).boundary_blocks
    refute block_exists?(protected_a, protected_b)
    assert block_exists?(active_a, active_b)
    assert block_exists?(before_a, before_b)

    assert {:ok, 0} = RetentionCleanup.run(@now).boundary_blocks
  end

  defp report_fixture(label) do
    {conversation, reporter, _peer} = conversation_fixture()

    assert {:ok, report} =
             Reports.submit_conversation_report(
               conversation.conversation_id,
               reporter.participant_id,
               "HARASSMENT",
               label
             )

    {report, Repo.get_by!(SafetyReview, report_id: report.report_id)}
  end

  defp set_final_report_time(report, timestamp) do
    Repo.update_all(
      from(row in Report, where: row.report_id == ^report.report_id),
      set: [report_status: :RESOLVED, resolved_at: timestamp, updated_at: timestamp]
    )
  end

  defp set_open_report_time(report, timestamp) do
    Repo.update_all(
      from(row in Report, where: row.report_id == ^report.report_id),
      set: [report_status: :SUBMITTED, created_at: timestamp, updated_at: timestamp]
    )
  end

  defp set_review_time(review, notes, timestamp) do
    Repo.update_all(
      from(row in SafetyReview, where: row.safety_review_id == ^review.safety_review_id),
      set: [status: :RESOLVED, review_notes: notes, reviewed_at: timestamp, updated_at: timestamp]
    )
  end

  defp safety_event_fixture(label, timestamp, overrides \\ %{}) do
    attrs = %{
      event_status: :RESOLVED,
      event_type: :REPORT,
      severity_level: :LOW,
      action_type: :MATCH_RESTRICTION,
      action_taken: true,
      related_event_count: 0,
      participant_report_count: 0,
      participant_block_count: 0,
      report_description: label,
      safety_summary: %{"private" => label},
      contains_sensitive_data: true,
      created_at: timestamp,
      updated_at: timestamp,
      review_completed_at: timestamp
    }

    {:ok, event} = SafetyEvents.create_safety_event(Map.merge(attrs, overrides))
    event
  end

  defp block_fixture do
    blocker = participant_fixture()
    blocked = participant_fixture()
    assert {:ok, _} = MatchingRules.enforce_block(blocker.participant_id, blocked.participant_id, "TEST")
    {blocker, blocked}
  end

  defp set_block(blocker, blocked, active_status, timestamp) do
    Repo.update_all(
      from(block in BoundaryBlock,
        where:
          block.blocker_user_id == ^blocker.participant_id and
            block.blocked_user_id == ^blocked.participant_id
      ),
      set: [active_status: active_status, timestamp: timestamp]
    )
  end

  defp block_exists?(blocker, blocked) do
    Repo.get_by(BoundaryBlock,
      blocker_user_id: blocker.participant_id,
      blocked_user_id: blocked.participant_id
    )
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

  defp age_seconds(seconds), do: DateTime.add(@now, -seconds, :second)
end
