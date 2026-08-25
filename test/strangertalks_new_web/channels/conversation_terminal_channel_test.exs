defmodule StrangertalksNewWeb.ConversationTerminalChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{Conversation, Participants, Repo}
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  setup do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0"),
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
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
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

    {:ok, pid} = ConversationServer.ensure_started(conversation.conversation_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
      end
    end)

    %{
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b
    }
  end

  test "Block broadcasts authoritative terminal state to blocker, peer, and sibling tab",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    _socket_a_sibling = connect_and_join(context.participant_a, context.conversation)

    ref = push(socket_a, "conversation:block", %{})
    assert_reply ref, :ok, %{status: "blocked"}

    for _ <- 1..3 do
      assert_push "conversation:ended", %{status: "ended", reason: "blocked"}
    end

    terminal = Repo.get!(Conversation, context.conversation.conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :BLOCK
    assert terminal.ending_initiator == context.participant_a.participant_id
    assert terminal.safety_flagged == true
    assert terminal.conversation_completed == false

    assert_eventually(fn ->
      ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}
    end)

    stale_ref =
      push(socket_b, "message:send", %{
        "client_message_id" => Ecto.UUID.generate(),
        "content" => "must not survive Block"
      })

    assert_reply stale_ref, :error, %{code: "CONVERSATION_UNAVAILABLE"}

    fresh_socket = connect_socket(context.participant_b)

    assert {:error, _terminal_join_error} =
             subscribe_and_join(
               fresh_socket,
               ConversationChannel,
               "conversation:#{context.conversation.conversation_id}",
               %{}
             )
  end

  test "duplicate successful Block is idempotent and reasserts terminal authority", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    _socket_b = connect_and_join(context.participant_b, context.conversation)

    first = push(socket_a, "conversation:block", %{})
    assert_reply first, :ok, %{status: "blocked"}
    assert_push "conversation:ended", %{status: "ended", reason: "blocked"}
    assert_push "conversation:ended", %{status: "ended", reason: "blocked"}

    second = push(socket_a, "conversation:block", %{})
    assert_reply second, :ok, %{status: "blocked"}
    assert_push "conversation:ended", %{status: "ended", reason: "blocked"}
    assert_push "conversation:ended", %{status: "ended", reason: "blocked"}

    terminal = Repo.get!(Conversation, context.conversation.conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :BLOCK
    assert terminal.ending_initiator == context.participant_a.participant_id

    assert {:error, :terminal_conversation} =
             ConversationServer.ensure_started(context.conversation.conversation_id)
  end

  test "ordinary End still terminalizes both clients and rejects stale authority", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)

    ref = push(socket_a, "conversation:end", %{})
    assert_reply ref, :ok, %{status: "ended"}

    for _ <- 1..2 do
      assert_push "conversation:ended", %{status: "ended", reason: "participant_completed"}
    end

    terminal = Repo.get!(Conversation, context.conversation.conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator == context.participant_a.participant_id
    assert terminal.conversation_completed == true

    assert_eventually(fn ->
      ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}
    end)

    stale_ref = push(socket_b, "typing:start", %{})
    assert_reply stale_ref, :error, %{code: "CONVERSATION_UNAVAILABLE"}

    fresh_socket = connect_socket(context.participant_b)

    assert {:error, _terminal_join_error} =
             subscribe_and_join(
               fresh_socket,
               ConversationChannel,
               "conversation:#{context.conversation.conversation_id}",
               %{}
             )
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp connect_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp connect_and_join(participant, conversation) do
    socket = connect_socket(participant)

    {:ok, _reply, socket} =
      subscribe_and_join(
        socket,
        ConversationChannel,
        "conversation:#{conversation.conversation_id}",
        %{}
      )

    socket
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
