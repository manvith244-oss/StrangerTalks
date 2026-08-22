# filepath: test/strangertalks_new/conversation_lifecycle_test.exs
defmodule StrangertalksNew.ConversationLifecycle.ConversationLifecycleTest do
  use StrangertalksNew.DataCase, async: false

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
          conversation_language: "en",
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
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, @pubsub_topic)

    p_a = participant_fixture()
    p_b = participant_fixture()
    match = match_fixture(p_a.participant_id, p_b.participant_id)

    {:ok, conversation} =
      Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        conversation_status: :ACTIVE,
        door_type: :SOMETHING_REAL,
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
        duration_seconds: 0,
        created_at: DateTime.utc_now()
      })

    {:ok,
     conversation_id: conversation.conversation_id,
     participant_a: p_a.participant_id,
     participant_b: p_b.participant_id,
     match_id: match.match_id}
  end

  describe "Ecto Persistence Layer Specifications" do
    test "successfully inserts conversation parameters with verified strategies", %{
      conversation_id: c_id,
      participant_a: p_id_a,
      participant_b: p_id_b
    } do
      Repo.get!(StrangertalksNew.Conversation, c_id)
      |> StrangertalksNew.Conversation.changeset(%{conversation_status: :ENDED})
      |> Repo.update!()

      second_match = match_fixture(p_id_a, p_id_b)

      attrs = %{
        conversation_id: c_id,
        match_id: second_match.match_id,
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
         %{conversation_id: c_id, participant_a: sender_id} do
      child_spec = %{
        id: ConversationServer,
        start: {ConversationServer, :start_link, [%{conversation_id: c_id}]},
        restart: :transient
      }

      start_supervised!(child_spec)

      overflow_payload = String.duplicate("A", 262_145)

      assert {:error, :message_too_large} =
               ConversationServer.append_message(
                 c_id,
                 sender_id,
                 Ecto.UUID.generate(),
                 overflow_payload
               )
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

  describe "transition survivor recovery" do
    test "final registration wins deterministically before terminal end", %{
      conversation_id: conversation_id,
      participant_a: ending_id,
      participant_b: final_peer_id,
      match_id: match_id
    } do
      set_pending!(conversation_id)
      {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      assert :ok = ConversationServer.register_channel(conversation_id, ending_id, self())

      register_ref = make_ref()
      end_ref = make_ref()
      monitor_ref = Process.monitor(pid)

      send(
        pid,
        {:"$gen_call", {self(), register_ref}, {:register_channel, final_peer_id, self()}}
      )

      send(pid, {:"$gen_call", {self(), end_ref}, {:complete_conversation, ending_id}})

      assert_receive {^register_ref, :ok}
      assert_receive {^end_ref, {:ok, %{status: "ended"}}}
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}

      assert Repo.get!(StrangertalksNew.Conversation, conversation_id).conversation_status ==
               :ENDED

      match = Repo.get!(StrangertalksNew.Matching, match_id)
      assert match.match_status == :ACTIVE
      refute match.failure_reason == :LEFT_DURING_TRANSITION
      refute queued?(ending_id)
      refute queued?(final_peer_id)
    end

    test "terminal end wins deterministically before final registration", %{
      conversation_id: conversation_id,
      participant_a: ending_id,
      participant_b: final_peer_id,
      match_id: match_id
    } do
      set_pending!(conversation_id)
      {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      assert :ok = ConversationServer.register_channel(conversation_id, ending_id, self())

      end_ref = make_ref()
      register_ref = make_ref()
      monitor_ref = Process.monitor(pid)

      send(pid, {:"$gen_call", {self(), end_ref}, {:complete_conversation, ending_id}})

      send(
        pid,
        {:"$gen_call", {self(), register_ref}, {:register_channel, final_peer_id, self()}}
      )

      assert_receive {^end_ref, {:ok, %{status: "ended"}}}
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}
      refute_receive {^register_ref, _reply}

      conversation = Repo.get!(StrangertalksNew.Conversation, conversation_id)
      assert conversation.conversation_status == :FAILED
      assert conversation.ending_type == :PARTICIPANT_LEFT

      match = Repo.get!(StrangertalksNew.Matching, match_id)
      assert match.match_status == :FAILED
      assert match.failure_reason == :LEFT_DURING_TRANSITION
      assert queued?(final_peer_id)
      refute queued?(ending_id)
    end

    test "durable terminal state survives unavailable survivor admission owner", %{
      conversation_id: conversation_id,
      participant_a: leaving_id,
      participant_b: survivor_id,
      match_id: match_id
    } do
      set_pending!(conversation_id)
      {:ok, _pid} = ConversationServer.ensure_started(conversation_id)
      assert :ok = ConversationServer.register_channel(conversation_id, leaving_id, self())

      assert :ok =
               Supervisor.terminate_child(
                 StrangertalksNew.Supervisor,
                 StrangertalksNew.QueueEngine.QueueState
               )

      on_exit(fn -> ensure_queue_state_started() end)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, leaving_id)

      assert_receive {:transition_recovery_failed, ^survivor_id, ^conversation_id}

      conversation = Repo.get!(StrangertalksNew.Conversation, conversation_id)
      match = Repo.get!(StrangertalksNew.Matching, match_id)
      assert conversation.conversation_status == :FAILED
      assert conversation.ending_type == :PARTICIPANT_LEFT
      assert match.match_status == :FAILED
      assert match.failure_reason == :LEFT_DURING_TRANSITION

      ensure_queue_state_started()

      assert {:ok, %{canonical_state: :AVAILABLE, conversation: nil, queue: nil}} =
               StrangertalksNew.SessionReconciliation.reconcile(survivor_id)

      refute queued?(survivor_id)
    end

    test "a terminal leave from PENDING fails old authority and requeues only the survivor once",
         %{
           conversation_id: conversation_id,
           participant_a: leaving_id,
           participant_b: survivor_id,
           match_id: match_id
         } do
      Repo.get!(StrangertalksNew.Matching, match_id)
      |> StrangertalksNew.Matching.changeset(%{
        participant_a_door_type: :JUST_TALK,
        participant_b_door_type: :EXPLORE,
        conversation_language: "en",
        door_type: nil
      })
      |> Repo.update!()

      Repo.get!(StrangertalksNew.Conversation, conversation_id)
      |> StrangertalksNew.Conversation.changeset(%{
        conversation_status: :PENDING,
        door_type: nil
      })
      |> Repo.update!()

      {:ok, pid} = ConversationServer.ensure_started(conversation_id)
      monitor_ref = Process.monitor(pid)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, leaving_id)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}

      failed_conversation = Repo.get!(StrangertalksNew.Conversation, conversation_id)
      failed_match = Repo.get!(StrangertalksNew.Matching, match_id)

      assert failed_conversation.conversation_status == :FAILED
      assert failed_conversation.ending_type == :PARTICIPANT_LEFT
      assert failed_conversation.ending_initiator == leaving_id
      assert failed_match.match_status == :FAILED
      assert failed_match.failure_reason == :LEFT_DURING_TRANSITION

      queue_state = Agent.get(StrangertalksNew.QueueEngine.QueueState, & &1)

      assert %{door_selection: :EXPLORE, queue_attempt_id: attempt_id} =
               Map.fetch!(queue_state, survivor_id)

      assert is_binary(attempt_id)
      refute Map.has_key?(queue_state, leaving_id)

      assert_receive {:transition_survivor_requeued, ^survivor_id, ^conversation_id, ^attempt_id}

      assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, leaving_id)

      queue_state_after_duplicate = Agent.get(StrangertalksNew.QueueEngine.QueueState, & &1)
      assert get_in(queue_state_after_duplicate, [survivor_id, :queue_attempt_id]) == attempt_id
      refute Map.has_key?(queue_state_after_duplicate, leaving_id)
    end

    test "a second terminal leaver removes only this transition's survivor recovery", %{
      conversation_id: conversation_id,
      participant_a: first_leaver_id,
      participant_b: second_leaver_id
    } do
      Repo.get!(StrangertalksNew.Conversation, conversation_id)
      |> StrangertalksNew.Conversation.changeset(%{conversation_status: :PENDING})
      |> Repo.update!()

      {:ok, _pid} = ConversationServer.ensure_started(conversation_id)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, first_leaver_id)

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, second_leaver_id)

      refute Agent.get(
               StrangertalksNew.QueueEngine.QueueState,
               &Map.has_key?(&1, second_leaver_id)
             )

      assert {:ok, %{queue_attempt_id: newer_attempt_id}} =
               StrangertalksNew.Matchmaking.MatchmakingEngine.join_queue(
                 second_leaver_id,
                 :SOMETHING_REAL,
                 "en",
                 nil,
                 nil
               )

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, second_leaver_id)

      assert %{queue_attempt_id: ^newer_attempt_id} =
               Agent.get(
                 StrangertalksNew.QueueEngine.QueueState,
                 &Map.fetch!(&1, second_leaver_id)
               )
    end
  end

  defp set_pending!(conversation_id) do
    Repo.get!(StrangertalksNew.Conversation, conversation_id)
    |> StrangertalksNew.Conversation.changeset(%{conversation_status: :PENDING})
    |> Repo.update!()
  end

  defp queued?(participant_id) do
    Agent.get(StrangertalksNew.QueueEngine.QueueState, &Map.has_key?(&1, participant_id))
  end

  defp ensure_queue_state_started do
    case Process.whereis(StrangertalksNew.QueueEngine.QueueState) do
      nil ->
        case Supervisor.restart_child(
               StrangertalksNew.Supervisor,
               StrangertalksNew.QueueEngine.QueueState
             ) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
