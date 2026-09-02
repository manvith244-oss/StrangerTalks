defmodule StrangertalksNewWeb.ConversationReplyChannelTest do
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

    on_exit(fn ->
      case ConversationServer.lookup(conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    %{
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b
    }
  end

  test "message:reply_target returns FOUND for delivered target and CONFIRMED_UNAVAILABLE for absent target",
       context do
    socket_a = join_channel(context.participant_a, context.conversation.conversation_id)
    socket_b = join_channel(context.participant_b, context.conversation.conversation_id)

    msg_id = Ecto.UUID.generate()

    ref =
      push(socket_a, "message:send", %{"client_message_id" => msg_id, "content" => "Hello from A"})

    assert_reply ref, :ok, %{status: "sent", sequence: sequence}

    ref = push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))
    assert_reply ref, :ok, %{status: "applied"}

    # Participant B requests reply target check -> FOUND
    ref = push(socket_b, "message:reply_target", %{"reply_to_client_message_id" => msg_id})

    assert_reply ref, :ok, %{
      status: "found",
      reply_to_client_message_id: ^msg_id,
      reply_author_relation: "other_participant",
      reply_snippet: "Hello from A"
    }

    # Check non-existent target -> CONFIRMED_UNAVAILABLE
    missing_id = Ecto.UUID.generate()
    ref = push(socket_b, "message:reply_target", %{"reply_to_client_message_id" => missing_id})

    assert_reply ref, :ok, %{
      status: "confirmed_unavailable",
      reply_to_client_message_id: ^missing_id
    }
  end

  test "message:reply_target rejects extra/unauthorized payload keys and malformed UUIDs",
       context do
    socket = join_channel(context.participant_a, context.conversation.conversation_id)

    # Extra key
    ref =
      push(socket, "message:reply_target", %{
        "reply_to_client_message_id" => Ecto.UUID.generate(),
        "extra" => "bad"
      })

    assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}

    # Malformed UUID
    ref = push(socket, "message:reply_target", %{"reply_to_client_message_id" => "not-a-uuid"})
    assert_reply ref, :error, %{code: "INVALID_MESSAGE_ID"}
  end

  test "message:send rejects client-supplied quote content (reply_snippet, reply_author_relation)",
       context do
    socket = join_channel(context.participant_a, context.conversation.conversation_id)

    # Malicious client attempting to supply arbitrary quote content
    ref =
      push(socket, "message:send", %{
        "client_message_id" => Ecto.UUID.generate(),
        "content" => "fake reply",
        "reply_to_client_message_id" => Ecto.UUID.generate(),
        "reply_snippet" => "I admitted something I never said"
      })

    assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}

    ref =
      push(socket, "message:send", %{
        "client_message_id" => Ecto.UUID.generate(),
        "content" => "fake reply",
        "reply_to_client_message_id" => Ecto.UUID.generate(),
        "reply_author_relation" => "other_participant"
      })

    assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}
  end

  test "message:send with reply_to_client_message_id delivers to peer with server-derived quote",
       context do
    socket_a = join_channel(context.participant_a, context.conversation.conversation_id)
    socket_b = join_channel(context.participant_b, context.conversation.conversation_id)

    orig_id = Ecto.UUID.generate()

    ref =
      push(socket_a, "message:send", %{
        "client_message_id" => orig_id,
        "content" => "Original message"
      })

    assert_reply ref, :ok, %{status: "sent", sequence: sequence}

    ref = push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))
    assert_reply ref, :ok, %{status: "applied"}

    reply_id = Ecto.UUID.generate()

    ref =
      push(socket_b, "message:send", %{
        "client_message_id" => reply_id,
        "content" => "Reply text",
        "reply_to_client_message_id" => orig_id
      })

    assert_reply ref, :ok, %{
      status: "sent",
      reply_to_client_message_id: ^orig_id,
      reply_author_relation: "other_participant",
      reply_snippet: "Original message"
    }

    assert_push "message:new", %{
      message_id: ^reply_id,
      content: "Reply text",
      reply_to_client_message_id: ^orig_id,
      reply_author_relation: "other_participant",
      reply_snippet: "Original message"
    }
  end

  test "message:reply_target with :sent and :failed targets returns non-retryable INVALID_REQUEST and emits zero check_failed/evicted/found",
       context do
    socket_a = join_channel(context.participant_a, context.conversation.conversation_id)
    socket_b = join_channel(context.participant_b, context.conversation.conversation_id)

    parent = self()
    handler_id = "channel-reply-target-exclusion-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:strangertalks_new, :reply_target, :found],
          [:strangertalks_new, :reply_target, :evicted],
          [:strangertalks_new, :reply_target, :check_failed]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    msg_pending = Ecto.UUID.generate()
    msg_failed = Ecto.UUID.generate()

    # Send msg_pending -> delivery_status: :sent
    ref =
      push(socket_a, "message:send", %{
        "client_message_id" => msg_pending,
        "content" => "pending target"
      })

    assert_reply ref, :ok, %{status: "sent"}

    # Send msg_failed and expire it -> delivery_status: :failed
    ref =
      push(socket_a, "message:send", %{
        "client_message_id" => msg_failed,
        "content" => "failed target"
      })

    assert_reply ref, :ok, %{status: "sent"}

    {:ok, pid} = ConversationServer.lookup(context.conversation.conversation_id)
    send(pid, {:expire_message, msg_failed})
    _ = :sys.get_state(pid)

    # 1. Channel request for :sent target
    ref =
      push(socket_b, "message:reply_target", %{
        "reply_to_client_message_id" => msg_pending
      })

    assert_reply ref, :error, %{
      code: "INVALID_REQUEST",
      category: "validation",
      retryable: false
    }

    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :check_failed], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :evicted], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :found], _, _}

    # 2. Channel request for :failed target
    ref =
      push(socket_b, "message:reply_target", %{
        "reply_to_client_message_id" => msg_failed
      })

    assert_reply ref, :error, %{
      code: "INVALID_REQUEST",
      category: "validation",
      retryable: false
    }

    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :check_failed], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :evicted], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :found], _, _}
  end

  test "message:reply_target operational failure (rate limit) returns retryable RATE_LIMITED and emits reply_target_check_failed",
       context do
    socket = join_channel(context.participant_a, context.conversation.conversation_id)

    parent = self()
    handler_id = "channel-reply-target-rate-limit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:strangertalks_new, :reply_target, :check_failed]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Exhaust rate limit (30 requests allowed per 10s window)
    target_id = Ecto.UUID.generate()

    for _ <- 1..30 do
      ref =
        push(socket, "message:reply_target", %{
          "reply_to_client_message_id" => target_id
        })

      assert_reply ref, :ok, %{status: "confirmed_unavailable"}
    end

    # Flush mailbox
    receive do
      {:telemetry_event, _, _, _} -> :ok
    after
      0 -> :ok
    end

    # 31st request is rate limited
    ref =
      push(socket, "message:reply_target", %{
        "reply_to_client_message_id" => target_id
      })

    assert_reply ref, :error, %{
      code: "RATE_LIMITED",
      category: "rate_limit",
      retryable: true
    }

    assert_received {:telemetry_event, [:strangertalks_new, :reply_target, :check_failed], _,
                     meta}

    assert meta.reason_code == "RATE_LIMITED"
  end

  defp join_channel(participant, conversation_id) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation_id}", %{})

    socket
  end

  defp progress_payload(conversation, sequence) do
    {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)

    %{
      "epoch_id" => state.epoch_id,
      "highest_contiguous_sequence" => sequence
    }
  end
end
