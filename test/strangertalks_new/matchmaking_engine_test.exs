defmodule StrangertalksNew.Matchmaking.MatchmakingEngineTest do
  use StrangertalksNew.DataCase, async: false

  import ExUnit.CaptureLog

  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.QueueEngine.Matcher
  alias StrangertalksNew.QueueEngine.QueueState

  setup do
    # Wipe the volatile Agent memory clean before spinning up individual test blocks
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  describe "BoundaryBlock and anonymous admission ordering" do
    test "committed BoundaryBlock wins before anonymous durable admission" do
      {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
      parent = self()

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

      evaluator =
        ParticipantActivityLock.with_participants([a.participant_id, b.participant_id], fn ->
          task =
            Task.async(fn ->
              send(parent, :admission_attempting)
              MatchmakingEngine.evaluate_pending_matches()
            end)

          assert_receive :admission_attempting

          assert {:ok, _block} =
                   StrangertalksNew.MatchingRules.enforce_block(
                     a.participant_id,
                     b.participant_id,
                     "FOUNDATION_TEST"
                   )

          task
        end)

      assert {:ok, []} = Task.await(evaluator)
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0
    end

    test "anonymous durable admission wins before a later BoundaryBlock" do
      {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

      assert {:ok, _block} =
               StrangertalksNew.MatchingRules.enforce_block(
                 a.participant_id,
                 b.participant_id,
                 "FOUNDATION_TEST"
               )

      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1
    end

    test "admission holding both participant locks commits before an attempted BoundaryBlock" do
      {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
      parent = self()

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

      block_task =
        ParticipantActivityLock.with_participants([a.participant_id, b.participant_id], fn ->
          task =
            Task.async(fn ->
              send(parent, :block_attempting)

              StrangertalksNew.MatchingRules.enforce_block(
                a.participant_id,
                b.participant_id,
                "CYCLE_5B_TEST"
              )
            end)

          assert_receive :block_attempting
          assert_waiting_for_participant_lock(task.pid)
          assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
          task
        end)

      assert {:ok, _block} = Task.await(block_task)
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1
    end
  end

  describe "terminal relationship closure admission" do
    test "a CLOSED canonical relationship cannot be recreated by anonymous matchmaking" do
      {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

      conversation = Repo.one!(StrangertalksNew.Conversation)

      conversation
      |> StrangertalksNew.Conversation.changeset(%{
        conversation_status: :ENDED,
        conversation_completed: true,
        ending_type: :NATURAL_END,
        ended_at: DateTime.utc_now()
      })
      |> Repo.update!()

      assert {:ok, _} =
               StrangertalksNew.Relationships.consent_to_relationship(
                 conversation.conversation_id,
                 a.participant_id
               )

      assert {:ok, %{relationship_id: relationship_id}} =
               StrangertalksNew.Relationships.consent_to_relationship(
                 conversation.conversation_id,
                 b.participant_id
               )

      assert {:ok, %{status: "closed"}} =
               StrangertalksNew.Relationships.close_relationship(
                 relationship_id,
                 a.participant_id,
                 :PARTICIPANT_CLOSED
               )

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1
    end

    test "admission holding both participant locks commits before an attempted closure" do
      {a, b, relationship} = relationship_fixture()
      parent = self()

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

      closure_task =
        ParticipantActivityLock.with_participants([a.participant_id, b.participant_id], fn ->
          task =
            Task.async(fn ->
              send(parent, :closure_attempting)

              StrangertalksNew.Relationships.close_relationship(
                relationship.relationship_id,
                a.participant_id,
                :PARTICIPANT_CLOSED
              )
            end)

          assert_receive :closure_attempting
          assert_waiting_for_participant_lock(task.pid)
          assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
          task
        end)

      assert {:ok, %{status: "closed"}} = Task.await(closure_task)
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 2
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 2
    end

    test "closure holding both participant locks commits before waiting admission revalidates" do
      {a, b, relationship} = relationship_fixture()
      parent = self()

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

      evaluator =
        ParticipantActivityLock.with_participants([a.participant_id, b.participant_id], fn ->
          task =
            Task.async(fn ->
              send(parent, :closure_race_admission_attempting)
              MatchmakingEngine.evaluate_pending_matches()
            end)

          assert_receive :closure_race_admission_attempting
          assert_waiting_for_participant_lock(task.pid)

          assert {:ok, %{status: "closed"}} =
                   StrangertalksNew.Relationships.close_relationship(
                     relationship.relationship_id,
                     a.participant_id,
                     :PARTICIPANT_CLOSED
                   )

          task
        end)

      assert {:ok, []} = Task.await(evaluator)
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1

      queue_state = Agent.get(QueueState, & &1)
      assert Map.has_key?(queue_state, a.participant_id)
      assert Map.has_key?(queue_state, b.participant_id)
    end
  end

  describe "safety authority failure" do
    test "an unavailable required safety relation fails closed and preserves both queue entries" do
      {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

      Repo.query!("ALTER TABLE relationships RENAME TO cycle5_unavailable_relationships")

      assert_raise Postgrex.Error, fn -> MatchmakingEngine.evaluate_pending_matches() end
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0

      queue_state = Agent.get(QueueState, & &1)
      assert Map.has_key?(queue_state, a.participant_id)
      assert Map.has_key?(queue_state, b.participant_id)
    end
  end

  describe "candidate FIFO opportunity" do
    test "the two oldest equally eligible same-Door participants receive first opportunity" do
      participants =
        for _ <- 1..4 do
          {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})

          assert {:ok, _} =
                   MatchmakingEngine.join_queue(
                     participant.participant_id,
                     :EXPLORE,
                     "en",
                     nil,
                     nil
                   )

          participant
        end

      enumeration = Agent.get(QueueState, &Map.values/1)
      base = DateTime.utc_now()

      enumeration
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.each(fn {entry, age_rank} ->
        Agent.update(QueueState, fn state ->
          put_in(
            state,
            [entry.participant_id, :queue_entry_time],
            DateTime.add(base, age_rank, :second)
          )
        end)
      end)

      expected_oldest_ids =
        enumeration
        |> Enum.reverse()
        |> Enum.take(2)
        |> Enum.map(& &1.participant_id)
        |> MapSet.new()

      assert {:ok, [_, _]} = MatchmakingEngine.evaluate_pending_matches()

      first_match =
        StrangertalksNew.Matching
        |> Ecto.Query.order_by(asc: :created_at)
        |> Ecto.Query.limit(1)
        |> Repo.one!()

      assert MapSet.new([first_match.participant_a_id, first_match.participant_b_id]) ==
               expected_oldest_ids

      assert length(participants) == 4
    end

    test "identical queue times use participant UUID as a stable tie-break" do
      for _execution <- 1..3 do
        participants = queued_participants(4, :EXPLORE)
        identical_time = DateTime.utc_now()

        Agent.update(QueueState, fn state ->
          Enum.reduce(participants, state, fn participant, acc ->
            put_in(acc, [participant.participant_id, :queue_entry_time], identical_time)
          end)
        end)

        expected_first_pair =
          participants
          |> Enum.map(& &1.participant_id)
          |> Enum.sort()
          |> Enum.take(2)
          |> MapSet.new()

        before_count = Repo.aggregate(StrangertalksNew.Matching, :count, :match_id)
        assert {:ok, [_, _]} = MatchmakingEngine.evaluate_pending_matches()

        first_match =
          StrangertalksNew.Matching
          |> Ecto.Query.order_by(asc: :created_at)
          |> Ecto.Query.offset(^before_count)
          |> Ecto.Query.limit(1)
          |> Repo.one!()

        assert MapSet.new([first_match.participant_a_id, first_match.participant_b_id]) ==
                 expected_first_pair
      end
    end

    test "third participant keeps its attempt and matches the next eligible arrival" do
      [a, b, c] = queued_participants(3, :EXPLORE)
      set_queue_age_order([a, b, c])
      survivor_before = Agent.get(QueueState, &Map.fetch!(&1, c.participant_id))

      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1

      survivor_after = Agent.get(QueueState, &Map.fetch!(&1, c.participant_id))
      assert survivor_after.queue_attempt_id == survivor_before.queue_attempt_id
      assert survivor_after.queue_entry_time == survivor_before.queue_entry_time

      [new_arrival] = queued_participants(1, :EXPLORE)
      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

      second_match =
        StrangertalksNew.Matching
        |> Ecto.Query.order_by(desc: :created_at)
        |> Ecto.Query.limit(1)
        |> Repo.one!()

      assert MapSet.new([second_match.participant_a_id, second_match.participant_b_id]) ==
               MapSet.new([c.participant_id, new_arrival.participant_id])

      assert Agent.get(QueueState, &map_size/1) == 0
    end

    test "oldest candidate skips a vetoed peer and matches the next safe peer" do
      [a, b, c] = queued_participants(3, :EXPLORE)
      set_queue_age_order([a, b, c])

      assert {:ok, _block} =
               StrangertalksNew.MatchingRules.enforce_block(
                 a.participant_id,
                 b.participant_id,
                 "CYCLE_6_TEST"
               )

      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
      [match] = Repo.all(StrangertalksNew.Matching)

      assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
               MapSet.new([a.participant_id, c.participant_id])

      assert Agent.get(QueueState, &Map.keys/1) == [b.participant_id]
    end

    test "stale oldest snapshot is skipped and later current candidates still match" do
      [a, b, c, d] = queued_participants(4, :EXPLORE)
      set_queue_age_order([a, b, c, d])

      evaluator =
        ParticipantActivityLock.with_participants([a.participant_id], fn ->
          task = Task.async(&MatchmakingEngine.evaluate_pending_matches/0)
          assert_waiting_for_participant_lock(task.pid)
          attempt = Agent.get(QueueState, &Map.fetch!(&1, a.participant_id)).queue_attempt_id
          assert :ok = MatchmakingEngine.cancel_queue(a.participant_id, attempt)
          task
        end)

      assert {:ok, [_match_id]} = Task.await(evaluator, :infinity)
      [match] = Repo.all(StrangertalksNew.Matching)

      assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
               MapSet.new([b.participant_id, c.participant_id])

      refute Agent.get(QueueState, &Map.has_key?(&1, a.participant_id))
      assert Agent.get(QueueState, &Map.has_key?(&1, d.participant_id))
    end

    test "several newer arrivals cannot bypass an older eligible waiter" do
      [older] = queued_participants(1, :EXPLORE)
      older_entry = Agent.get(QueueState, &Map.fetch!(&1, older.participant_id))

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()

      [vetoed_newer] = queued_participants(1, :EXPLORE)

      assert {:ok, _block} =
               StrangertalksNew.MatchingRules.enforce_block(
                 older.participant_id,
                 vetoed_newer.participant_id,
                 "CYCLE_6B_TEST"
               )

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()

      retained = Agent.get(QueueState, &Map.fetch!(&1, older.participant_id))
      assert retained.queue_entry_time == older_entry.queue_entry_time
      assert retained.queue_attempt_id == older_entry.queue_attempt_id

      [eligible_newer] = queued_participants(1, :EXPLORE)
      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

      [first_match] = Repo.all(StrangertalksNew.Matching)

      assert MapSet.new([first_match.participant_a_id, first_match.participant_b_id]) ==
               MapSet.new([older.participant_id, eligible_newer.participant_id])

      assert Agent.get(QueueState, &Map.keys/1) == [vetoed_newer.participant_id]
    end
  end

  describe "anonymous Ecto.Multi atomicity" do
    test "forced Match insert failure creates neither Match nor Conversation" do
      force_insert_failure!("matches")
      queue_eligible_pair()

      assert_raise Postgrex.Error, fn -> MatchmakingEngine.evaluate_pending_matches() end
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0
    end

    test "forced Conversation insert failure rolls back Match" do
      force_insert_failure!("conversations")
      queue_eligible_pair()

      assert_raise Postgrex.Error, fn -> MatchmakingEngine.evaluate_pending_matches() end
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0
    end
  end

  describe "Queue Entry Boundary Validations" do
    test "successfully injects structured parameters into the volatile Agent map" do
      p_id = Ecto.UUID.generate()

      assert {:ok, %{status: :queued}} =
               MatchmakingEngine.join_queue(p_id, :EXPLORE, "en", 7, 120.0)

      {:ok, status} = MatchmakingEngine.get_queue_status()
      assert status.active_participants == 1
    end

    test "rejects unformatted inputs matching the type constraints layout" do
      assert {:error, :unsupported_schema} =
               MatchmakingEngine.join_queue(12345, "EXPLORE", "en", 7, 120)
    end

    test "concurrent queue joins cannot overwrite one participant with a different Door" do
      participant_id = Ecto.UUID.generate()

      results =
        [:EXPLORE, :JUST_TALK]
        |> Task.async_stream(
          &MatchmakingEngine.join_queue(participant_id, &1, "en", nil, nil),
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %{status: :queued}}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, :already_queued_different_door}, &1)
             ) == 1

      assert Agent.get(QueueState, &Map.fetch!(&1, participant_id)).door_selection in [
               :EXPLORE,
               :JUST_TALK
             ]
    end

    test "concurrent same-Door joins preserve one canonical entry and admission time" do
      participant_id = Ecto.UUID.generate()

      results =
        race(2, fn ->
          MatchmakingEngine.join_queue(participant_id, :EXPLORE, "en", nil, nil)
        end)

      assert Enum.all?(results, &match?({:ok, %{status: :queued}}, &1))
      assert map_size(Agent.get(QueueState, & &1)) == 1
      entry = Agent.get(QueueState, &Map.fetch!(&1, participant_id))
      assert entry.attempt_count == 1
    end

    test "legacy scorer treats unknown cadence as neutral instead of crashing" do
      participant = %{
        language: "en",
        intent_vibe_vector: %{"primary_intent" => "EXPLORE", "vibe_dimensions" => %{}},
        media_mask: 1,
        typing_rate: nil
      }

      assert is_integer(Matcher.compute_match_score(participant, participant))
    end
  end

  describe "Dynamic Matrix Pipeline Verification" do
    test "same-Door candidates with different Conversation Languages do not match" do
      {:ok, participant_1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, participant_2} = StrangertalksNew.Participants.create_participant(%{})
      p1 = participant_1.participant_id
      p2 = participant_2.participant_id

      MatchmakingEngine.join_queue(p1, :EXPLORE, "en", 1, 5.0)
      MatchmakingEngine.join_queue(p2, :EXPLORE, "te", 7, 900.0)

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0
    end

    test "missing or invalid Conversation Language is rejected before QueueState" do
      {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})

      assert {:error, :language_required} =
               MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, nil, nil, nil)

      assert {:error, :invalid_conversation_language} =
               MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "xx", nil, nil)

      refute Agent.get(QueueState, &Map.has_key?(&1, participant.participant_id))
    end

    test "Conversation Language is immutable within an attempt and change requires a new attempt" do
      {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, first} =
               MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "te", nil, nil)

      assert {:ok, duplicate} =
               MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "TE", nil, nil)

      assert duplicate.queue_attempt_id == first.queue_attempt_id

      assert {:error, :already_queued_different_door} =
               MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)

      assert Agent.get(QueueState, &Map.fetch!(&1, participant.participant_id)).conversation_language ==
               "te"

      assert :ok = MatchmakingEngine.leave_queue(participant.participant_id)

      assert {:ok, second} =
               MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)

      refute second.queue_attempt_id == first.queue_attempt_id
    end

    test "scarcity and long wait never relax different Conversation Languages" do
      {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
      assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :JUST_TALK, "te", nil, nil)
      assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
      age_queue_entries([a, b], 600_000)

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0
    end

    test "language mismatch is skipped and search continues to same-language candidate" do
      [a, b, c] =
        for language <- ["te", "en", "te"] do
          {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})

          assert {:ok, _} =
                   MatchmakingEngine.join_queue(
                     participant.participant_id,
                     :EXPLORE,
                     language,
                     nil,
                     nil
                   )

          participant
        end

      set_queue_age_order([a, b, c])
      assert {:ok, [_]} = MatchmakingEngine.evaluate_pending_matches()
      match = Repo.one!(StrangertalksNew.Matching)

      assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
               MapSet.new([a.participant_id, c.participant_id])

      assert match.conversation_language == "te"
      assert Agent.get(QueueState, &Map.keys/1) == [b.participant_id]
    end

    test "matching doors persist a match and pending conversation before removing both participants" do
      {:ok, participant_1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, participant_2} = StrangertalksNew.Participants.create_participant(%{})
      p1 = participant_1.participant_id
      p2 = participant_2.participant_id

      MatchmakingEngine.join_queue(p1, :EXPLORE, "en", 7, 120.0)
      MatchmakingEngine.join_queue(p2, :EXPLORE, "en", 7, 120.0)

      # Artificially alter timestamps to force an active wait time past 40 seconds
      past_time = DateTime.add(DateTime.utc_now(), -45, :second)

      Agent.update(QueueState, fn state ->
        state
        |> put_in([p1, :queue_entry_time], past_time)
        |> put_in([p2, :queue_entry_time], past_time)
      end)

      assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

      match = Repo.get!(StrangertalksNew.Matching, match_id)
      conversation = Repo.get_by!(StrangertalksNew.Conversation, match_id: match_id)

      assert match.participant_a_id in [p1, p2]
      assert match.participant_b_id in [p1, p2]
      refute match.participant_a_id == match.participant_b_id
      assert match.door_type == :EXPLORE
      assert match.match_status == :CREATED
      assert match.match_strategy == :COMPATIBILITY
      assert Decimal.to_float(match.compatibility_score) == 1.0
      assert match.compatibility_version == "compatibility_v1"
      assert match.queue_duration_seconds >= 45
      assert match.conversation_duration_seconds == 0
      assert match.conversation_started == false
      assert match.conversation_completed == false
      assert match.memory_created == false
      assert match.relationship_created == false
      assert match.reconnected_later == false
      assert match.report_generated == false
      assert match.block_generated == false
      assert match.safety_review_required == false
      assert match.learning_processed == false
      assert is_nil(match.learning_version)
      assert is_nil(match.opportunity_score)
      assert is_nil(match.scarcity_adjustment)
      assert is_nil(match.conversation_temperature)
      assert is_nil(match.mutual_participation_score)
      assert is_nil(match.conversation_health_score)
      assert is_nil(match.match_quality_score)

      assert conversation.participant_a_id == match.participant_a_id
      assert conversation.participant_b_id == match.participant_b_id
      assert conversation.door_type == :EXPLORE
      assert conversation.conversation_status == :PENDING
      assert conversation.message_count == 0
      assert conversation.voice_note_count == 0
      assert conversation.memory_count == 0
      assert conversation.report_count == 0
      assert conversation.block_count == 0
      assert conversation.duration_seconds == 0
      assert conversation.bridge_shown == false
      assert conversation.bridge_used == false
      assert conversation.bridge_ignored == false
      assert conversation.conversation_completed == false
      assert conversation.memory_created == false
      assert conversation.relationship_created == false
      assert conversation.reconnected_later == false
      assert conversation.relationship_created_at_end == false
      assert conversation.safety_flagged == false
      assert conversation.learning_processed == false
      assert is_nil(conversation.learning_version)
      assert is_nil(conversation.conversation_temperature)

      {:ok, status} = MatchmakingEngine.get_queue_status()
      assert status.active_participants == 0
    end

    test "different doors do not match or remove either participant" do
      {:ok, participant_1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, participant_2} = StrangertalksNew.Participants.create_participant(%{})

      MatchmakingEngine.join_queue(
        participant_1.participant_id,
        :EXPLORE,
        "en",
        7,
        120.0
      )

      MatchmakingEngine.join_queue(
        participant_2.participant_id,
        :SOMETHING_REAL,
        "en",
        7,
        120.0
      )

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0

      {:ok, status} = MatchmakingEngine.get_queue_status()
      assert status.active_participants == 2
    end

    test "independent A-B and A-C admissions race with exactly one winner" do
      [a, b, c] =
        for _ <- 1..3 do
          {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
          participant
        end

      Enum.each([a, b, c], fn participant ->
        assert {:ok, %{status: :queued}} =
                 MatchmakingEngine.join_queue(
                   participant.participant_id,
                   :EXPLORE,
                   "en",
                   nil,
                   nil
                 )
      end)

      original_state = Agent.get(QueueState, & &1)

      tasks =
        ParticipantActivityLock.with_participants(
          [a.participant_id, b.participant_id, c.participant_id],
          fn ->
            Agent.update(QueueState, &Map.take(&1, [a.participant_id, b.participant_id]))
            ab_task = Task.async(&MatchmakingEngine.evaluate_pending_matches/0)
            assert_waiting_for_participant_lock(ab_task.pid)

            Agent.update(QueueState, fn _state ->
              Map.take(original_state, [a.participant_id, c.participant_id])
            end)

            ac_task = Task.async(&MatchmakingEngine.evaluate_pending_matches/0)
            assert_waiting_for_participant_lock(ac_task.pid)

            Agent.update(QueueState, fn _state -> original_state end)
            [ab_task, ac_task]
          end
        )

      results = Enum.map(tasks, &Task.await(&1, :infinity))
      assert Enum.all?(results, &match?({:ok, _}, &1))

      matches = Repo.all(StrangertalksNew.Matching)
      conversations = Repo.all(StrangertalksNew.Conversation)
      [winning_match] = matches
      winning_ids = [winning_match.participant_a_id, winning_match.participant_b_id]
      losing_peer = if b.participant_id in winning_ids, do: c, else: b

      assert length(matches) == 1
      assert length(conversations) == 1
      assert a.participant_id in winning_ids
      assert Repo.one!(StrangertalksNew.Conversation).match_id == winning_match.match_id
      assert Agent.get(QueueState, &Map.keys(&1)) == [losing_peer.participant_id]

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1
      assert Agent.get(QueueState, &Map.keys(&1)) == [losing_peer.participant_id]
    end

    test "candidate selected before Cancel has no admission authority after Cancel wins" do
      participants =
        for _ <- 1..2 do
          {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
          participant
        end

      [peer, cancelled] = Enum.sort_by(participants, & &1.participant_id)

      Enum.each([peer, cancelled], fn participant ->
        assert {:ok, %{status: :queued}} =
                 MatchmakingEngine.join_queue(
                   participant.participant_id,
                   :EXPLORE,
                   "en",
                   nil,
                   nil
                 )
      end)

      evaluator =
        ParticipantActivityLock.with_participants([peer.participant_id], fn ->
          task = Task.async(&MatchmakingEngine.evaluate_pending_matches/0)
          assert_waiting_for_participant_lock(task.pid)

          attempt_1 = Agent.get(QueueState, &Map.fetch!(&1, cancelled.participant_id))

          assert :ok =
                   MatchmakingEngine.cancel_queue(
                     cancelled.participant_id,
                     attempt_1.queue_attempt_id
                   )

          refute Map.has_key?(Agent.get(QueueState, & &1), cancelled.participant_id)

          assert {:ok, %{queue_attempt_id: attempt_2_id}} =
                   MatchmakingEngine.join_queue(
                     cancelled.participant_id,
                     :EXPLORE,
                     "en",
                     nil,
                     nil
                   )

          refute attempt_2_id == attempt_1.queue_attempt_id
          {task, attempt_2_id}
        end)

      {evaluator, attempt_2_id} = evaluator
      assert {:ok, []} = Task.await(evaluator, :infinity)
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0

      state = Agent.get(QueueState, & &1)
      assert Map.fetch!(state, cancelled.participant_id).queue_attempt_id == attempt_2_id
      assert Map.has_key?(state, peer.participant_id)
    end

    test "durable anonymous outcome outranks stale QueueState on retry" do
      participants =
        for _ <- 1..2 do
          {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
          participant
        end

      Enum.each(participants, fn participant ->
        assert {:ok, _} =
                 MatchmakingEngine.join_queue(
                   participant.participant_id,
                   :EXPLORE,
                   "en",
                   nil,
                   nil
                 )
      end)

      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
      baseline_matches = Repo.aggregate(StrangertalksNew.Matching, :count, :match_id)

      baseline_conversations =
        Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id)

      now = DateTime.utc_now()

      Agent.update(QueueState, fn state ->
        Enum.reduce(participants, state, fn participant, acc ->
          Map.put(acc, participant.participant_id, %{
            participant_id: participant.participant_id,
            door_selection: :EXPLORE,
            conversation_language: "en",
            queue_entry_time: now,
            queue_entry_monotonic: System.monotonic_time()
          })
        end)
      end)

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == baseline_matches

      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) ==
               baseline_conversations

      assert Agent.get(QueueState, & &1) == %{}
    end

    test "cancel cannot report success after match commit wins" do
      participants =
        for _ <- 1..2 do
          {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
          participant
        end

      Enum.each(participants, fn participant ->
        assert {:ok, _} =
                 MatchmakingEngine.join_queue(
                   participant.participant_id,
                   :EXPLORE,
                   "en",
                   nil,
                   nil
                 )
      end)

      committed_attempt_id =
        Agent.get(QueueState, fn state ->
          state |> Map.fetch!(hd(participants).participant_id) |> Map.fetch!(:queue_attempt_id)
        end)

      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

      assert {:error, :participant_busy} =
               MatchmakingEngine.cancel_queue(
                 hd(participants).participant_id,
                 committed_attempt_id
               )

      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 1
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 1
    end

    test "missing participant is logged and removed while the valid participant remains queued" do
      {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
      missing_participant_id = Ecto.UUID.generate()

      MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", 7, 120.0)
      MatchmakingEngine.join_queue(missing_participant_id, :EXPLORE, "en", 7, 120.0)

      log =
        capture_log(fn ->
          assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
        end)

      assert log =~ "matchmaking participant record missing"
      assert log =~ "missing_participant_count=1"
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0

      state = Agent.get(QueueState, & &1)
      assert Map.has_key?(state, participant.participant_id)
      refute Map.has_key?(state, missing_participant_id)
    end
  end

  describe "Cycle 7B Door scarcity and representation" do
    test "same Door matches immediately and persists both entry Doors" do
      [a, b] = queued_participants(2, :JUST_TALK)

      assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()
      match = Repo.get!(StrangertalksNew.Matching, match_id)
      conversation = Repo.get_by!(StrangertalksNew.Conversation, match_id: match_id)

      assert {match.participant_a_door_type, match.participant_b_door_type} ==
               {:JUST_TALK, :JUST_TALK}

      assert match.door_type == :JUST_TALK
      assert conversation.door_type == :JUST_TALK

      assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
               MapSet.new([a.participant_id, b.participant_id])
    end

    test "approved cross Door requires both server-owned waits and reconciles each own Door" do
      [a] = queued_participants(1, :JUST_TALK)
      [b] = queued_participants(1, :EXPLORE)

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      age_queue_entries([a, b], 15_000)
      assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

      match = Repo.get!(StrangertalksNew.Matching, match_id)
      conversation = Repo.get_by!(StrangertalksNew.Conversation, match_id: match_id)

      assert %{
               match.participant_a_id => match.participant_a_door_type,
               match.participant_b_id => match.participant_b_door_type
             } == %{
               a.participant_id => :JUST_TALK,
               b.participant_id => :EXPLORE
             }

      assert is_nil(match.door_type)
      assert is_nil(conversation.door_type)
      assert match.match_strategy == :SCARCITY

      assert {:ok, %{conversation: %{door_type: "JUST_TALK"}}} =
               StrangertalksNew.SessionReconciliation.reconcile(a.participant_id)

      assert {:ok, %{conversation: %{door_type: "EXPLORE"}}} =
               StrangertalksNew.SessionReconciliation.reconcile(b.participant_id)

      conversation
      |> StrangertalksNew.Conversation.changeset(%{
        conversation_status: :ENDED,
        conversation_completed: true,
        ending_type: :NATURAL_END,
        ended_at: DateTime.utc_now()
      })
      |> Repo.update!()

      assert {:ok, _} =
               StrangertalksNew.Relationships.consent_to_relationship(
                 conversation.conversation_id,
                 a.participant_id
               )

      assert {:ok, %{relationship_id: relationship_id}} =
               StrangertalksNew.Relationships.consent_to_relationship(
                 conversation.conversation_id,
                 b.participant_id
               )

      relationship = Repo.get!(StrangertalksNew.Relationship, relationship_id)

      assert is_nil(relationship.origin_door_type)

      assert %{
               relationship.participant_a_id => relationship.origin_participant_a_door_type,
               relationship.participant_b_id => relationship.origin_participant_b_door_type
             } == %{
               a.participant_id => :JUST_TALK,
               b.participant_id => :EXPLORE
             }
    end

    test "only one old participant cannot pull a fresh participant into cross Door" do
      [a] = queued_participants(1, :JUST_TALK)
      [b] = queued_participants(1, :EXPLORE)
      age_queue_entries([a], 20_000)

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()

      assert Agent.get(QueueState, &Map.keys/1) |> MapSet.new() ==
               MapSet.new([a.participant_id, b.participant_id])
    end

    test "exact Door opportunity beats an older approved cross Door candidate" do
      [a] = queued_participants(1, :JUST_TALK)
      [b] = queued_participants(1, :EXPLORE)
      [c] = queued_participants(1, :JUST_TALK)
      age_queue_entries([a], 25_000)
      age_queue_entries([b], 24_000)
      age_queue_entries([c], 5_000)

      assert {:ok, [_]} = MatchmakingEngine.evaluate_pending_matches()
      match = Repo.one!(StrangertalksNew.Matching)

      assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
               MapSet.new([a.participant_id, c.participant_id])

      assert Agent.get(QueueState, &Map.keys/1) == [b.participant_id]
    end

    test "approved graph is symmetric and permanently disallowed pairs remain queued" do
      approved = [
        {:JUST_TALK, :EXPLORE},
        {:JUST_TALK, :KEEP_IT_LIGHT},
        {:KEEP_IT_LIGHT, :EXPLORE},
        {:EXPLORE, :SOMETHING_REAL}
      ]

      for {door_a, door_b} <- approved, {left, right} <- [{door_a, door_b}, {door_b, door_a}] do
        [a] = queued_participants(1, left)
        [b] = queued_participants(1, right)
        age_queue_entries([a, b], 16_000)
        before = Repo.aggregate(StrangertalksNew.Matching, :count, :match_id)

        assert {:ok, [_]} = MatchmakingEngine.evaluate_pending_matches()
        assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == before + 1
      end

      for {door_a, door_b} <- [
            {:JUST_TALK, :SOMETHING_REAL},
            {:KEEP_IT_LIGHT, :SOMETHING_REAL}
          ] do
        [a] = queued_participants(1, door_a)
        [b] = queued_participants(1, door_b)
        age_queue_entries([a, b], 300_000)

        assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
        Agent.update(QueueState, fn _ -> %{} end)
      end
    end

    test "cross Door uses oldest safe partner and skips a vetoed older candidate" do
      [a] = queued_participants(1, :JUST_TALK)
      [b] = queued_participants(1, :EXPLORE)
      [c] = queued_participants(1, :KEEP_IT_LIGHT)
      age_queue_entries([a], 30_000)
      age_queue_entries([b], 25_000)
      age_queue_entries([c], 20_000)

      assert {:ok, _} =
               StrangertalksNew.MatchingRules.enforce_block(
                 a.participant_id,
                 b.participant_id,
                 "CYCLE_7B_TEST"
               )

      assert {:ok, [_]} = MatchmakingEngine.evaluate_pending_matches()
      match = Repo.one!(StrangertalksNew.Matching)

      assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
               MapSet.new([a.participant_id, c.participant_id])

      assert Agent.get(QueueState, &Map.keys/1) == [b.participant_id]
    end

    test "participant remains queued beyond 120 seconds with attempt and entry time unchanged" do
      [a] = queued_participants(1, :JUST_TALK)
      age_queue_entries([a], 121_000)
      before = Agent.get(QueueState, &Map.fetch!(&1, a.participant_id))

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
      after_evaluation = Agent.get(QueueState, &Map.fetch!(&1, a.participant_id))

      assert after_evaluation.queue_entry_time == before.queue_entry_time
      assert after_evaluation.queue_attempt_id == before.queue_attempt_id
    end
  end

  describe "Stale & Active Conversation Queue Boundaries" do
    alias StrangertalksNew.{Conversation, Matching}

    defp create_conv(p1_id, p2_id, status, created_at) do
      {:ok, match} =
        Repo.insert(%Matching{
          participant_a_id: p1_id,
          participant_b_id: p2_id,
          door_type: :EXPLORE,
          participant_a_door_type: :EXPLORE,
          participant_b_door_type: :EXPLORE,
          match_status: :ACTIVE,
          match_strategy: :COMPATIBILITY,
          created_at: created_at,
          queue_entry_time: created_at,
          match_found_time: created_at,
          compatibility_score: Decimal.new("0.85"),
          opportunity_score: Decimal.new("0.75"),
          scarcity_adjustment: Decimal.new("0.0"),
          conversation_temperature: Decimal.new("0.5"),
          mutual_participation_score: Decimal.new("0.8"),
          conversation_health_score: Decimal.new("0.85"),
          match_quality_score: Decimal.new("0.82"),
          queue_duration_seconds: 0,
          conversation_duration_seconds: 0,
          conversation_started: false,
          conversation_completed: false,
          memory_created: false,
          relationship_created: false,
          report_generated: false,
          block_generated: false,
          safety_review_required: false,
          learning_processed: false,
          reconnected_later: false
        })

      {:ok, conv} =
        %Conversation{}
        |> Conversation.changeset(%{
          match_id: match.match_id,
          participant_a_id: p1_id,
          participant_b_id: p2_id,
          door_type: :EXPLORE,
          conversation_status: status,
          bridge_shown: false,
          bridge_used: false,
          bridge_ignored: false,
          conversation_completed: false,
          memory_created: false,
          relationship_created: false,
          reconnected_later: false,
          relationship_created_at_end: false,
          safety_flagged: false,
          learning_processed: false,
          created_at: created_at,
          message_count: 0,
          voice_note_count: 0,
          memory_count: 0,
          report_count: 0,
          block_count: 0,
          duration_seconds: 0
        })
        |> Repo.insert()

      conv
    end

    test "fresh participant without conversation joins queue successfully" do
      {:ok, p} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, %{status: :queued}} =
               MatchmakingEngine.join_queue(p.participant_id, :EXPLORE, "en", nil, nil)
    end

    test "participant in an active conversation is rejected with :participant_busy and conversation is untouched" do
      {:ok, p1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, p2} = StrangertalksNew.Participants.create_participant(%{})

      conv = create_conv(p1.participant_id, p2.participant_id, :ACTIVE, DateTime.utc_now())

      assert {:error, :participant_busy} =
               MatchmakingEngine.join_queue(p1.participant_id, :EXPLORE, "en", nil, nil)

      assert Repo.get(Conversation, conv.conversation_id).conversation_status == :ACTIVE
    end

    test "recent PENDING conversation within recovery grace period rejects queue with :participant_busy" do
      {:ok, p1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, p2} = StrangertalksNew.Participants.create_participant(%{})

      conv = create_conv(p1.participant_id, p2.participant_id, :PENDING, DateTime.utc_now())

      assert {:error, :participant_busy} =
               MatchmakingEngine.join_queue(p1.participant_id, :EXPLORE, "en", nil, nil)

      assert Repo.get(Conversation, conv.conversation_id).conversation_status == :PENDING
    end

    test "orphaned PENDING conversation older than grace period without process is transitioned to :ABANDONED and queue succeeds" do
      {:ok, p1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, p2} = StrangertalksNew.Participants.create_participant(%{})

      old_time = DateTime.utc_now() |> DateTime.add(-300, :second)
      conv = create_conv(p1.participant_id, p2.participant_id, :PENDING, old_time)

      assert {:ok, %{status: :queued}} =
               MatchmakingEngine.join_queue(p1.participant_id, :EXPLORE, "en", nil, nil)

      updated_conv = Repo.get(Conversation, conv.conversation_id)
      assert updated_conv.conversation_status == :ABANDONED
      assert updated_conv.ending_type == :TIMEOUT
      assert updated_conv.ended_at != nil
    end
  end

  defp race(count, operation) do
    parent = self()

    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> operation.()
          end
        end)
      end

    Enum.each(tasks, fn task ->
      task_pid = task.pid
      assert_receive {:ready, ^task_pid}
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, :infinity))
  end

  defp relationship_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

    conversation = Repo.one!(StrangertalksNew.Conversation)

    assert {:ok, _pid} =
             StrangertalksNew.ConversationLifecycle.ConversationServer.ensure_started(
               conversation.conversation_id
             )

    assert :ok =
             StrangertalksNew.ConversationLifecycle.ConversationServer.register_channel(
               conversation.conversation_id,
               a.participant_id,
               self()
             )

    assert :ok =
             StrangertalksNew.ConversationLifecycle.ConversationServer.register_channel(
               conversation.conversation_id,
               b.participant_id,
               self()
             )

    assert {:ok, %{status: "ended"}} =
             StrangertalksNew.ConversationLifecycle.ConversationServer.complete_conversation(
               conversation.conversation_id,
               a.participant_id
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM participant_pairing_reservations WHERE match_id::text = $1 AND released_at IS NULL",
               [conversation.match_id]
             )

    assert {:ok, _} =
             StrangertalksNew.Relationships.consent_to_relationship(
               conversation.conversation_id,
               a.participant_id
             )

    assert {:ok, %{relationship_id: relationship_id}} =
             StrangertalksNew.Relationships.consent_to_relationship(
               conversation.conversation_id,
               b.participant_id
             )

    {a, b, Repo.get!(StrangertalksNew.Relationship, relationship_id)}
  end

  defp queued_participants(count, door) do
    for _ <- 1..count do
      {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, _} =
               MatchmakingEngine.join_queue(participant.participant_id, door, "en", nil, nil)

      participant
    end
  end

  defp set_queue_age_order(participants) do
    base = DateTime.utc_now() |> DateTime.add(-length(participants), :second)

    participants
    |> Enum.with_index()
    |> Enum.each(fn {participant, index} ->
      Agent.update(QueueState, fn state ->
        put_in(
          state,
          [participant.participant_id, :queue_entry_time],
          DateTime.add(base, index, :second)
        )
      end)
    end)
  end

  defp age_queue_entries(participants, age_ms) do
    queued_at = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    Agent.update(QueueState, fn state ->
      Enum.reduce(participants, state, fn participant, acc ->
        put_in(acc, [participant.participant_id, :queue_entry_time], queued_at)
      end)
    end)
  end

  defp assert_waiting_for_participant_lock(pid, attempts \\ 1_000_000)

  defp assert_waiting_for_participant_lock(_pid, 0) do
    flunk("evaluator did not reach participant admission lock")
  end

  defp assert_waiting_for_participant_lock(pid, attempts) do
    case Process.info(pid, :current_function) do
      {:current_function, {:global, _function, _arity}} ->
        :ok

      _other ->
        :erlang.yield()
        assert_waiting_for_participant_lock(pid, attempts - 1)
    end
  end

  defp queue_eligible_pair do
    for _ <- 1..2 do
      {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})

      assert {:ok, _} =
               MatchmakingEngine.join_queue(
                 participant.participant_id,
                 :EXPLORE,
                 "en",
                 nil,
                 nil
               )
    end
  end

  defp force_insert_failure!(table) when table in ["matches", "conversations"] do
    function = "foundation_fail_#{table}_insert"
    trigger = "foundation_fail_#{table}_insert_trigger"

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'forced foundation transaction failure';
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE INSERT ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function}()
    """)
  end
end
