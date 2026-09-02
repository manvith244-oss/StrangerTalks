defmodule StrangertalksNewWeb.ConversationReactionChannelTest do
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

  defp setup_telemetry_handler(event_name, test_pid) do
    handler_id = "test-channel-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end

  test "channel message:react applies reaction and pushes message:reaction live update",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)

    msg_id = Ecto.UUID.generate()

    # Participant A sends message
    ref = push(socket_a, "message:send", %{"client_message_id" => msg_id, "content" => "Hello"})
    assert_reply ref, :ok, %{status: "sent", sequence: sequence}

    ref_ack =
      push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))

    assert_reply ref_ack, :ok, %{status: "applied"}

    # Participant B reacts with "❤️"
    ref_react =
      push(socket_b, "message:react", %{
        "target_client_message_id" => msg_id,
        "desired_reaction" => "❤️",
        "expected_reaction_revision" => 0
      })

    assert_reply ref_react, :ok, %{
      status: "applied",
      target_client_message_id: ^msg_id,
      emoji: "❤️",
      revision: 1
    }

    # Participant A receives push notification
    assert_push "message:reaction", %{
      target_client_message_id: ^msg_id,
      owner_relation: "peer",
      emoji: "❤️",
      revision: 1
    }
  end

  test "shared rate limit: same participant across multiple sockets shares the 20/10s budget",
       context do
    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :check_failed],
      self()
    )

    socket1 = connect_and_join(context.participant_a, context.conversation)
    socket2 = connect_and_join(context.participant_a, context.conversation)

    msg_id = Ecto.UUID.generate()

    ref = push(socket1, "message:send", %{"client_message_id" => msg_id, "content" => "Msg"})
    assert_reply ref, :ok, %{status: "sent"}

    # Acknowledge
    {:ok, _} =
      ConversationServer.acknowledge_message(
        context.conversation.conversation_id,
        context.participant_b.participant_id,
        msg_id
      )

    # Exhaust 20 attempts using socket1
    for i <- 1..20 do
      ref =
        push(socket1, "message:react", %{
          "target_client_message_id" => msg_id,
          "desired_reaction" => if(rem(i, 2) == 0, do: "❤️", else: "😂"),
          "expected_reaction_revision" => i - 1
        })

      assert_reply ref, :ok, %{status: "applied"}
    end

    # 21st attempt on socket2 (different socket, same participant & conversation) must be rate-limited
    ref21 =
      push(socket2, "message:react", %{
        "target_client_message_id" => msg_id,
        "desired_reaction" => "😭",
        "expected_reaction_revision" => 20
      })

    assert_reply ref21, :error, %{code: "RATE_LIMITED", retryable: true}

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :check_failed],
                     %{count: 1}, %{reason_code: "RATE_LIMITED"}}
  end

  test "telemetry exclusions: sent/failed targets, absent targets emit ZERO check_failed",
       context do
    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :check_failed],
      self()
    )

    socket_b = connect_and_join(context.participant_b, context.conversation)
    conv_id = context.conversation.conversation_id

    # 1. Sent target (:sent)
    sent_msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a.participant_id,
        sent_msg_id,
        "Sent"
      )

    ref_sent =
      push(socket_b, "message:react", %{
        "target_client_message_id" => sent_msg_id,
        "desired_reaction" => "❤️",
        "expected_reaction_revision" => 0
      })

    assert_reply ref_sent, :error, %{code: "INVALID_REQUEST"}

    # 2. Absent valid target
    absent_id = Ecto.UUID.generate()

    ref_absent =
      push(socket_b, "message:react", %{
        "target_client_message_id" => absent_id,
        "desired_reaction" => "❤️",
        "expected_reaction_revision" => 0
      })

    assert_reply ref_absent, :ok, %{status: "target_absent"}

    # Confirm ZERO check_failed telemetry
    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :check_failed], _,
                     _}
  end

  test "backpressure owning boundary: deliberate mailbox soft-limit sheds reaction with CONVERSATION_BUSY and check_failed telemetry while preserving higher-priority message/ack paths",
       context do
    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :check_failed],
      self()
    )

    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :applied],
      self()
    )

    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :idempotent],
      self()
    )

    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :stale],
      self()
    )

    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :target_absent],
      self()
    )

    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    conv_id = context.conversation.conversation_id
    msg_id = Ecto.UUID.generate()

    # Participant A sends message
    ref_send =
      push(socket_a, "message:send", %{
        "client_message_id" => msg_id,
        "content" => "Backpressure Target"
      })

    assert_reply ref_send, :ok, %{status: "sent", sequence: sequence}

    ref_ack =
      push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))

    assert_reply ref_ack, :ok, %{status: "applied"}

    {:ok, server_pid} = ConversationServer.lookup(conv_id)
    {:ok, state_before} = ConversationServer.inspect_state(conv_id)
    seq_before = state_before.next_sequence

    # Deliberately induce mailbox soft-limit pressure (>= 100 messages)
    :sys.suspend(server_pid)

    try do
      for _ <- 1..105, do: send(server_pid, :pressure_dummy)
      assert elem(Process.info(server_pid, :message_queue_len), 1) >= 100

      # 1. Reaction mutation must be rejected before canonical mutation
      ref_react =
        push(socket_b, "message:react", %{
          "target_client_message_id" => msg_id,
          "desired_reaction" => "❤️",
          "expected_reaction_revision" => 0
        })

      assert_reply ref_react, :error, %{code: "CONVERSATION_BUSY", retryable: true}
    after
      :sys.resume(server_pid)
      _ = :sys.get_state(server_pid)
    end

    # 2. Canonical state and sequence remain completely unchanged
    {:ok, state_after} = ConversationServer.inspect_state(conv_id)
    assert state_after.next_sequence == seq_before
    target_msg = Enum.find(state_after.recent_messages, &(&1.client_message_id == msg_id))
    assert Map.get(target_msg, :reactions, %{}) == %{}

    # 3. Zero fanout occurred
    refute_push "message:reaction", _

    # 4. Telemetry check_failed emitted exactly once; zero applied/idempotent/stale/target_absent
    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :check_failed],
                     %{count: 1}, %{reason_code: "CONVERSATION_BUSY"}}

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied], _, _}

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :idempotent], _,
                     _}

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :stale], _, _}

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :target_absent],
                     _, _}

    # 5. Higher-priority preservation under mailbox pressure
    # Soft limit (100) sheds reactions, but higher-priority append (@mailbox_hard_limit = 500)
    # and ACK (safe_call) remain admissible.
    :sys.suspend(server_pid)

    try do
      for _ <- 1..105, do: send(server_pid, :pressure_dummy)
      assert elem(Process.info(server_pid, :message_queue_len), 1) >= 100

      # Under 105 messages in mailbox, reaction is shed
      ref_shed =
        push(socket_b, "message:react", %{
          "target_client_message_id" => msg_id,
          "desired_reaction" => "😂",
          "expected_reaction_revision" => 0
        })

      assert_reply ref_shed, :error, %{code: "CONVERSATION_BUSY", retryable: true}
    after
      :sys.resume(server_pid)
      _ = :sys.get_state(server_pid)
    end

    # Under same healthy server, higher-priority ACK and append remain fully operational
    msg2_id = Ecto.UUID.generate()

    ref_send2 =
      push(socket_a, "message:send", %{
        "client_message_id" => msg2_id,
        "content" => "High priority text"
      })

    assert_reply ref_send2, :ok, %{status: "sent", sequence: sequence2}

    ref_ack2 =
      push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence2))

    assert_reply ref_ack2, :ok, %{status: "applied"}
  end

  defp progress_payload(conversation, sequence) do
    {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)

    %{
      "epoch_id" => state.epoch_id,
      "highest_contiguous_sequence" => sequence
    }
  end
end
