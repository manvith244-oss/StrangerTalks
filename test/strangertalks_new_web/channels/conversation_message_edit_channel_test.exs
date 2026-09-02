defmodule StrangertalksNewWeb.ConversationMessageEditChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  setup do
    fixture = conversation_fixture()

    start_supervised!(
      {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
    )

    fixture
  end

  test "channel message:edit fans current canonical revision to origin, sibling sender tab, and peer",
       context do
    socket_a1 = connect_and_join(context.participant_a, context.conversation)
    _socket_a2 = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a1, "message:send", %{"client_message_id" => message_id, "content" => "before"})

    assert_reply send_ref, :ok, %{status: "sent", sequence: sequence}
    assert_push "message:new", %{client_message_id: ^message_id, content_revision: 0}

    ack_ref =
      push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))

    assert_reply ack_ref, :ok, %{status: "applied"}

    edit_ref =
      push(socket_a1, "message:edit", %{
        "target_client_message_id" => message_id,
        "expected_content_revision" => 0,
        "content" => "after"
      })

    assert_reply edit_ref, :ok, %{
      status: "applied",
      client_message_id: ^message_id,
      content: "after",
      content_revision: 1,
      sequence: ^sequence,
      edited: true,
      delivery_status: "delivered",
      latest_content_status: "sent"
    }

    for _session <- 1..3 do
      assert_push "message:edited", %{
        client_message_id: ^message_id,
        content: "after",
        content_revision: 1,
        sequence: ^sequence
      }
    end
  end

  test "channel content:applied authenticates recipient and lost acknowledgment retry is NO_OP",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{"client_message_id" => message_id, "content" => "v0"})

    assert_reply send_ref, :ok, %{sequence: sequence}
    assert_push "message:new", %{client_message_id: ^message_id}

    edit_ref =
      push(socket_a, "message:edit", %{
        "target_client_message_id" => message_id,
        "expected_content_revision" => 0,
        "content" => "v1"
      })

    assert_reply edit_ref, :ok, %{status: "applied", content_revision: 1}

    {:ok, state} = ConversationServer.inspect_state(context.conversation.conversation_id)

    applied_ref =
      push(socket_b, "content:applied", %{
        "epoch_id" => state.epoch_id,
        "target_client_message_id" => message_id,
        "content_revision" => 1
      })

    assert_reply applied_ref, :ok, %{
      status: "applied",
      peer_applied_content_revision: 1,
      latest_content_status: "delivered"
    }

    assert_push "message:content_status", %{
      client_message_id: ^message_id,
      peer_applied_content_revision: 1,
      latest_content_status: "delivered"
    }

    retry_ref =
      push(socket_b, "content:applied", %{
        "epoch_id" => state.epoch_id,
        "target_client_message_id" => message_id,
        "content_revision" => 1
      })

    assert_reply retry_ref, :ok, %{status: "no_op", peer_applied_content_revision: 1}

    lower_ref =
      push(socket_b, "content:applied", %{
        "epoch_id" => state.epoch_id,
        "target_client_message_id" => message_id,
        "content_revision" => 0
      })

    assert_reply lower_ref, :ok, %{status: "no_op", peer_applied_content_revision: 1}

    future_ref =
      push(socket_b, "content:applied", %{
        "epoch_id" => state.epoch_id,
        "target_client_message_id" => message_id,
        "content_revision" => 2
      })

    assert_reply future_ref, :error, %{code: "INVALID_PAYLOAD"}

    ack_ref =
      push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))

    assert_reply ack_ref, :ok, %{status: "applied"}
  end

  test "channel rejects forged edit structure, peer edit, and unsupported target type", context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{"client_message_id" => message_id, "content" => "text"})

    assert_reply send_ref, :ok, %{}
    assert_push "message:new", %{client_message_id: ^message_id}

    forged_ref =
      push(socket_a, "message:edit", %{
        "target_client_message_id" => message_id,
        "expected_content_revision" => 0,
        "content" => "forged",
        "sender_id" => context.participant_a.participant_id,
        "sequence" => 99
      })

    assert_reply forged_ref, :error, %{code: "INVALID_PAYLOAD"}

    peer_ref =
      push(socket_b, "message:edit", %{
        "target_client_message_id" => message_id,
        "expected_content_revision" => 0,
        "content" => "peer overwrite"
      })

    assert_reply peer_ref, :error, %{code: "INVALID_REQUEST"}

    expressive_id = Ecto.UUID.generate()

    expressive_ref =
      push(socket_a, "message:send", %{
        "client_message_id" => expressive_id,
        "expressive_id" => "warm-wave"
      })

    assert_reply expressive_ref, :ok, %{}
    assert_push "message:new", %{client_message_id: ^expressive_id, type: "expressive"}

    type_ref =
      push(socket_a, "message:edit", %{
        "target_client_message_id" => expressive_id,
        "expected_content_revision" => 0,
        "content" => "type change"
      })

    assert_reply type_ref, :error, %{code: "INVALID_REQUEST"}
  end

  test "edit limiter charges APPLY, NO_OP, STALE, INVALID, and ABSENT attempts across tabs",
       context do
    socket_a1 = connect_and_join(context.participant_a, context.conversation)
    socket_a2 = connect_and_join(context.participant_a, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a1, "message:send", %{"client_message_id" => message_id, "content" => "v0"})

    assert_reply send_ref, :ok, %{}

    apply_ref = edit(socket_a1, message_id, 0, "v1")
    assert_reply apply_ref, :ok, %{status: "applied"}

    for _ <- 1..4 do
      ref = edit(socket_a1, message_id, 1, "v1")
      assert_reply ref, :ok, %{status: "no_op"}
    end

    for suffix <- 1..5 do
      ref = edit(socket_a1, message_id, 0, "stale-#{suffix}")
      assert_reply ref, :ok, %{status: "stale"}
    end

    for _ <- 1..5 do
      absent_ref = edit(socket_a2, Ecto.UUID.generate(), 0, "absent")
      assert_reply absent_ref, :ok, %{status: "absent_from_authority"}
    end

    for _ <- 1..5 do
      invalid_ref = edit(socket_a2, message_id, 1, "   ")
      assert_reply invalid_ref, :error, %{code: "INVALID_REQUEST"}
    end

    limited_ref = edit(socket_a2, message_id, 1, "v1")
    assert_reply limited_ref, :error, %{code: "RATE_LIMITED", retryable: true}
  end

  test "JOIN and separate sync:reconcile project current revision without allocating sequence",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{"client_message_id" => message_id, "content" => "before"})

    assert_reply send_ref, :ok, %{sequence: 1}

    edit_ref = edit(socket_a, message_id, 0, "after")
    assert_reply edit_ref, :ok, %{status: "applied", content_revision: 1}

    socket_b = connect_and_join(context.participant_b, context.conversation)

    reconcile_ref = push(socket_b, "sync:reconcile", %{"last_applied_sequence" => 1})

    assert_reply reconcile_ref, :ok, %{
      through_sequence: 1,
      current_message_revisions: [
        %{
          client_message_id: ^message_id,
          sequence: 1,
          content: "after",
          content_revision: 1,
          edited: true
        }
      ]
    }
  end

  defp edit(socket, message_id, expected_revision, content) do
    push(socket, "message:edit", %{
      "target_client_message_id" => message_id,
      "expected_content_revision" => expected_revision,
      "content" => content
    })
  end

  defp connect_and_join(participant, conversation) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    {:ok, _reply, socket} =
      subscribe_and_join(
        socket,
        ConversationChannel,
        "conversation:#{conversation.conversation_id}",
        %{}
      )

    socket
  end

  defp progress_payload(conversation, sequence) do
    {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)
    %{"epoch_id" => state.epoch_id, "highest_contiguous_sequence" => sequence}
  end

  defp conversation_fixture do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
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

    %{conversation: conversation, participant_a: participant_a, participant_b: participant_b}
  end
end
