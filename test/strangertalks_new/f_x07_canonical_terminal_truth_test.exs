defmodule StrangertalksNew.FX07CanonicalTerminalTruthTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{Conversation, MatchingRules, Repo}

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "X07-03 durable End wins over a later stale Block terminal broadcast" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id

    activate_conversation(conversation_id, a.participant_id, b.participant_id)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    assert_eventually(fn ->
      ConversationServer.lookup(conversation_id) == {:error, :not_started}
    end)

    ended = Repo.get!(Conversation, conversation_id)
    assert ended.conversation_status == :ENDED
    assert ended.ending_type == :NATURAL_END
    assert ended.conversation_completed == true

    :ok = StrangertalksNewWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(conversation_id, b.participant_id)

    canonical = Repo.get!(Conversation, conversation_id)
    assert canonical.conversation_status == :ENDED
    assert canonical.ending_type == :NATURAL_END
    assert canonical.conversation_completed == true

    refute_receive %Phoenix.Socket.Broadcast{
                     topic: "conversation:" <> ^conversation_id,
                     event: "conversation:ended",
                     payload: %{status: "ended", reason: "blocked"}
                   },
                   200
  end

  test "X07-04 durable Block wins over a later duplicate End" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id

    activate_conversation(conversation_id, a.participant_id, b.participant_id)

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(conversation_id, a.participant_id)

    blocked = Repo.get!(Conversation, conversation_id)
    assert blocked.conversation_status == :ENDED
    assert blocked.ending_type == :BLOCK
    assert blocked.ending_initiator == a.participant_id
    assert blocked.conversation_completed == false

    assert_eventually(fn ->
      ConversationServer.lookup(conversation_id) == {:error, :not_started}
    end)

    :ok = StrangertalksNewWeb.Endpoint.subscribe("conversation:#{conversation_id}")

    assert {:error, :conversation_unavailable} =
             ConversationServer.complete_conversation(conversation_id, b.participant_id)

    canonical = Repo.get!(Conversation, conversation_id)
    assert canonical.conversation_status == :ENDED
    assert canonical.ending_type == :BLOCK
    assert canonical.ending_initiator == a.participant_id
    assert canonical.conversation_completed == false

    refute_receive %Phoenix.Socket.Broadcast{
                     topic: "conversation:" <> ^conversation_id,
                     event: "conversation:ended",
                     payload: %{status: "ended", reason: "participant_completed"}
                   },
                   200
  end

  defp activate_conversation(conversation_id, participant_a_id, participant_b_id) do
    _pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               participant_a_id,
               self(),
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               participant_b_id,
               self(),
               nil,
               0
             )

    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
    :ok
  end

  defp queue_match do
    a = participant_fixture()
    b = participant_fixture()

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    %{
      conversation: Repo.get_by!(Conversation, match_id: match_id),
      a: a,
      b: b
    }
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
