defmodule StrangertalksNew.IntelligenceV1HostileTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Intelligence.{V1Metrics, V1Recommendations}

  alias StrangertalksNew.{
    AnalyticsRecord,
    Conversation,
    Conversations,
    LearningRecord,
    Matching,
    Matches,
    Participant,
    Participants,
    Relationship,
    Repo,
    Report
  }

  test "legacy writers have no live production callers and A02 is not runtime authority" do
    runtime_files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("config/**/*.exs")

    assert symbol_files(runtime_files, "create_analytics_record") == [
             "lib/strangertalks_new/analytics_records.ex"
           ]

    assert symbol_files(runtime_files, "create_learning_record") == [
             "lib/strangertalks_new/learning_records.ex"
           ]

    assert symbol_files(runtime_files, "LearningAdvisor") == [
             "lib/strangertalks_new/agent_systems/learning_advisor.ex"
           ]

    assert symbol_files(runtime_files, "advise_latest") == [
             "lib/strangertalks_new/agent_systems/learning_advisor.ex"
           ]

    router = File.read!("lib/strangertalks_new_web/router.ex")
    refute router =~ "/analytics"
    refute router =~ "/intelligence"
    refute router =~ "/learning"

    operator_task = File.read!("lib/mix/tasks/strangertalks.intelligence.ex")
    assert operator_task =~ "V1Metrics.snapshot"
    assert operator_task =~ "V1Recommendations.analyze"

    agent_task = File.read!("lib/mix/tasks/strangertalks.agents.ex")
    assert agent_task =~ ":learning_advisor_superseded_by_team8_v1"
    refute agent_task =~ "LearningAdvisor"
  end

  test "privacy boundary rejects nested atom and string forms across forbidden V1 data classes" do
    private_payloads = [
      %{participant_id: Ecto.UUID.generate()},
      %{"nested" => %{"conversation_id" => Ecto.UUID.generate()}},
      %{nested: [%{match_id: Ecto.UUID.generate()}]},
      %{"message_id" => Ecto.UUID.generate()},
      %{report_id: Ecto.UUID.generate()},
      %{"conversation_text" => "private Conversation text"},
      %{nested: %{report_evidence: "private safety evidence"}},
      %{"reflection_text" => "private reflection"},
      %{memory_text: "private memory"},
      %{"voice_note_bytes" => <<1, 2, 3>>},
      %{voice_note_transcript: "private transcript"},
      %{"call_audio_metadata" => %{"track" => "identifying"}},
      %{authorization: "Bearer private-token"},
      %{"refresh_token" => "private-refresh-token"},
      %{email: "private@example.com"},
      %{"name" => "Private Name"},
      %{photo: "private-photo"},
      %{"ip_address" => "203.0.113.7"},
      %{device_fingerprint: "device-secret"},
      %{"keystroke_latency_variance" => 0.2},
      %{readiness_score: 7.0},
      %{"personality_label" => "private-profile"},
      %{vulnerability_label: "private-profile"},
      %{"biometric_id" => "private-biometric"},
      %{voiceprint: "private-voiceprint"}
    ]

    Enum.each(private_payloads, fn payload ->
      refute V1Metrics.safe_output?(payload), "unexpectedly accepted #{inspect(payload)}"
    end)

    canonical = canonical_snapshot()

    refute V1Metrics.safe_output?(
             put_in(canonical, [:window, :device_fingerprint], "private-device")
           )

    assert {:error, :unsafe_analytics_input} =
             V1Recommendations.analyze(
               put_in(canonical, [:window, :device_fingerprint], "private-device")
             )

    assert {:error, :invalid_analytics_input} =
             V1Recommendations.analyze(put_in(canonical, [:window, :unexpected], "extra"))

    assert {:error, :invalid_analytics_input} =
             V1Recommendations.analyze(%{
               "schema_version" => V1Metrics.schema_version(),
               "window" => %{"from" => "2026-08-24T00:00:00Z", "to" => "2026-08-25T00:00:00Z"},
               "system" => %{},
               "human_outcomes" => %{}
             })
  end

  test "recommendation analysis is deterministic and leaves product state and configuration untouched" do
    snapshot = canonical_snapshot()
    before_counts = product_counts()
    before_env = Application.get_all_env(:strangertalks_new)

    assert {:ok, first} = V1Recommendations.analyze(snapshot)

    results =
      1..40
      |> Task.async_stream(
        fn _ -> V1Recommendations.analyze(snapshot) end,
        ordered: false,
        max_concurrency: 20,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == {:ok, first}))
    assert first.mutation_authority == false
    assert first.requires_review == true
    assert product_counts() == before_counts
    assert Application.get_all_env(:strangertalks_new) == before_env
  end

  test "reporting window is left-inclusive and right-exclusive" do
    from = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    to = DateTime.add(from, 60, :second)

    canonical_outcome(from)
    canonical_outcome(to)

    assert {:ok, snapshot} = V1Metrics.snapshot(from, to)
    assert snapshot.system.matches_created == 1
    assert snapshot.system.conversations_started == 1
    assert snapshot.system.natural_ends == 1
    assert snapshot.system.average_queue_time_seconds == 12.0
  end

  test "same/cross Door and terminal categories preserve narrow metric semantics" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    canonical_outcome(now, queue_seconds: 10)

    canonical_outcome(now,
      participant_a_door: :EXPLORE,
      participant_b_door: :SOMETHING_REAL,
      ending_type: :DISCONNECT,
      queue_seconds: 20
    )

    canonical_outcome(now,
      participant_a_door: :KEEP_IT_LIGHT,
      participant_b_door: :KEEP_IT_LIGHT,
      ending_type: :BLOCK,
      queue_seconds: 30
    )

    canonical_outcome(now,
      participant_a_door: :JUST_TALK,
      participant_b_door: :JUST_TALK,
      conversation_status: :FAILED,
      ending_type: :TIMEOUT,
      queue_seconds: 40
    )

    from = DateTime.add(now, -1, :second)
    to = DateTime.add(now, 1, :second)

    assert {:ok, snapshot} = V1Metrics.snapshot(from, to)
    assert snapshot.system.matches_created == 4
    assert snapshot.system.same_door_matches == 3
    assert snapshot.system.cross_door_matches == 1
    assert snapshot.system.average_queue_time_seconds == 25.0
    assert snapshot.system.natural_ends == 1
    assert snapshot.system.technical_disconnects == 1
    assert snapshot.system.failed_conversations == 1
    assert snapshot.human_outcomes.block_terminated_conversations == 1

    dictionary = Map.new(V1Metrics.metric_dictionary(), &{&1.name, &1})

    assert dictionary.average_queue_time_seconds.interpretation =~ "successfully matched"
    assert dictionary.average_queue_time_seconds.non_goal =~ "never produced a Match"
    assert dictionary.natural_ends.non_goal =~ "not automatically a positive"
    assert dictionary.same_door_matches.non_goal =~ "not be used to infer personal compatibility"
    assert dictionary.reports_submitted.non_goal =~ "not expose report evidence"
    assert dictionary.voluntary_relationships_created.non_goal =~ "relationship-strength score"
  end

  defp canonical_snapshot do
    %{
      schema_version: V1Metrics.schema_version(),
      window: %{from: "2026-08-24T00:00:00Z", to: "2026-08-25T00:00:00Z"},
      system: %{
        matches_created: 20,
        same_door_matches: 18,
        cross_door_matches: 2,
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
  end

  defp product_counts do
    %{
      participants: Repo.aggregate(Participant, :count, :participant_id),
      matches: Repo.aggregate(Matching, :count, :match_id),
      conversations: Repo.aggregate(Conversation, :count, :conversation_id),
      relationships: Repo.aggregate(Relationship, :count, :relationship_id),
      reports: Repo.aggregate(Report, :count, :report_id),
      analytics: Repo.aggregate(AnalyticsRecord, :count, :analytics_record_id),
      learning: Repo.aggregate(LearningRecord, :count, :learning_record_id)
    }
  end

  defp symbol_files(files, symbol) do
    files
    |> Enum.filter(fn path -> File.read!(path) =~ symbol end)
    |> Enum.sort()
  end

  defp canonical_outcome(now, opts \\ []) do
    participant_a_door = Keyword.get(opts, :participant_a_door, :EXPLORE)
    participant_b_door = Keyword.get(opts, :participant_b_door, participant_a_door)
    conversation_status = Keyword.get(opts, :conversation_status, :ENDED)
    ending_type = Keyword.get(opts, :ending_type, :NATURAL_END)
    queue_seconds = Keyword.get(opts, :queue_seconds, 12)

    {:ok, participant_1} = Participants.create_participant(%{})
    {:ok, participant_2} = Participants.create_participant(%{})
    [a, b] = Enum.sort_by([participant_1, participant_2], & &1.participant_id)

    queue_entry = DateTime.add(now, -queue_seconds, :second)
    shared_door = if participant_a_door == participant_b_door, do: participant_a_door, else: nil

    {:ok, match} =
      Matches.create_match(%{
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        participant_a_door_type: participant_a_door,
        participant_b_door_type: participant_b_door,
        door_type: shared_door,
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
        queue_duration_seconds: queue_seconds,
        conversation_duration_seconds: 30,
        conversation_started: true,
        conversation_completed: conversation_status != :FAILED,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        report_generated: false,
        block_generated: ending_type == :BLOCK,
        safety_review_required: false,
        learning_processed: false
      })

    {:ok, conversation} =
      Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: conversation_status,
        created_at: now,
        ended_at: now,
        door_type: shared_door,
        ending_type: ending_type,
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
        conversation_completed: conversation_status != :FAILED,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        conversation_success_score: "0.0000",
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: if(ending_type == :BLOCK, do: 1, else: 0),
        safety_flagged: ending_type == :BLOCK,
        safety_score: "0.0000",
        learning_processed: false,
        duration_seconds: 30,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    %{a: a, b: b, match: match, conversation: conversation}
  end
end
