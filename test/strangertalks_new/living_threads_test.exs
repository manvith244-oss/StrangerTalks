defmodule StrangertalksNew.LivingThreadsTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.LivingThreads
  alias StrangertalksNew.LivingThreads.{ExperimentAssignment, LivingThread, PilotEvent}
  alias StrangertalksNew.{MatchingRules, Participants, Repo, Reports}

  @now ~U[2026-09-11 00:00:00.000000Z]

  test "assignment is stable for a participant" do
    participant = participant!()

    assert {:ok, first} = LivingThreads.ensure_assignment(participant.participant_id, now: @now)
    assert first.role in [:CONSEQUENCE_A, :SPECTATOR_A, :CARRIER_B]

    assert {:ok, second} =
             LivingThreads.ensure_assignment(
               participant.participant_id,
               now: DateTime.add(@now, 60, :second)
             )

    assert second.assignment_id == first.assignment_id
    assert second.role == first.role
  end

  test "consequence A opens one thread with frozen 8h continuation and 24h resolution deadlines" do
    participant = participant!()
    assign!(participant, :CONSEQUENCE_A)

    assert {:ok, thread} =
             LivingThreads.start_thread(participant.participant_id, "A small beginning",
               now: @now
             )

    assert thread.status == :WAITING_FOR_B
    assert thread.opened_at == @now
    assert thread.continuation_deadline_at == DateTime.add(@now, 8 * 60 * 60, :second)
    assert thread.resolves_at == DateTime.add(@now, 24 * 60 * 60, :second)

    assert {:error, :thread_already_exists} =
             LivingThreads.start_thread(participant.participant_id, "A second beginning",
               now: @now
             )
  end

  test "a waiting thread becomes liquidity failure after 8h and cannot be rescued" do
    a = participant!()
    b = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(b, :CARRIER_B)

    assert {:ok, thread} = LivingThreads.start_thread(a.participant_id, "seed", now: @now)
    too_late = DateTime.add(@now, 8 * 60 * 60 + 1, :second)

    assert {:error, :no_waiting_thread} =
             LivingThreads.continue_next(b.participant_id, "late continuation", now: too_late)

    persisted = Repo.get!(LivingThread, thread.thread_id)
    assert persisted.status == :LIQUIDITY_FAILURE
    assert is_nil(persisted.carrier_participant_id)
    assert is_nil(persisted.continuation_body)
  end

  test "carrier continuation is single-use, logs remaining time, and stays hidden until resolution" do
    a = participant!()
    b = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(b, :CARRIER_B)

    assert {:ok, thread} = LivingThreads.start_thread(a.participant_id, "seed", now: @now)
    continued_at = DateTime.add(@now, 7 * 60 * 60, :second)

    assert {:ok, continued} =
             LivingThreads.continue_next(b.participant_id, "what B carried forward",
               now: continued_at
             )

    assert continued.thread_id == thread.thread_id
    assert continued.status == :CONTINUED
    assert continued.carrier_participant_id == b.participant_id
    assert continued.time_remaining_at_continuation_seconds == 17 * 60 * 60

    assert {:error, :carrier_already_used} =
             LivingThreads.continue_next(b.participant_id, "another one", now: continued_at)

    assert {:ok, before_resolution} =
             LivingThreads.experience_for(a.participant_id,
               now: DateTime.add(@now, 23 * 60 * 60, :second)
             )

    assert before_resolution.thread_id == thread.thread_id
    assert before_resolution.status == :CONTINUED
    assert before_resolution.your_contribution == "seed"
    refute Map.has_key?(before_resolution, :continuation)

    assert {:ok, after_resolution} =
             LivingThreads.experience_for(a.participant_id,
               now: DateTime.add(@now, 24 * 60 * 60, :second)
             )

    assert after_resolution.status == :RESOLVED
    assert after_resolution.your_contribution == "seed"
    assert after_resolution.continuation == "what B carried forward"

    event =
      Repo.get_by!(PilotEvent,
        participant_id: b.participant_id,
        thread_id: thread.thread_id,
        event_type: :THREAD_CONTRIBUTED
      )

    assert event.metadata["time_remaining_at_continuation_seconds"] == 17 * 60 * 60
  end

  test "spectator can be attached to a real thread but cannot mutate it" do
    a = participant!()
    spectator = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(spectator, :SPECTATOR_A)

    assert {:ok, thread} = LivingThreads.start_thread(a.participant_id, "seed", now: @now)

    assert {:ok, experience} = LivingThreads.experience_for(spectator.participant_id, now: @now)
    assert experience.role == :SPECTATOR_A
    assert experience.thread_id == thread.thread_id
    assert experience.seed == "seed"
    refute Map.has_key?(experience, :your_contribution)

    assert {:error, :wrong_role} =
             LivingThreads.start_thread(spectator.participant_id, "cannot mutate", now: @now)

    assert {:error, :wrong_role} =
             LivingThreads.continue_next(spectator.participant_id, "cannot carry", now: @now)

    assignment = Repo.get_by!(ExperimentAssignment, participant_id: spectator.participant_id)
    assert assignment.observed_thread_id == thread.thread_id
  end

  test "canonical safety veto prevents a blocked carrier from being assigned the thread" do
    a = participant!()
    blocked_b = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(blocked_b, :CARRIER_B)

    assert {:ok, _thread} = LivingThreads.start_thread(a.participant_id, "seed", now: @now)

    assert {:ok, _block} =
             MatchingRules.enforce_block(
               a.participant_id,
               blocked_b.participant_id,
               "LIVING_THREAD_PILOT"
             )

    assert {:error, :no_waiting_thread} =
             LivingThreads.continue_next(blocked_b.participant_id, "must not be routed",
               now: @now
             )
  end

  test "active conversation report prevents a reported carrier from being assigned the thread" do
    a = participant!()
    reported_b = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(reported_b, :CARRIER_B)

    conversation = conversation_between!(a, reported_b)

    assert {:ok, _report} =
             Reports.create_report(%{
               created_at: @now,
               updated_at: @now,
               reporting_participant_id: a.participant_id,
               reported_participant_id: reported_b.participant_id,
               conversation_id: conversation.conversation_id,
               report_category: :HARASSMENT,
               report_status: :SUBMITTED,
               reporter_context: "pilot separation test",
               deduplication_key: "living-thread-report-#{a.participant_id}",
               media_origin: :NO_MEDIA
             })

    assert {:ok, _thread} = LivingThreads.start_thread(a.participant_id, "seed", now: @now)

    assert {:error, :no_waiting_thread} =
             LivingThreads.continue_next(reported_b.participant_id, "must not be routed",
               now: @now
             )
  end

  test "known-person debrief is accepted only after a resolved exposure" do
    a = participant!()
    b = participant!()
    assign!(a, :CONSEQUENCE_A)
    assign!(b, :CARRIER_B)

    assert {:ok, thread} = LivingThreads.start_thread(a.participant_id, "seed", now: @now)
    assert {:ok, _continued} = LivingThreads.continue_next(b.participant_id, "reply", now: @now)

    assert {:error, :thread_not_resolved} =
             LivingThreads.record_known_person_debrief(a.participant_id, "no", nil, now: @now)

    resolved_at = DateTime.add(@now, 24 * 60 * 60, :second)

    assert {:ok, :recorded} =
             LivingThreads.record_known_person_debrief(
               a.participant_id,
               "maybe",
               "The writing style felt familiar",
               now: resolved_at
             )

    event =
      Repo.get_by!(PilotEvent,
        participant_id: a.participant_id,
        thread_id: thread.thread_id,
        event_type: :KNOWN_PERSON_DEBRIEF
      )

    assert event.metadata["answer"] == "maybe"
    assert event.metadata["reason"] == "The writing style felt familiar"
  end

  defp participant! do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp conversation_between!(a, b) do
    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: @now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_language: "en",
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
        match_id: match.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: :PENDING,
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

    conversation
  end

  defp assign!(participant, role) do
    %ExperimentAssignment{}
    |> ExperimentAssignment.changeset(
      %{role: role, assigned_at: @now},
      participant.participant_id
    )
    |> Repo.insert!()
  end
end
