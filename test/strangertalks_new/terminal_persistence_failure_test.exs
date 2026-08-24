defmodule StrangertalksNew.TerminalPersistenceFailureTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{Conversation, Repo}

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "End persistence failure reports ending, emits no terminal authority, then converges only after durable retry" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               b.participant_id,
               self(),
               nil,
               0
             )

    durable_active = Repo.get!(Conversation, conversation_id)
    assert durable_active.conversation_status == :ACTIVE

    # Corrupt only the runtime copy of one required persistence field. The durable row
    # remains valid and ACTIVE, but the first terminal changeset must fail validation.
    :sys.replace_state(pid, fn state ->
      %{state | conversation: %{state.conversation | participant_b_id: nil}}
    end)

    assert {:ok, %{status: "ending"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    # A persistence failure is not terminal authority: the durable row is still ACTIVE,
    # no terminal event was delivered, and the runtime remains alive only to retry.
    after_failure = Repo.get!(Conversation, conversation_id)
    assert after_failure.conversation_status == :ACTIVE
    refute_receive {:conversation_completed, _payload}, 100
    assert Process.alive?(pid)

    terminating_state = :sys.get_state(pid)
    assert terminating_state.lifecycle_status == :TERMINATING
    assert %{retry_token: retry_token} = terminating_state.terminal_intent
    assert is_reference(retry_token)

    assert {:error, :conversation_inactive} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               "must not mutate while terminal persistence is unresolved"
             )

    # Repair the runtime copy to the canonical durable row and trigger the exact retry
    # token. Only the successful durable write may now emit terminal authority.
    :sys.replace_state(pid, fn state -> %{state | conversation: durable_active} end)
    send(pid, {:retry_terminal_persistence, retry_token})

    assert_receive {:conversation_completed,
                    %{status: "ended", reason: "participant_completed"}}, 1_000

    assert_eventually(fn ->
      ConversationServer.lookup(conversation_id) == {:error, :not_started}
    end)

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator == a.participant_id
    assert terminal.conversation_completed == true

    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)
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
