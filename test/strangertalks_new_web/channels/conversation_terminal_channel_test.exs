defmodule StrangertalksNewWeb.ConversationTerminalChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{Conversation, Conversations, Participants, Repo}
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

    assert {:ok, truth} = Conversations.terminal_truth(terminal)
    assert truth.conversation_status == :ENDED
    assert truth.ending_type == :BLOCK
    assert truth.client_event == %{status: "ended", reason: "blocked"}

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

    assert {:ok, truth} = Conversations.terminal_truth(terminal)
    assert truth.client_event == %{status: "ended", reason: "participant_completed"}

    assert_eventually(fn ->
      ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}
    end)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(
               context.conversation.conversation_id,
               context.participant_a.participant_id
             )

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

  test "End first then stale Block preserves and reasserts canonical End truth", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)

    end_ref = push(socket_a, "conversation:end", %{})
    assert_reply end_ref, :ok, %{status: "ended"}

    for _ <- 1..2 do
      assert_push "conversation:ended", %{status: "ended", reason: "participant_completed"}
    end

    before_block = Repo.get!(Conversation, context.conversation.conversation_id)
    assert before_block.conversation_status == :ENDED
    assert before_block.ending_type == :NATURAL_END
    assert before_block.ending_initiator == context.participant_a.participant_id

    block_ref = push(socket_b, "conversation:block", %{})
    assert_reply block_ref, :ok, %{status: "blocked"}

    for _ <- 1..2 do
      assert_push "conversation:ended", %{status: "ended", reason: "participant_completed"}
    end

    after_block = Repo.get!(Conversation, context.conversation.conversation_id)
    assert after_block.conversation_status == :ENDED
    assert after_block.ending_type == :NATURAL_END
    assert after_block.ending_initiator == context.participant_a.participant_id
    assert after_block.conversation_completed == true

    assert {:ok, truth} = Conversations.terminal_truth(after_block)
    assert truth.client_event == %{status: "ended", reason: "participant_completed"}
  end

  test "Block first then duplicate End cannot replace canonical Block truth", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)

    block_ref = push(socket_a, "conversation:block", %{})
    assert_reply block_ref, :ok, %{status: "blocked"}

    for _ <- 1..2 do
      assert_push "conversation:ended", %{status: "ended", reason: "blocked"}
    end

    assert_eventually(fn ->
      ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}
    end)

    end_ref = push(socket_b, "conversation:end", %{})
    assert_reply end_ref, :error, %{code: "CONVERSATION_UNAVAILABLE"}
    refute_push "conversation:ended", %{reason: "participant_completed"}, 100

    terminal = Repo.get!(Conversation, context.conversation.conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :BLOCK
    assert terminal.ending_initiator == context.participant_a.participant_id
    assert terminal.conversation_completed == false

    assert {:ok, truth} = Conversations.terminal_truth(terminal)
    assert truth.client_event == %{status: "ended", reason: "blocked"}
  end

  test "ordinary End rejects stale live-only operations across Conversation feature families",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    _socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{
        "client_message_id" => message_id,
        "content" => "seed before terminal"
      })

    assert_reply send_ref, :ok, %{status: "sent"}

    end_ref = push(socket_a, "conversation:end", %{})
    assert_reply end_ref, :ok, %{status: "ended"}

    for _ <- 1..2 do
      assert_push "conversation:ended", %{status: "ended", reason: "participant_completed"}
    end

    assert_eventually(fn ->
      ConversationServer.lookup(context.conversation.conversation_id) == {:error, :not_started}
    end)

    stale_operations = [
      {"message:send",
       %{"client_message_id" => Ecto.UUID.generate(), "content" => "stale after End"}},
      {"message:edit",
       %{
         "target_client_message_id" => message_id,
         "expected_content_revision" => 0,
         "content" => "stale edit"
       }},
      {"message:unsend",
       %{"target_client_message_id" => message_id, "expected_content_revision" => 0}},
      {"message:react",
       %{
         "target_client_message_id" => message_id,
         "desired_reaction" => "❤️",
         "expected_reaction_revision" => 0
       }},
      {"message:pin",
       %{
         "target_client_message_id" => message_id,
         "pinned" => true,
         "expected_pin_revision" => 0
       }},
      {"typing:start", %{}},
      {"view_once:open", %{"target_client_message_id" => message_id}},
      {"voice_note:ack", %{"voice_note_id" => Ecto.UUID.generate()}},
      {"call:initiate", %{"call_type" => "voice"}},
      {"call:accept", %{"call_attempt_id" => Ecto.UUID.generate()}},
      {"call:request_credentials", %{"call_attempt_id" => Ecto.UUID.generate()}},
      {"sync:reconcile", %{"last_applied_sequence" => 0}}
    ]

    for {event, payload} <- stale_operations do
      stale_ref = push(socket_a, event, payload)
      assert_reply stale_ref, :error, %{code: "CONVERSATION_UNAVAILABLE"}
    end
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
