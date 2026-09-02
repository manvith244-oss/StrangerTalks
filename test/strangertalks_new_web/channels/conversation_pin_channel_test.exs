defmodule StrangertalksNewWeb.ConversationPinChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Participants
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  setup do
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

  defp connect_and_join(participant, conversation) do
    token = ParticipantToken.sign(participant.participant_id)

    {:ok, socket} =
      connect(UserSocket, %{}, connect_info: %{auth_token: token})

    topic = "conversation:#{conversation.conversation_id}"

    {:ok, _reply, socket} =
      subscribe_and_join(socket, ConversationChannel, topic, %{})

    socket
  end

  test "channel message:pin routes mutation and broadcasts only to actor's tabs", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    _socket_a_tab2 = connect_and_join(context.participant_a, context.conversation)
    _socket_b = connect_and_join(context.participant_b, context.conversation)
    msg_id = Ecto.UUID.generate()
    conv_id = context.conversation.conversation_id

    # Create delivered text
    {:ok, _} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a.participant_id,
        msg_id,
        "Hello pin"
      )

    {:ok, _} =
      ConversationServer.acknowledge_message(
        conv_id,
        context.participant_b.participant_id,
        msg_id
      )

    ref =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => msg_id,
        "pinned" => true,
        "expected_pin_revision" => 0
      })

    assert_reply ref, :ok, %{status: "applied", revision: 1, pins: [pin]}
    assert pin.target_client_message_id == msg_id
    assert pin.snippet == "Hello pin"

    # Both sockets (tab 1 and tab 2) of participant A receive conversation:pins broadcast
    assert_push "conversation:pins", %{revision: 1, pins: [^pin]}
    assert_push "conversation:pins", %{revision: 1, pins: [^pin]}

    # Participant B receives NO broadcast
    refute_push "conversation:pins", _
  end

  test "Feature 1D channel admits approved expressive identity and delivers one canonical message",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    _socket_b = connect_and_join(context.participant_b, context.conversation)
    id = Ecto.UUID.generate()

    ref =
      push(socket_a, "message:send", %{
        "client_message_id" => id,
        "message_id" => id,
        "expressive_id" => "warm-wave"
      })

    assert_reply ref, :ok, %{client_message_id: ^id, sequence: 1}

    assert_push "message:new", %{
      type: "expressive",
      client_message_id: ^id,
      expressive: %{id: "warm-wave", asset_path: "/assets/expressive/warm-wave.svg"}
    }

    retry_ref =
      push(socket_a, "message:send", %{
        "client_message_id" => id,
        "message_id" => id,
        "expressive_id" => "warm-wave"
      })

    assert_reply retry_ref, :ok, %{client_message_id: ^id, sequence: 1, duplicate: true}

    state =
      :sys.get_state(ConversationServer.lookup(context.conversation.conversation_id) |> elem(1))

    assert length(state.recent_messages) == 1
  end

  test "Feature 1D forged expressive attempts consume the normal message-send rate budget",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)

    replies =
      for attempt <- 1..21 do
        id = Ecto.UUID.generate()

        ref =
          push(socket_a, "message:send", %{
            "client_message_id" => id,
            "message_id" => id,
            "expressive_id" => "forged-#{attempt}",
            "url" => "https://evil.invalid/a.gif"
          })

        assert_reply ref, :error, reply
        reply
      end

    assert Enum.any?(replies, &(&1.code == "RATE_LIMITED"))

    state =
      :sys.get_state(ConversationServer.lookup(context.conversation.conversation_id) |> elem(1))

    assert state.recent_messages == []
  end

  test "channel payload validations and error mappings", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)

    # Invalid message UUID
    ref1 =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => "not-a-uuid",
        "pinned" => true,
        "expected_pin_revision" => 0
      })

    assert_reply ref1, :error, %{code: "INVALID_MESSAGE_ID"}

    # Invalid pinned non-boolean
    ref2 =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => Ecto.UUID.generate(),
        "pinned" => "true",
        "expected_pin_revision" => 0
      })

    assert_reply ref2, :error, %{code: "INVALID_PAYLOAD"}

    # Invalid expected revision
    ref3 =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => Ecto.UUID.generate(),
        "pinned" => true,
        "expected_pin_revision" => -1
      })

    assert_reply ref3, :error, %{code: "INVALID_PAYLOAD"}

    # Disallowed extra keys
    ref4 =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => Ecto.UUID.generate(),
        "pinned" => true,
        "expected_pin_revision" => 0,
        "extra_key" => "malicious"
      })

    assert_reply ref4, :error, %{code: "INVALID_PAYLOAD"}
  end

  test "channel rate limiting: 20 per 10s window", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    conv_id = context.conversation.conversation_id
    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a.participant_id,
        msg_id,
        "Rate limit test"
      )

    {:ok, _} =
      ConversationServer.acknowledge_message(
        conv_id,
        context.participant_b.participant_id,
        msg_id
      )

    for rev <- 0..18 do
      pinned = rem(rev, 2) == 0
      target_rev = if pinned, do: 0, else: 1

      _ref =
        push(socket_a, "message:pin", %{
          "target_client_message_id" => msg_id,
          "pinned" => pinned,
          "expected_pin_revision" => target_rev
        })
    end

    # Push 20th and 21st
    _ref20 =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => msg_id,
        "pinned" => true,
        "expected_pin_revision" => 0
      })

    ref21 =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => msg_id,
        "pinned" => false,
        "expected_pin_revision" => 1
      })

    assert_reply ref21, :error, %{code: "RATE_LIMITED"}
  end

  test "channel backpressure: mailbox soft limit produces CONVERSATION_BUSY", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.lookup(conv_id)

    :sys.suspend(pid)

    try do
      for _ <- 1..105 do
        send(pid, :dummy_message)
      end

      assert elem(Process.info(pid, :message_queue_len), 1) >= 100

      ref =
        push(socket_a, "message:pin", %{
          "target_client_message_id" => Ecto.UUID.generate(),
          "pinned" => true,
          "expected_pin_revision" => 0
        })

      assert_reply ref, :error, %{code: "CONVERSATION_BUSY"}
    after
      :sys.resume(pid)
      _ = :sys.get_state(pid)
    end
  end

  test "rate-limited mutation causes zero pin-state and zero revision mutation", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    conv_id = context.conversation.conversation_id
    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a.participant_id,
        msg_id,
        "Zero mutation rate test"
      )

    {:ok, _} =
      ConversationServer.acknowledge_message(
        conv_id,
        context.participant_b.participant_id,
        msg_id
      )

    # Exhaust rate limit budget (20 allowed mutations per 10s)
    for _ <- 1..20 do
      ref =
        push(socket_a, "message:pin", %{
          "target_client_message_id" => msg_id,
          "pinned" => true,
          "expected_pin_revision" => 0
        })

      assert_reply ref, :ok, _
    end

    {:ok, pid} = ConversationServer.lookup(conv_id)
    state_before = :sys.get_state(pid)
    pins_before = Map.get(state_before.pins, context.participant_a.participant_id)

    # 21st attempt is rate limited
    ref =
      push(socket_a, "message:pin", %{
        "target_client_message_id" => msg_id,
        "pinned" => true,
        "expected_pin_revision" => pins_before.revision
      })

    assert_reply ref, :error, %{code: "RATE_LIMITED"}

    state_after = :sys.get_state(pid)
    pins_after = Map.get(state_after.pins, context.participant_a.participant_id)

    assert pins_after.revision == pins_before.revision
    assert pins_after.items == pins_before.items
  end

  test "sync:reconcile returns participant-private canonical pin collection", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    conv_id = context.conversation.conversation_id
    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a.participant_id,
        msg_id,
        "Reconcile pin"
      )

    {:ok, _} =
      ConversationServer.acknowledge_message(
        conv_id,
        context.participant_b.participant_id,
        msg_id
      )

    {:ok, %{pins: [pinned_item]}} =
      ConversationServer.mutate_pin(
        conv_id,
        context.participant_a.participant_id,
        msg_id,
        true,
        0
      )

    # Push sync:reconcile
    ref =
      push(socket_a, "sync:reconcile", %{
        "last_applied_sequence" => 0
      })

    assert_reply ref, :ok, %{pins: %{revision: 1, items: [^pinned_item]}}
  end
end
