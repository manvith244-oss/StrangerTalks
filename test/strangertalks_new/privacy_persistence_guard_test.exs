defmodule StrangertalksNew.PrivacyPersistenceGuardTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine

  setup do
    Agent.update(StrangertalksNew.QueueEngine.QueueState, fn _ -> %{} end)
    :ok
  end

  test "normal live send and reaction create zero legacy durable transcript rows" do
    fixture = conversation_fixture()
    conv_id = fixture.conversation.conversation_id

    {:ok, pid} = ConversationServer.ensure_started(conv_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
      end
    end)

    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               fixture.participant_a,
               message_id,
               "RAM-first privacy regression"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, fixture.participant_b, message_id)

    assert {:ok, %{status: "applied"}} =
             ConversationServer.mutate_reaction(
               conv_id,
               fixture.participant_b,
               message_id,
               "❤️",
               0
             )

    assert Repo.one(from row in "messages", select: count()) == 0
    assert Repo.one(from row in "message_reactions", select: count()) == 0
  end

  test "canonical queue and match flow creates zero durable QueueState rows" do
    a = participant_fixture()
    b = participant_fixture()

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", 7, 120.0)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", 7, 120.0)
    assert {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()

    assert Repo.one(from row in "queue_states", select: count()) == 0
  end

  test "current V1 intelligence and learning snapshot path creates zero participant-linked learning rows" do
    to = DateTime.utc_now()
    from = DateTime.add(to, -3_600, :second)

    assert {:ok, snapshot} = StrangertalksNew.Intelligence.V1Metrics.snapshot(from, to)
    assert is_map(snapshot)
    assert {:ok, []} = StrangertalksNew.AgentSystems.LearningAdvisor.snapshot(12)

    assert Repo.one(from row in "learning_records", select: count()) == 0
  end

  test "participant-facing router exposes no report safety-media read endpoint" do
    paths =
      StrangertalksNewWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)

    refute Enum.any?(paths, &String.contains?(&1, "report_safety_media"))
    refute Enum.any?(paths, &String.contains?(&1, "safety-media"))
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
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
        created_at: now,
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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

    %{
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
