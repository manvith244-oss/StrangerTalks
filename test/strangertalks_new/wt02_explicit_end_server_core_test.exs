defmodule StrangertalksNew.WT02ExplicitEndServerCoreTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.DomainError
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  @terminal_constraint "wt02_team5_reject_terminal_ended_at"

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    drop_terminal_constraint()
    :ok
  end

  test "ACTIVE explicit End persistence failure is rejected and restores the pre-End runtime" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    _pid = activate_runtime(conversation_id, a.participant_id, b.participant_id)

    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent", message_id: ^message_id}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "team5 pending survives failed End"
             )

    drain_mailbox()
    assert active_reservations(conversation.match_id) == 2

    add_terminal_constraint()

    try do
      assert {:error, :end_not_committed} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      durable = Repo.get!(Conversation, conversation_id)
      assert durable.conversation_status == :ACTIVE
      assert durable.ended_at == nil
      assert active_reservations(conversation.match_id) == 2

      assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
      assert state.lifecycle_status == :ACTIVE
      assert state.terminal_intent == nil
      assert state.pending_count == 1
      assert Map.has_key?(state.pending, message_id)
      refute Map.has_key?(state.completed, message_id)

      assert Enum.find(state.recent_messages, &(&1.message_id == message_id)).delivery_status ==
               :sent

      refute_receive {:conversation_message_status, %{message_id: ^message_id, status: "failed"}},
                     100

      refute_receive {:conversation_completed, _payload}, 100
      refute_receive {:conversation_event, :"conversation.ended", _payload}, 100
    after
      drop_terminal_constraint()
    end
  end

  test "explicit End failure leaves no hidden retry that can later commit" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    _pid = activate_runtime(conversation_id, a.participant_id, b.participant_id)

    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")

    add_terminal_constraint()

    result =
      try do
        ConversationServer.complete_conversation(conversation_id, a.participant_id)
      after
        drop_terminal_constraint()
      end

    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE

    # The historical retry interval is 5 seconds. Once the injected DB failure is
    # removed, old behavior commits in the background. New explicit-End behavior must
    # stay ACTIVE because the caller was already told that the End did not commit.
    refute_receive {:conversation_completed, _payload}, 5_500
    refute_receive {:conversation_event, :"conversation.ended", _payload}, 100

    assert {:error, :end_not_committed} = result

    durable = Repo.get!(Conversation, conversation_id)
    assert durable.conversation_status == :ACTIVE
    assert durable.ended_at == nil
    assert active_reservations(conversation.match_id) == 2

    assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert state.lifecycle_status == :ACTIVE
    assert state.terminal_intent == nil
  end

  test "PENDING explicit End persistence failure restores PENDING authority without teardown" do
    %{conversation: conversation, a: a} = queue_match()
    conversation_id = conversation.conversation_id
    assert conversation.conversation_status == :PENDING

    _pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    assert Repo.get!(Conversation, conversation_id).conversation_status == :PENDING

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "team5 pending-path message survives failed End"
             )

    drain_mailbox()
    assert active_reservations(conversation.match_id) == 2

    add_terminal_constraint()

    try do
      assert {:error, :end_not_committed} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      durable = Repo.get!(Conversation, conversation_id)
      assert durable.conversation_status == :PENDING
      assert durable.ended_at == nil
      assert durable.ending_type == nil
      assert active_reservations(conversation.match_id) == 2

      assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
      assert state.lifecycle_status == :ACTIVE
      assert state.conversation.conversation_status == :PENDING
      assert state.terminal_intent == nil
      assert state.pending_count == 1
      assert Map.has_key?(state.pending, message_id)
      refute Map.has_key?(state.completed, message_id)

      refute_receive {:conversation_message_status,
                      %{
                        message_id: ^message_id,
                        status: "failed",
                        reason: "left_during_transition"
                      }},
                     100

      refute_receive {:conversation_completed, _payload}, 100
    after
      drop_terminal_constraint()
    end
  end

  test "successful ACTIVE explicit End still commits before final teardown and is idempotent" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    _pid = activate_runtime(conversation_id, a.participant_id, b.participant_id)

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "team5 successful End pending message"
             )

    drain_mailbox()

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.conversation_completed == true
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator == a.participant_id
    assert active_reservations(conversation.match_id) == 0

    assert_receive {:conversation_message_status,
                    %{
                      message_id: ^message_id,
                      status: "failed",
                      reason: "participant_completed"
                    }},
                   500

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)
  end

  test "successful PENDING explicit End remains FAILED PARTICIPANT_LEFT" do
    %{conversation: conversation, a: a} = queue_match()
    conversation_id = conversation.conversation_id
    assert conversation.conversation_status == :PENDING

    _pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               self(),
               nil,
               0
             )

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "team5 successful pending End"
             )

    drain_mailbox()

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :FAILED
    assert terminal.conversation_completed == false
    assert terminal.ending_type == :PARTICIPANT_LEFT
    assert terminal.ending_initiator == a.participant_id
    assert active_reservations(conversation.match_id) == 0

    assert_receive {:conversation_message_status,
                    %{
                      message_id: ^message_id,
                      status: "failed",
                      reason: "left_during_transition"
                    }},
                   500
  end

  test "END_NOT_COMMITTED is a stable retryable channel error" do
    assert %{
             code: "END_NOT_COMMITTED",
             category: "transport",
             retryable: true,
             reason: "end_not_committed"
           } = DomainError.to_channel_payload(:end_not_committed)
  end

  defp activate_runtime(conversation_id, a_id, b_id) do
    pid = start_supervised!({ConversationServer, %{conversation_id: conversation_id}})

    assert {:ok, _sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a_id,
               self(),
               nil,
               0
             )

    assert {:ok, _sync} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               b_id,
               self(),
               nil,
               0
             )

    assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
    drain_mailbox()
    pid
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

  defp active_reservations(match_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM participant_pairing_reservations WHERE match_id = $1 AND released_at IS NULL",
        [Ecto.UUID.dump!(match_id)]
      )

    count
  end

  defp add_terminal_constraint do
    drop_terminal_constraint()

    Repo.query!("""
    ALTER TABLE conversations
    ADD CONSTRAINT #{@terminal_constraint}
    CHECK (ended_at IS NULL)
    """)

    :ok
  end

  defp drop_terminal_constraint do
    Repo.query!("""
    ALTER TABLE conversations
    DROP CONSTRAINT IF EXISTS #{@terminal_constraint}
    """)

    :ok
  end

  defp drain_mailbox do
    receive do
      _message -> drain_mailbox()
    after
      0 -> :ok
    end
  end
end
