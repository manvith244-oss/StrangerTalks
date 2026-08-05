# filepath: test/strangertalks_new/conversation_lifecycle_test.exs
defmodule StrangertalksNew.ConversationLifecycle.ConversationLifecycleTest do
  use StrangertalksNew.DataCase, async: true

  alias StrangertalksNew.ConversationLifecycle.Conversations
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Repo

  @pubsub_topic "strangertalks:matchmaking"

  # --- Programmatic Test Fixture Helpers ---

  defp participant_fixture(attrs \\ %{}) do
    struct(
      StrangertalksNew.Participant,
      Map.merge(
        %{
          participant_id: Ecto.UUID.generate(),
          presence_state: :ONLINE
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp match_fixture(participant_a_id, participant_b_id, attrs \\ %{}) do
    now = DateTime.utc_now()
    score_default = Decimal.new("1.0")

    match_attrs =
      Map.merge(
        %{
          match_id: Ecto.UUID.generate(),
          participant_a_id: participant_a_id,
          participant_b_id: participant_b_id,
          door_type: "SOMETHING_REAL",
          match_status: "ACTIVE",
          match_strategy: "COMPATIBILITY",
          compatibility_score: score_default,
          opportunity_score: score_default,
          scarcity_adjustment: score_default,
          conversation_temperature: score_default,
          mutual_participation_score: score_default,
          conversation_health_score: score_default,
          match_quality_score: score_default,
          queue_entry_time: now,
          match_found_time: now,
          queue_duration_seconds: 0,
          conversation_duration_seconds: 0,
          conversation_started: true,
          conversation_completed: false,
          memory_created: false,
          relationship_created: false,
          reconnected_later: false,
          report_generated: false,
          block_generated: false,
          safety_review_required: false,
          learning_processed: false,
          learning_version: "1",
          created_at: now
        },
        attrs
      )

    %StrangertalksNew.Matching{}
    |> StrangertalksNew.Matching.changeset(match_attrs)
    |> Repo.insert!()
  end

  # --- Test Lifecycle Setup ---

  setup do
    start_supervised!({Registry, keys: :unique, name: StrangertalksNew.DistributedRegistry})
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @pubsub_topic)

    c_id = Ecto.UUID.generate()

    p_a = participant_fixture()
    p_b = participant_fixture()
    match = match_fixture(p_a.participant_id, p_b.participant_id)

    {:ok,
     conversation_id: c_id,
     participant_a: p_a.participant_id,
     participant_b: p_b.participant_id,
     match_id: match.match_id}
  end

  describe "Ecto Persistence Layer Specifications" do
    test "successfully inserts conversation parameters with verified strategies", %{
      conversation_id: c_id,
      participant_a: p_id_a,
      participant_b: p_id_b,
      match_id: m_id
    } do
      attrs = %{
        conversation_id: c_id,
        match_id: m_id,
        participant_a_id: p_id_a,
        participant_b_id: p_id_b,
        match_strategy_used: :COMPATIBILITY,
        conversation_status: "ACTIVE",
        door_type: "SOMETHING_REAL",
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        participation_balance_score: Decimal.new("1.0"),
        message_exchange_rate: 0.0,
        conversation_depth_score: Decimal.new("0.0"),
        conversation_temperature: Decimal.new("1.0"),
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        bridge_effectiveness_score: Decimal.new("0.0"),
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        conversation_success_score: Decimal.new("0.0"),
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        safety_score: Decimal.new("1.0"),
        learning_processed: false,
        learning_version: "1",
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0,
        created_at: DateTime.utc_now()
      }

      assert {:ok, %StrangertalksNew.Conversation{} = conversation} =
               Conversations.create_conversation(attrs)

      # FIXED: Updated assertion tracking keys to target conversation_status field
      assert conversation.conversation_status == :ACTIVE
    end
  end

  describe "In-Memory Memory Ceiling & Buffer Restrictions" do
    test "activates circuit breaker block when message payload allocation breaches 256KB constraint limit",
         %{conversation_id: c_id} do
      child_spec = %{
        id: ConversationServer,
        start: {ConversationServer, :start_link, [%{conversation_id: c_id}]},
        restart: :transient
      }

      start_supervised!(child_spec)

      overflow_payload = String.duplicate("A", 262_145)
      sender_id = Ecto.UUID.generate()

      assert {:error, :buffer_overflow_imminent} =
               ConversationServer.append_message(c_id, sender_id, overflow_payload)
    end
  end

  describe "Network Resilience and Safety Intervention Pathways" do
    test "triggers safety intervention hook and executes immediate unannounced teardown sequence",
         %{conversation_id: c_id} do
      child_spec = %{
        id: ConversationServer,
        start: {ConversationServer, :start_link, [%{conversation_id: c_id}]},
        restart: :transient
      }

      start_supervised!(child_spec)

      :ok = ConversationServer.trigger_safety_terminate(c_id)

      assert_receive {:conversation_event, :"conversation.ended",
                      %{"payload" => %{"reason" => "SAFETY_TERMINATED"}}}
    end
  end
end
