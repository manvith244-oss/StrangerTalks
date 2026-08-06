defmodule StrangertalksNew.Matchmaking.MatchmakingEngineTest do
  use StrangertalksNew.DataCase, async: false

  import ExUnit.CaptureLog

  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.Matcher
  alias StrangertalksNew.QueueEngine.QueueState

  setup do
    # Wipe the volatile Agent memory clean before spinning up individual test blocks
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
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
          &MatchmakingEngine.join_queue(participant_id, &1, nil, nil, nil),
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
    test "same-Door V1 matching ignores reserved language, media, and cadence inputs" do
      {:ok, participant_1} = StrangertalksNew.Participants.create_participant(%{})
      {:ok, participant_2} = StrangertalksNew.Participants.create_participant(%{})
      p1 = participant_1.participant_id
      p2 = participant_2.participant_id

      MatchmakingEngine.join_queue(p1, :EXPLORE, "en", 1, 5.0)
      MatchmakingEngine.join_queue(p2, :EXPLORE, "es", 7, 900.0)

      assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
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
      assert log =~ missing_participant_id
      assert Repo.aggregate(StrangertalksNew.Matching, :count, :match_id) == 0
      assert Repo.aggregate(StrangertalksNew.Conversation, :count, :conversation_id) == 0

      state = Agent.get(QueueState, & &1)
      assert Map.has_key?(state, participant.participant_id)
      refute Map.has_key?(state, missing_participant_id)
    end
  end
end
