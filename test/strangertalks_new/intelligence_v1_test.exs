defmodule StrangertalksNew.IntelligenceV1Test do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Intelligence.{V1Metrics, V1Recommendations}

  alias StrangertalksNew.{
    AnalyticsRecord,
    Conversations,
    LearningRecord,
    Matches,
    Participants,
    Relationship,
    Relationships,
    Repo,
    Report,
    Telemetry
  }

  test "zero-data snapshot is bounded, aggregate-only and creates no analytics history" do
    {from, to} = reporting_window()

    assert {:ok, snapshot} = V1Metrics.snapshot(from, to)
    assert snapshot.schema_version == "team8-v1-metrics-1"
    assert snapshot.system.matches_created == 0
    assert snapshot.system.conversations_started == 0
    assert snapshot.human_outcomes.voluntary_relationships_created == 0
    assert snapshot.human_outcomes.reports_submitted == 0
    assert V1Metrics.safe_output?(snapshot)

    assert Repo.aggregate(AnalyticsRecord, :count, :analytics_record_id) == 0
    assert Repo.aggregate(LearningRecord, :count, :learning_record_id) == 0
  end

  test "canonical durable outcomes produce one truthful aggregate snapshot" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{a: a, b: b, match: match, conversation: conversation} = canonical_natural_end(now)

    assert {:ok, %Relationship{}} =
             Relationships.create_relationship(%{
               created_at: now,
               updated_at: now,
               accepted_at: now,
               first_conversation_at: conversation.created_at,
               last_conversation_at: conversation.ended_at,
               last_activity_at: now,
               relationship_status: :ACTIVE,
               origin_door_type: :EXPLORE,
               participant_a_id: a.participant_id,
               participant_b_id: b.participant_id,
               origin_conversation_id: conversation.conversation_id,
               origin_match_id: match.match_id,
               participant_a_accepted: true,
               participant_b_accepted: true,
               allow_reconnection: true,
               reconnection_eligible: true,
               participant_a_closed: false,
               participant_b_closed: false,
               conversation_count: 1,
               memory_count: 0,
               reconnection_count: 0,
               shared_memory_count: 0,
               private_note_count: 0
             })

    {:ok, _report} = insert_report(a, b, conversation, now, "team8-dedup-1")

    from = DateTime.add(now, -120, :second)
    to = DateTime.add(now, 120, :second)

    assert {:ok, snapshot} = V1Metrics.snapshot(from, to)
    assert snapshot.system.matches_created == 1
    assert snapshot.system.same_door_matches == 1
    assert snapshot.system.cross_door_matches == 0
    assert snapshot.system.average_queue_time_seconds == 12.0
    assert snapshot.system.conversations_started == 1
    assert snapshot.system.natural_ends == 1
    assert snapshot.system.technical_disconnects == 0
    assert snapshot.system.failed_conversations == 0
    assert snapshot.human_outcomes.voluntary_relationships_created == 1
    assert snapshot.human_outcomes.reports_submitted == 1
    assert snapshot.human_outcomes.block_terminated_conversations == 0

    refute inspect(snapshot) =~ a.participant_id
    refute inspect(snapshot) =~ b.participant_id
    refute inspect(snapshot) =~ conversation.conversation_id
    refute inspect(snapshot) =~ match.match_id

    # Aggregation is observational and repeatable: reading the same canonical rows
    # neither duplicates metrics nor creates AnalyticsRecord/LearningRecord history.
    assert {:ok, ^snapshot} = V1Metrics.snapshot(from, to)
    assert Repo.aggregate(AnalyticsRecord, :count, :analytics_record_id) == 0
    assert Repo.aggregate(LearningRecord, :count, :learning_record_id) == 0
  end

  test "canonical report dedup prevents retry inflation" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{a: a, b: b, conversation: conversation} = canonical_natural_end(now)

    assert {:ok, _report} = insert_report(a, b, conversation, now, "team8-retry-key")
    assert {:error, changeset} = insert_report(a, b, conversation, now, "team8-retry-key")
    assert "has already been taken" in errors_on(changeset).deduplication_key

    from = DateTime.add(now, -120, :second)
    to = DateTime.add(now, 120, :second)

    assert {:ok, snapshot} = V1Metrics.snapshot(from, to)
    assert snapshot.human_outcomes.reports_submitted == 1
  end

  test "privacy guard rejects identity, content and readiness payloads" do
    refute V1Metrics.safe_output?(%{participant_id: Ecto.UUID.generate(), count: 1})
    refute V1Metrics.safe_output?(%{content: "private message", count: 1})
    refute V1Metrics.safe_output?(%{keystroke_latency_variance: 0.2, count: 1})
    refute V1Metrics.safe_output?(%{"reporter_context" => "private report evidence"})

    assert {:error, :unsafe_analytics_input} =
             V1Recommendations.analyze(%{
               system: %{},
               human_outcomes: %{},
               participant_id: Ecto.UUID.generate()
             })
  end

  test "existing telemetry strips private content, identifiers and credentials" do
    sanitized =
      Telemetry.sanitize_metadata(%{
        participant_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        match_id: Ecto.UUID.generate(),
        content: "private Conversation text",
        audio: <<1, 2, 3>>,
        authorization: "Bearer private-token",
        door_type: :EXPLORE,
        result: :success
      })

    assert sanitized == %{door_type: :EXPLORE, result: :success}
  end

  test "recommendations are deterministic evidence packets with zero mutation authority" do
    snapshot = %{
      schema_version: V1Metrics.schema_version(),
      window: %{from: "2026-08-24T00:00:00Z", to: "2026-08-25T00:00:00Z"},
      system: %{
        matches_created: 20,
        same_door_matches: 20,
        cross_door_matches: 0,
        average_queue_time_seconds: 8.0,
        conversations_started: 20,
        natural_ends: 15,
        technical_disconnects: 2,
        failed_conversations: 1
      },
      human_outcomes: %{
        voluntary_relationships_created: 3,
        reports_submitted: 1,
        block_terminated_conversations: 1
      }
    }

    assert {:ok, first} = V1Recommendations.analyze(snapshot)
    assert {:ok, second} = V1Recommendations.analyze(snapshot)
    assert first == second
    assert first.mutation_authority == false
    assert first.requires_review == true
    assert length(first.recommendations) == 2
    assert Enum.all?(first.recommendations, &(&1.mutation_authority == false))
    assert Enum.all?(first.recommendations, &(&1.requires_review == true))

    concurrent_results =
      1..20
      |> Task.async_stream(
        fn _ -> V1Recommendations.analyze(snapshot) end,
        ordered: false,
        max_concurrency: 10,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(concurrent_results, &(&1 == {:ok, first}))
  end

  test "reporting window rejects unbounded scans" do
    to = DateTime.utc_now()
    from = DateTime.add(to, -(32 * 24 * 60 * 60), :second)

    assert {:error, :analytics_window_too_large} = V1Metrics.snapshot(from, to)
    assert {:error, :invalid_analytics_window} = V1Metrics.snapshot(to, from)
  end

  test "V1 canonical Match and Conversation creation does not invent learning_version" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{match: match, conversation: conversation} = canonical_natural_end(now)

    assert match.learning_processed == false
    assert match.learning_version == nil
    assert conversation.learning_processed == false
    assert conversation.learning_version == nil
  end

  defp canonical_natural_end(now) do
    {:ok, participant_1} = Participants.create_participant(%{})
    {:ok, participant_2} = Participants.create_participant(%{})

    [a, b] = Enum.sort_by([participant_1, participant_2], & &1.participant_id)
    queue_entry = DateTime.add(now, -12, :second)

    {:ok, match} =
      Matches.create_match(%{
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        participant_a_door_type: :EXPLORE,
        participant_b_door_type: :EXPLORE,
        door_type: :EXPLORE,
        conversation_language: "en",
        match_status: :ENDED,
        match_strategy: :COMPATIBILITY,
        compatibility_score: "1.0000",
        opportunity_score: "0.0000",
        scarcity_adjustment: "0.0000",
        conversation_temperature: "0.0000",
        mutual_participation_score: "0.0000",
        conversation_health_score: "0.0000",
        match_quality_score: "0.0000",
        created_at: now,
        queue_entry_time: queue_entry,
        match_found_time: now,
        conversation_start_time: now,
        match_end_time: now,
        queue_duration_seconds: 12,
        conversation_duration_seconds: 30,
        conversation_started: true,
        conversation_completed: true,
        memory_created: false,
        relationship_created: true,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: :ENDED,
        created_at: now,
        ended_at: now,
        door_type: :EXPLORE,
        ending_type: :NATURAL_END,
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        participation_balance_score: "0.0000",
        message_exchange_rate: 0.0,
        conversation_depth_score: "0.0000",
        conversation_temperature: "0.0000",
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        bridge_effectiveness_score: "0.0000",
        conversation_completed: true,
        memory_created: false,
        relationship_created: true,
        reconnected_later: false,
        conversation_success_score: "0.0000",
        memory_count: 0,
        relationship_created_at_end: true,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        safety_score: "0.0000",
        learning_processed: false,
        duration_seconds: 30,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    %{a: a, b: b, match: match, conversation: conversation}
  end

  defp insert_report(a, b, conversation, now, deduplication_key) do
    %Report{}
    |> Report.changeset(%{
      created_at: now,
      updated_at: now,
      reporting_participant_id: a.participant_id,
      reported_participant_id: b.participant_id,
      conversation_id: conversation.conversation_id,
      report_category: :SPAM,
      report_status: :SUBMITTED,
      reporter_context: "private evidence that Team 8 must never ingest",
      deduplication_key: deduplication_key
    })
    |> Repo.insert()
  end

  defp reporting_window do
    to = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {DateTime.add(to, -60, :second), DateTime.add(to, 60, :second)}
  end
end
