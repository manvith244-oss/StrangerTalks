defmodule StrangertalksNew.RetentionCleanupDbTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Accounts.{AccountSession, GoogleOauthAttempt, PrivateAccount}
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.Memories
  alias StrangertalksNew.Memory
  alias StrangertalksNew.Matching
  alias StrangertalksNew.MatchingRules.BoundaryBlock
  alias StrangertalksNew.Report
  alias StrangertalksNew.ReportSafetyMedia
  alias StrangertalksNew.SafetyReview
  alias StrangertalksNew.{Accounts, MatchingRules, Reflections, Reports, RetentionCleanup, SafetyReviews}

  @now ~U[2026-08-26 12:00:00Z]

  setup do
    Agent.update(StrangertalksNew.QueueEngine.QueueState, fn _ -> %{} end)
    :ok
  end

  test "29-day safety media remains and 30-day eligible safety media is deleted" do
    {_conversation, reporter, _peer, report} = report_fixture()
    media = safety_media_fixture(report, days_ago(29))

    assert {:ok, _} = RetentionCleanup.run(@now).safety_media
    assert Repo.get(ReportSafetyMedia, media.safety_media_id)

    Repo.update_all(
      from(m in ReportSafetyMedia, where: m.safety_media_id == ^media.safety_media_id),
      set: [created_at: days_ago(30)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).safety_media
    refute Repo.get(ReportSafetyMedia, media.safety_media_id)
    assert Repo.get(StrangertalksNew.Participant, reporter.participant_id)
  end

  test "active human review extends safety media after day 30 but never beyond day 60" do
    {_conversation, _reporter, _peer, report} = report_fixture()
    media = safety_media_fixture(report, days_ago(45))
    review = Repo.get_by!(SafetyReview, report_id: report.report_id)

    assert {:ok, %{status: :IN_REVIEW}} = SafetyReviews.start_review(review.safety_review_id)

    assert {:ok, _} = RetentionCleanup.run(@now).safety_media
    assert Repo.get(ReportSafetyMedia, media.safety_media_id)

    Repo.update_all(
      from(m in ReportSafetyMedia, where: m.safety_media_id == ^media.safety_media_id),
      set: [created_at: days_ago(60)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).safety_media
    refute Repo.get(ReportSafetyMedia, media.safety_media_id)
  end

  test "resolved report evidence and final review notes are removed after 90 days" do
    {_conversation, _reporter, _peer, report} = report_fixture("selected evidence")
    review = Repo.get_by!(SafetyReview, report_id: report.report_id)

    assert {:ok, %{status: :IN_REVIEW}} = SafetyReviews.start_review(review.safety_review_id)

    assert {:ok, resolved} =
             SafetyReviews.resolve_review(review.safety_review_id, :LOW, "resolved", "rich notes")

    old = days_ago(90)

    Repo.update_all(
      from(r in Report, where: r.report_id == ^report.report_id),
      set: [report_status: :RESOLVED, resolved_at: old, updated_at: old]
    )

    Repo.update_all(
      from(r in SafetyReview, where: r.safety_review_id == ^resolved.safety_review_id),
      set: [reviewed_at: old, updated_at: old]
    )

    result = RetentionCleanup.run(@now)
    assert {:ok, _} = result.reports
    assert {:ok, _} = result.safety_reviews

    assert Repo.get!(Report, report.report_id).reporter_context == nil
    assert Repo.get!(SafetyReview, resolved.safety_review_id).review_notes == nil
  end

  test "open report remains before its 180-day maximum" do
    {_conversation, _reporter, _peer, report} = report_fixture("still needed")

    Repo.update_all(
      from(r in Report, where: r.report_id == ^report.report_id),
      set: [created_at: days_ago(179), updated_at: days_ago(179)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).reports
    assert Repo.get!(Report, report.report_id).reporter_context == "still needed"
  end

  test "active BoundaryBlock is never deleted; inactive historical block cleans after 30 days" do
    a = participant_fixture()
    b = participant_fixture()
    assert {:ok, _} = MatchingRules.enforce_block(a.participant_id, b.participant_id, "TEST")

    assert {:ok, _} = RetentionCleanup.run(@now).boundary_blocks
    assert Repo.get_by(BoundaryBlock, blocker_user_id: a.participant_id, blocked_user_id: b.participant_id)

    Repo.update_all(
      from(block in BoundaryBlock,
        where:
          block.blocker_user_id == ^a.participant_id and
            block.blocked_user_id == ^b.participant_id
      ),
      set: [active_status: false, timestamp: days_ago(30)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).boundary_blocks

    refute Repo.get_by(BoundaryBlock,
             blocker_user_id: a.participant_id,
             blocked_user_id: b.participant_id
           )
  end

  test "inactive guest without dependencies is deleted; active safety dependency keeps guest" do
    old = days_ago(30)
    guest = participant_fixture(%{presence_state: :OFFLINE, last_active_at: old, created_at: old})

    assert {:ok, _} = RetentionCleanup.run(@now).inactive_guests
    refute Repo.get(StrangertalksNew.Participant, guest.participant_id)

    protected = participant_fixture(%{presence_state: :OFFLINE, last_active_at: old, created_at: old})
    peer = participant_fixture()
    assert {:ok, _} = MatchingRules.enforce_block(protected.participant_id, peer.participant_id, "TEST")

    assert {:ok, _} = RetentionCleanup.run(@now).inactive_guests
    assert Repo.get(StrangertalksNew.Participant, protected.participant_id)
  end

  test "ACTIVE and PAUSED Conversations survive while eligible terminal Conversation expires" do
    {active, _a, _b, _match} = conversation_fixture(:ACTIVE, nil)
    {paused, _c, _d, _match2} = conversation_fixture(:PAUSED, nil)
    {terminal, _e, _f, _match3} = conversation_fixture(:ENDED, days_ago(30))

    assert {:ok, _} = RetentionCleanup.run(@now).conversations
    assert Repo.get(Conversation, active.conversation_id)
    assert Repo.get(Conversation, paused.conversation_id)
    refute Repo.get(Conversation, terminal.conversation_id)
  end

  test "terminal Conversation referenced by an active Report survives cleanup" do
    {conversation, reporter, _peer, _match} = conversation_fixture(:ENDED, days_ago(30))
    assert {:ok, report} = Reports.submit_conversation_report(conversation.conversation_id, reporter.participant_id, "SPAM", "evidence")

    assert {:ok, _} = RetentionCleanup.run(@now).conversations
    assert Repo.get(Conversation, conversation.conversation_id)
    assert Repo.get(Report, report.report_id)
  end

  test "terminal Match referenced by Conversation survives cleanup" do
    {_conversation, _a, _b, matching} = conversation_fixture(:ACTIVE, nil)

    Repo.update_all(
      from(m in Matching, where: m.match_id == ^matching.match_id),
      set: [match_status: :ENDED, match_end_time: days_ago(30)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).matches
    assert Repo.get(Matching, matching.match_id)
  end

  test "expired OAuth attempts disappear while valid attempt remains" do
    assert {:ok, expired, _state1, _nonce1} = Accounts.start_oauth("SIGN_IN_EXISTING", nil)
    assert {:ok, valid, _state2, _nonce2} = Accounts.start_oauth("SIGN_IN_EXISTING", nil)

    Repo.update_all(
      from(a in GoogleOauthAttempt, where: a.oauth_attempt_id == ^expired.oauth_attempt_id),
      set: [expires_at: hours_ago(25)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).oauth_attempts
    refute Repo.get(GoogleOauthAttempt, expired.oauth_attempt_id)
    assert Repo.get(GoogleOauthAttempt, valid.oauth_attempt_id)
  end

  test "expired and revoked sessions purge after 30 days while current session remains" do
    participant = participant_fixture()
    account = private_account_fixture(participant)

    expired = session_fixture(account, expires_at: days_ago(31))
    revoked = session_fixture(account, expires_at: DateTime.add(@now, 86_400, :second), revoked_at: days_ago(30))
    current = session_fixture(account, expires_at: DateTime.add(@now, 86_400, :second))

    assert {:ok, _} = RetentionCleanup.run(@now).account_sessions
    refute Repo.get(AccountSession, expired.account_session_id)
    refute Repo.get(AccountSession, revoked.account_session_id)
    assert Repo.get(AccountSession, current.account_session_id)
  end

  test "expired composer grant disappears after 24-hour physical cleanup grace" do
    participant = participant_fixture()
    assert {:ok, %{grant: grant}} = Reflections.open_composer_grant(participant.participant_id, %{})

    Repo.update_all(
      from(g in StrangertalksNew.Reflections.ComposerGrant, where: g.grant_id == ^grant.grant_id),
      set: [state: "CONSUMED", updated_at: hours_ago(24)]
    )

    assert {:ok, _} = RetentionCleanup.run(@now).composer_grants
    refute Repo.get(StrangertalksNew.Reflections.ComposerGrant, grant.grant_id)
  end

  test "deleted Memory hard purges after seven days while active Memory remains" do
    {conversation, owner, _peer, matching} = conversation_fixture(:ACTIVE, nil)
    deleted = memory_fixture(conversation, matching, owner, days_ago(7))
    active = memory_fixture(conversation, matching, owner, nil)

    assert {:ok, _} = RetentionCleanup.run(@now).deleted_memories
    refute Repo.get(Memory, deleted.memory_id)
    assert Repo.get(Memory, active.memory_id)
  end

  test "cleanup twice remains safe with real database categories" do
    participant_fixture(%{presence_state: :OFFLINE, last_active_at: days_ago(30), created_at: days_ago(30)})

    first = RetentionCleanup.run(@now)
    second = RetentionCleanup.run(@now)

    assert {:ok, _} = first.inactive_guests
    assert {:ok, 0} = second.inactive_guests
  end

  defp report_fixture(evidence \\ "selected evidence") do
    {conversation, reporter, peer, _match} = conversation_fixture(:ENDED, @now)
    assert {:ok, report} = Reports.submit_conversation_report(conversation.conversation_id, reporter.participant_id, "HARASSMENT", evidence)
    {conversation, reporter, peer, report}
  end

  defp safety_media_fixture(report, created_at) do
    bytes = <<1, 2, 3>>

    %ReportSafetyMedia{}
    |> ReportSafetyMedia.changeset(%{
      report_id: report.report_id,
      media_bytes: bytes,
      media_type: "image/jpeg",
      byte_size: byte_size(bytes),
      created_at: created_at
    })
    |> Repo.insert!()
  end

  defp participant_fixture(attrs \\ %{}) do
    defaults = %{presence_state: :OFFLINE, created_at: @now, last_active_at: @now}
    {:ok, participant} = StrangertalksNew.Participants.create_participant(Map.merge(defaults, attrs))
    participant
  end

  defp conversation_fixture(status, ended_at) do
    a = participant_fixture(%{presence_state: :ONLINE})
    b = participant_fixture(%{presence_state: :ONLINE})
    matching = match_fixture(a, b)

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: @now,
        match_id: matching.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: status,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: status in [:ENDED, :COMPLETED],
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0,
        ended_at: ended_at
      })

    {conversation, a, b, matching}
  end

  defp match_fixture(a, b) do
    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: @now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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

    matching
  end

  defp private_account_fixture(participant) do
    %PrivateAccount{}
    |> change(%{
      participant_id: participant.participant_id,
      created_at: @now,
      updated_at: @now,
      last_signed_in_at: @now
    })
    |> Repo.insert!()
  end

  defp session_fixture(account, opts) do
    attrs = %{
      account_id: account.account_id,
      session_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()),
      created_at: @now,
      last_used_at: @now,
      expires_at: Keyword.fetch!(opts, :expires_at),
      revoked_at: Keyword.get(opts, :revoked_at)
    }

    %AccountSession{} |> change(attrs) |> Repo.insert!()
  end

  defp memory_fixture(conversation, matching, owner, deleted_at) do
    attrs = %{
      memory_status: :ACTIVE,
      memory_type: :REFLECTION,
      title: "Retention test memory",
      memory_content: "Explicitly user-kept content",
      door_type: :JUST_TALK,
      atmosphere_id: Ecto.UUID.generate(),
      atmosphere_name: "Test",
      view_count: 1,
      revisited_count: 0,
      memory_significance_score: Decimal.new("0.5"),
      memory_category: :DISCOVERY,
      learning_processed: false,
      eligible_for_revisit: true,
      match_id: matching.match_id,
      conversation_id: conversation.conversation_id,
      owner_participant_id: owner.participant_id,
      deleted_at: deleted_at
    }

    {:ok, memory} = Memories.create_memory(attrs)
    memory
  end

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400, :second)
  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3_600, :second)
end
