# filepath: test/strangertalks_new/matching_rules_test.exs
defmodule StrangertalksNew.MatchingRulesTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.MatchingRules.ConversationRoom

  setup do
    # FIXED: Start the isolated Registry process required by dynamic room routing
    start_supervised!({Registry, keys: :unique, name: StrangertalksNew.ConversationRegistry})

    {:ok, p1} =
      MatchingRules.create_participant(%{
        presence_state: "MATCHING",
        current_door: "SOMETHING_REAL"
      })

    {:ok, p2} =
      MatchingRules.create_participant(%{
        presence_state: "MATCHING",
        current_door: "SOMETHING_REAL"
      })

    {:ok, participant_a: p1, participant_b: p2}
  end

  describe "Relational Constraints & Check Enforcement" do
    test "successfully logs persistent telemetry metrics using appropriate strategy maps", %{
      participant_a: p1
    } do
      assert {:ok, _} =
               MatchingRules.log_match_telemetry(
                 p1.participant_id,
                 "COMPATIBILITY",
                 42,
                 %{"primary_intent" => "SOMETHING_REAL"}
               )
    end

    test "fails insertion if the input strategy violates explicit check bounds", %{
      participant_a: p1
    } do
      changeset =
        MatchingRules.QueueState.changeset(
          %MatchingRules.QueueState{},
          %{
            participant_id: p1.participant_id,
            matched_strategy_applied: "INVALID_STRATEGY",
            intent_vibe_vector: %{}
          }
        )

      assert {:error, _changeset} = Repo.insert(changeset)
    end
  end

  describe "Safety Agent Master Veto System" do
    test "correctly handles and surfaces safety overrides for blocked participant combinations",
         %{participant_a: p1, participant_b: p2} do
      refute MatchingRules.check_safety_veto?(p1.participant_id, p2.participant_id)

      {:ok, _} =
        MatchingRules.enforce_block(
          p1.participant_id,
          p2.participant_id,
          "CONVERSATION_INTERFACE"
        )

      assert MatchingRules.check_safety_veto?(p1.participant_id, p2.participant_id)
      assert MatchingRules.check_safety_veto?(p2.participant_id, p1.participant_id)
    end
  end

  describe "Heap Process Overflow & Circuit Breaker Limits" do
    test "mutes message transmission loops if buffer allocations threaten memory limits", %{
      participant_a: p1,
      participant_b: p2
    } do
      conversation_id = Ecto.UUID.generate()

      start_supervised!(
        {ConversationRoom,
         [
           conversation_id: conversation_id,
           participant_a: p1.participant_id,
           participant_b: p2.participant_id
         ]}
      )

      # Flood buffer memory arrays up to the 50 message ceiling limit
      for _ <- 1..50 do
        assert :ok =
                 ConversationRoom.dispatch_message(
                   conversation_id,
                   p1.participant_id,
                   "Valid string length check input window"
                 )
      end

      # 51st message must trigger circuit-breaker mechanism
      assert {:error, :buffer_overflow_imminent} =
               ConversationRoom.dispatch_message(
                 conversation_id,
                 p1.participant_id,
                 "Overflow payload string"
               )
    end
  end
end
