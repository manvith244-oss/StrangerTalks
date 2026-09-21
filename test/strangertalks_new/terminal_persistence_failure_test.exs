defmodule StrangertalksNew.TerminalPersistenceFailureTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{Conversation, Repo}

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "Block transaction failure rolls back BoundaryBlock and resumes the still-active runtime" do
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

    # Force only the terminal Conversation write to fail at the database boundary.
    # The preceding BoundaryBlock insert can succeed, but the enclosing transaction
    # must roll it back when ending_type=BLOCK is rejected.
    Repo.query!("""
    ALTER TABLE conversations
    ADD CONSTRAINT team2_reject_block_terminal
    CHECK (ending_type IS DISTINCT FROM 'BLOCK')
    """)

    block_result =
      try do
        MatchingRules.block_conversation_participant(conversation_id, a.participant_id)
      after
        Repo.query!("""
        ALTER TABLE conversations
        DROP CONSTRAINT team2_reject_block_terminal
        """)
      end

    assert {:error, _reason} = block_result

    # The failed terminal write rolls back the preceding BoundaryBlock insert. No
    # durable safety authority may be reported when terminal persistence failed.
    refute MatchingRules.check_safety_veto?(a.participant_id, b.participant_id)

    durable = Repo.get!(Conversation, conversation_id)
    assert durable.conversation_status == :ACTIVE
    assert durable.ended_at == nil
    assert durable.ending_type == nil
    assert durable.ending_initiator == nil

    # The suspended runtime is resumed rather than killed or left inert. Because the
    # Block transaction did not commit, the original active Conversation remains the
    # canonical authority and can continue accepting normal mutations.
    assert Process.alive?(pid)
    assert {:ok, %{lifecycle_status: :ACTIVE}} = ConversationServer.inspect_state(conversation_id)

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               "transaction rollback keeps the original Conversation active"
             )
  end

  test "End persistence failure returns retryable error and restores active runtime without retry authority" do
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

    :sys.replace_state(pid, fn state ->
      %{state | conversation: %{state.conversation | participant_b_id: nil}}
    end)

    assert {:error, :end_not_committed} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    after_failure = Repo.get!(Conversation, conversation_id)
    assert after_failure.conversation_status == :ACTIVE
    assert after_failure.ended_at == nil
    refute_receive {:conversation_completed, _payload}, 100
    assert Process.alive?(pid)

    assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert state.lifecycle_status == :ACTIVE
    assert state.terminal_intent == nil

    assert_eventually(fn -> ConversationServer.lookup(conversation_id) == {:ok, pid} end)

    :sys.replace_state(pid, fn state -> %{state | conversation: durable_active} end)

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               "failed End returns authority to the active conversation"
             )
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
