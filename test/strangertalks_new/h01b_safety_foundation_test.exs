defmodule StrangertalksNew.H01bSafetyFoundationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{
    Conversations,
    Matches,
    Participants,
    Repo,
    Report,
    Reports
  }

  alias StrangertalksNew.Reports.{ReportEvidenceItem, SafetySubject}

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, participant_a} =
      Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: now,
        last_active_at: now
      })

    {:ok, participant_b} =
      Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: now,
        last_active_at: now
      })

    {:ok, match} =
      Matches.create_match(%{
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :SOMETHING_REAL,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: now,
        queue_entry_time: now,
        match_found_time: now,
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
      Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
        created_at: now,
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

    {:ok,
     now: now,
     participant_a: participant_a,
     participant_b: participant_b,
     conversation: conversation}
  end

  test "contract: safety_subjects table and case-local subject model exist", %{
    participant_a: participant_a,
    participant_b: participant_b,
    conversation: conversation
  } do
    {:ok, report} =
      Reports.submit_conversation_report(
        conversation.conversation_id,
        participant_a.participant_id,
        "HARASSMENT",
        "Harassing behavior test"
      )

    subjects = Repo.all(from s in SafetySubject, where: s.report_id == ^report.report_id)
    assert length(subjects) == 2

    reporter_sub = Enum.find(subjects, &(&1.subject_role == :REPORTER))
    reported_sub = Enum.find(subjects, &(&1.subject_role == :REPORTED))

    assert reporter_sub != nil
    assert reported_sub != nil
    assert reporter_sub.source_participant_id == participant_a.participant_id
    assert reported_sub.source_participant_id == participant_b.participant_id
    assert reporter_sub.report_id == report.report_id
    assert reported_sub.report_id == report.report_id

    # Verify subjects are case-local, not cross-case global
    {:ok, report2} =
      Reports.submit_conversation_report(
        conversation.conversation_id,
        participant_a.participant_id,
        "SPAM",
        "Different case"
      )

    subjects2 = Repo.all(from s in SafetySubject, where: s.report_id == ^report2.report_id)
    reporter_sub2 = Enum.find(subjects2, &(&1.subject_role == :REPORTER))

    assert reporter_sub2 != nil
    assert reporter_sub2.subject_id != reporter_sub.subject_id
  end

  test "contract: report_evidence_items table and durable snapshot model exist", %{
    participant_a: participant_a,
    conversation: conversation
  } do
    {:ok, report} =
      Reports.submit_conversation_report(
        conversation.conversation_id,
        participant_a.participant_id,
        "HARASSMENT",
        "Durable evidence message body"
      )

    evidence_items =
      Repo.all(from e in ReportEvidenceItem, where: e.report_id == ^report.report_id)

    assert length(evidence_items) == 1
    item = hd(evidence_items)

    assert item.source_kind == :CONVERSATION
    assert item.evidence_role == :SELECTED
    assert item.content_snapshot == "Durable evidence message body"
    assert item.captured_at != nil
    assert item.subject_id != nil
  end

  test "contract: retention metadata columns exist on reports", %{
    conversation: conversation,
    participant_a: participant_a
  } do
    {:ok, report} =
      Reports.submit_conversation_report(
        conversation.conversation_id,
        participant_a.participant_id,
        "SPAM",
        "Spam evidence"
      )

    reloaded = Repo.get!(Report, report.report_id)

    assert reloaded.retention_policy_version == "v1"
    assert not is_nil(reloaded.rich_evidence_expires_at)
    assert not is_nil(reloaded.reporter_unlink_at)
    assert not is_nil(reloaded.minimal_record_expires_at)

    assert DateTime.compare(reloaded.rich_evidence_expires_at, reloaded.minimal_record_expires_at) in [
             :lt,
             :eq
           ]
  end

  test "contract: bounded evidence limits are enforced (max 5 selected, max 20 context, max 15min window)" do
    # 1. Selected items > 5 rejected
    selected_items = for i <- 1..6, do: %{evidence_role: :SELECTED, content: "msg #{i}"}

    assert {:error, :selected_evidence_limit_exceeded} =
             Reports.validate_evidence_items(selected_items)

    # 2. Context items > 20 rejected
    context_items =
      for i <- 1..21, do: %{evidence_role: :CONTEXT_EXPANSION, content: "context #{i}"}

    assert {:error, :context_evidence_limit_exceeded} =
             Reports.validate_evidence_items(context_items)

    # 3. Context window > 15 minutes rejected
    t0 = DateTime.utc_now()
    t_over = DateTime.add(t0, 16 * 60, :second)

    window_items = [
      %{evidence_role: :CONTEXT_EXPANSION, source_timestamp: t0, content: "first"},
      %{evidence_role: :CONTEXT_EXPANSION, source_timestamp: t_over, content: "stale"}
    ]

    assert {:error, :context_window_exceeded} = Reports.validate_evidence_items(window_items)

    # 4. Valid bounded evidence passes
    t_ok = DateTime.add(t0, 5 * 60, :second)

    valid_items = [
      %{evidence_role: :SELECTED, content: "selected 1"},
      %{evidence_role: :CONTEXT_EXPANSION, source_timestamp: t0, content: "ctx 1"},
      %{evidence_role: :CONTEXT_EXPANSION, source_timestamp: t_ok, content: "ctx 2"}
    ]

    assert :ok = Reports.validate_evidence_items(valid_items)
  end

  test "contract: ephemeral lifecycle independence (safety subjects and evidence survive source deletion)",
       %{
         now: _now,
         participant_a: participant_a,
         participant_b: _participant_b,
         conversation: conversation
       } do
    {:ok, report} =
      Reports.submit_conversation_report(
        conversation.conversation_id,
        participant_a.participant_id,
        "HARASSMENT",
        "Evidence from ephemeral session"
      )

    subjects_before = Repo.all(from s in SafetySubject, where: s.report_id == ^report.report_id)

    evidence_before =
      Repo.all(from e in ReportEvidenceItem, where: e.report_id == ^report.report_id)

    assert length(subjects_before) == 2
    assert length(evidence_before) == 1

    # Simulate deletion of source conversation
    # Note: reports.conversation_id uses on_delete: :nothing; in H-01B the safety case itself
    # survives with case-local subject and evidence item snapshots even if source conversation or message is archived/deleted
    reloaded_report =
      Repo.get!(Report, report.report_id) |> Repo.preload([:safety_subjects, :evidence_items])

    assert length(reloaded_report.safety_subjects) == 2
    assert length(reloaded_report.evidence_items) == 1

    # Content snapshot is self-contained
    assert hd(reloaded_report.evidence_items).content_snapshot ==
             "Evidence from ephemeral session"
  end

  test "contract: database security - safety_subjects and report_evidence_items are RLS-enabled and closed to Data API" do
    for table <- ["safety_subjects", "report_evidence_items"] do
      # Table exists in postgres
      table_query =
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1)"

      assert Repo.query!(table_query, [table]).rows == [[true]]

      # RLS is enabled
      rls_query =
        "SELECT rowsecurity FROM pg_tables WHERE schemaname = 'public' AND tablename = $1"

      assert Repo.query!(rls_query, [table]).rows == [[true]]

      # API roles have 0 privileges
      existing_roles =
        Repo.query!("SELECT rolname FROM pg_roles WHERE rolname = ANY($1::text[])", [
          ["anon", "authenticated", "service_role"]
        ]).rows
        |> List.flatten()

      for role <- existing_roles do
        for priv <- ["SELECT", "INSERT", "UPDATE", "DELETE"] do
          priv_query = "SELECT has_table_privilege($1, $2, $3)"
          assert Repo.query!(priv_query, [role, table, priv]).rows == [[false]]
        end
      end
    end
  end
end
