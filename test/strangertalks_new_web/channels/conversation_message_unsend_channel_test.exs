defmodule StrangertalksNewWeb.ConversationMessageUnsendChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.{Report, Repo}
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  setup do
    fixture = conversation_fixture()

    start_supervised!(
      {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
    )

    fixture
  end

  test "channel message:unsend fans one content-blind terminal payload to origin, sibling, and peer",
       context do
    socket_a1 = connect_and_join(context.participant_a, context.conversation)
    _socket_a2 = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a1, "message:send", %{
        "client_message_id" => message_id,
        "content" => "remove me"
      })

    assert_reply send_ref, :ok, %{sequence: sequence}
    assert_push "message:new", %{client_message_id: ^message_id}

    ack_ref =
      push(socket_b, "delivery:progress", progress_payload(context.conversation, sequence))

    assert_reply ack_ref, :ok, %{status: "applied"}

    unsend_ref = unsend(socket_a1, message_id, 0)

    assert_reply unsend_ref, :ok, %{
      status: "applied",
      availability: "unsent",
      unsent: true,
      client_message_id: ^message_id,
      sequence: ^sequence,
      delivery_status: "delivered"
    }

    for _session <- 1..3 do
      assert_push "message:unsent", payload
      assert payload.client_message_id == message_id
      assert payload.sequence == sequence
      refute Map.has_key?(payload, :content)
      refute Map.has_key?(payload, :safety_snapshot)
    end
  end

  test "JOIN and separate sync:reconcile expose retained tombstone without private snapshot",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{"client_message_id" => message_id, "content" => "private"})

    assert_reply send_ref, :ok, %{sequence: 1}
    assert_reply unsend(socket_a, message_id, 0), :ok, %{status: "applied"}

    {_socket_b, join_reply} =
      connect_and_join_with_reply(context.participant_b, context.conversation)

    [join_target] =
      Enum.filter(join_reply.current_message_revisions, &(&1.client_message_id == message_id))

    assert join_target.availability == "unsent"
    assert join_target.unsent
    refute Map.has_key?(join_target, :content)
    refute Map.has_key?(join_target, :safety_snapshot)

    socket_b = connect_and_join(context.participant_b, context.conversation)
    reconcile_ref = push(socket_b, "sync:reconcile", %{"last_applied_sequence" => 1})
    assert_reply reconcile_ref, :ok, %{current_message_revisions: revisions}
    reconcile_target = Enum.find(revisions, &(&1.client_message_id == message_id))
    assert reconcile_target.availability == "unsent"
    refute Map.has_key?(reconcile_target, :content)
    refute Map.has_key?(reconcile_target, :safety_snapshot)
  end

  test "channel rejects peer, expressive, malformed, and forged revision without mutation",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = Ecto.UUID.generate()

    send_ref =
      push(socket_a, "message:send", %{"client_message_id" => message_id, "content" => "text"})

    assert_reply send_ref, :ok, %{}
    assert_push "message:new", %{client_message_id: ^message_id}

    assert_reply unsend(socket_b, message_id, 0), :error, %{code: "INVALID_REQUEST"}

    expressive_id = Ecto.UUID.generate()

    expressive_ref =
      push(socket_a, "message:send", %{
        "client_message_id" => expressive_id,
        "expressive_id" => "warm-wave"
      })

    assert_reply expressive_ref, :ok, %{}
    assert_push "message:new", %{client_message_id: ^expressive_id, type: "expressive"}
    assert_reply unsend(socket_a, expressive_id, 0), :error, %{code: "INVALID_REQUEST"}
    assert_reply unsend(socket_a, message_id, -1), :error, %{code: "INVALID_PAYLOAD"}

    forged_ref =
      push(socket_a, "message:unsend", %{
        "target_client_message_id" => message_id,
        "expected_content_revision" => 0,
        "sender_id" => context.participant_a.participant_id
      })

    assert_reply forged_ref, :error, %{code: "INVALID_PAYLOAD"}
    {:ok, state} = ConversationServer.inspect_state(context.conversation.conversation_id)

    assert Enum.find(state.recent_messages, &(&1.client_message_id == message_id)).content ==
             "text"
  end

  test "shared Unsend limiter charges APPLY, duplicate, STALE, ABSENT, foreign, media, and malformed attempts",
       context do
    socket_a1 = connect_and_join(context.participant_a, context.conversation)
    socket_a2 = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    apply_id = send_text(socket_a1, "apply")
    stale_id = send_text(socket_a1, "stale")
    peer_id = send_text(socket_b, "peer")
    expressive_id = Ecto.UUID.generate()

    expressive_ref =
      push(socket_a1, "message:send", %{
        "client_message_id" => expressive_id,
        "expressive_id" => "warm-wave"
      })

    assert_reply expressive_ref, :ok, %{}

    edit_ref =
      push(socket_a1, "message:edit", %{
        "target_client_message_id" => stale_id,
        "expected_content_revision" => 0,
        "content" => "newer"
      })

    assert_reply edit_ref, :ok, %{status: "applied"}
    assert_reply unsend(socket_a1, apply_id, 0), :ok, %{status: "applied"}

    for _ <- 1..3,
        do: assert_reply(unsend(socket_a2, apply_id, 0), :ok, %{status: "already_canonical"})

    for _ <- 1..3, do: assert_reply(unsend(socket_a1, stale_id, 0), :ok, %{status: "stale"})

    for _ <- 1..3,
        do:
          assert_reply(unsend(socket_a2, Ecto.UUID.generate(), 0), :ok, %{
            status: "absent_from_authority"
          })

    for _ <- 1..3,
        do: assert_reply(unsend(socket_a1, peer_id, 0), :error, %{code: "INVALID_REQUEST"})

    for _ <- 1..3,
        do: assert_reply(unsend(socket_a2, expressive_id, 0), :error, %{code: "INVALID_REQUEST"})

    for _ <- 1..4 do
      malformed_ref = push(socket_a1, "message:unsend", %{"target_client_message_id" => apply_id})
      assert_reply malformed_ref, :error, %{code: "INVALID_PAYLOAD"}
    end

    assert_reply unsend(socket_a2, apply_id, 0), :error, %{code: "RATE_LIMITED", retryable: true}
  end

  test "targeted report captures server authority, ignores browser historical text, and ordinary Unsend writes no report",
       context do
    socket_a = connect_and_join(context.participant_a, context.conversation)
    socket_b = connect_and_join(context.participant_b, context.conversation)
    message_id = send_text(socket_a, "authoritative report text")
    count_before = Repo.aggregate(Report, :count)
    assert_reply unsend(socket_a, message_id, 0), :ok, %{status: "applied"}
    assert Repo.aggregate(Report, :count) == count_before

    report_ref =
      push(socket_b, "conversation:report", %{
        "category" => "HARASSMENT",
        "evidence" => "forged cached history",
        "target_client_message_id" => message_id
      })

    assert_reply report_ref, :ok, %{report_id: report_id, status: "submitted"}
    report = Repo.get!(Report, report_id)
    assert report.reporter_context == "authoritative report text"
    refute report.reporter_context =~ "forged"
  end

  defp send_text(socket, content) do
    message_id = Ecto.UUID.generate()
    ref = push(socket, "message:send", %{"client_message_id" => message_id, "content" => content})
    assert_reply ref, :ok, %{}
    message_id
  end

  defp unsend(socket, message_id, expected_revision) do
    push(socket, "message:unsend", %{
      "target_client_message_id" => message_id,
      "expected_content_revision" => expected_revision
    })
  end

  defp connect_and_join(participant, conversation) do
    {socket, _reply} = connect_and_join_with_reply(participant, conversation)
    socket
  end

  defp connect_and_join_with_reply(participant, conversation) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})

    {:ok, reply, socket} =
      subscribe_and_join(
        socket,
        ConversationChannel,
        "conversation:#{conversation.conversation_id}",
        %{}
      )

    {socket, reply}
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
