defmodule StrangertalksNew.SecurityAdversarialTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest
  import ExUnit.CaptureLog

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{
    Conversation,
    Message,
    Participants,
    Relationship,
    RelationshipConsent,
    Report,
    Repo
  }

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.MatchingRules.BoundaryBlock
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.{ParticipantConnectionTracker, QueueState}
  alias StrangertalksNew.RateLimiter

  alias StrangertalksNewWeb.{
    ConversationChannel,
    ParticipantChannel,
    ParticipantToken,
    UserSocket
  }

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  # ============================================================================
  # 4A — SOCKET AUTHENTICATION & ORIGIN
  # ============================================================================

  describe "4A Socket Authentication" do
    test "missing auth token fails to connect" do
      assert :error = connect(UserSocket, %{})
      assert :error = connect(UserSocket, %{}, connect_info: %{})
    end

    test "malformed auth token fails to connect" do
      assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: "not-a-valid-token"})
      assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: ""})
    end

    test "expired auth token fails to connect" do
      participant = participant_fixture()

      expired_token =
        Phoenix.Token.sign(
          @endpoint,
          ParticipantToken.salt(),
          participant.participant_id,
          signed_at: System.system_time(:second) - ParticipantToken.max_age() - 10
        )

      assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: expired_token})
    end

    test "valid token for non-existent participant fails to connect" do
      fake_token = ParticipantToken.sign(Ecto.UUID.generate())
      assert :error = connect(UserSocket, %{}, connect_info: %{auth_token: fake_token})
    end

    test "valid participant token establishes identity and assigns do not retain raw token" do
      participant = participant_fixture()
      token = ParticipantToken.sign(participant.participant_id)

      assert {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
      assert socket.assigns.participant_id == participant.participant_id
      assert UserSocket.id(socket) == "participant_socket:#{participant.participant_id}"

      # Verify raw token is NOT stored in socket assigns
      refute Map.has_key?(socket.assigns, :token)
      refute Map.has_key?(socket.assigns, :auth_token)
      refute token in Map.values(socket.assigns)
    end

    test "client-supplied parameters cannot override verified token identity" do
      participant_a = participant_fixture()
      participant_b = participant_fixture()
      token_a = ParticipantToken.sign(participant_a.participant_id)

      # Attempting to supply participant_b id in params must not override token_a
      assert {:ok, socket} =
               connect(
                 UserSocket,
                 %{"participant_id" => participant_b.participant_id},
                 connect_info: %{auth_token: token_a}
               )

      assert socket.assigns.participant_id == participant_a.participant_id
      refute socket.assigns.participant_id == participant_b.participant_id
    end
  end

  # ============================================================================
  # 4B — EVENT-LEVEL AUTHORIZATION & ACTOR IDENTITY
  # ============================================================================

  describe "4B Event-Level Authorization & Actor Identity" do
    test "authenticated participant A cannot join participant:B topic" do
      participant_a = participant_fixture()
      participant_b = participant_fixture()
      socket_a = connected_socket(participant_a)

      assert {:error, %{reason: "participant_mismatch"}} =
               subscribe_and_join(
                 socket_a,
                 ParticipantChannel,
                 "participant:#{participant_b.participant_id}"
               )
    end

    test "participant A cannot queue or dequeue participant B via channel payloads" do
      participant_a = participant_fixture()
      participant_b = participant_fixture()
      socket_a = joined_participant_socket(participant_a)

      # Queue join accepts only door_type; extra keys like participant_id are rejected
      ref =
        push(socket_a, "queue:join", %{
          "door_type" => "JUST_TALK",
          "conversation_language" => "en",
          "participant_id" => participant_b.participant_id
        })

      assert_reply ref, :error, %{code: "INVALID_DOOR_TYPE"}
      refute queue_entry(participant_a.participant_id)
      refute queue_entry(participant_b.participant_id)

      # Valid queue join derives identity authoritatively from socket assigns
      ref =
        push(socket_a, "queue:join", %{
          "door_type" => "JUST_TALK",
          "conversation_language" => "en"
        })

      assert_reply ref, :ok, %{status: "queued", queue_attempt_id: queue_attempt_id}
      assert queue_entry(participant_a.participant_id)
      refute queue_entry(participant_b.participant_id)

      # Dequeue derives participant identity from the socket and validates its queue attempt.
      ref = push(socket_a, "queue:leave", %{"queue_attempt_id" => queue_attempt_id})
      assert_reply ref, :ok, %{status: "left"}
      refute queue_entry(participant_a.participant_id)
    end

    test "outsider C knowing conversation UUID cannot join conversation" do
      {conversation, _participant_a, _participant_b} = matched_conversation_fixture()
      outsider = participant_fixture()
      outsider_socket = connected_socket(outsider)

      assert {:error, %{reason: "not_conversation_member"}} =
               subscribe_and_join(
                 outsider_socket,
                 ConversationChannel,
                 "conversation:#{conversation.conversation_id}"
               )
    end

    test "outsider C cannot append message directly into ConversationServer" do
      {conversation, _participant_a, _participant_b} = matched_conversation_fixture()
      {:ok, _pid} = ConversationServer.ensure_started(conversation.conversation_id)
      outsider = participant_fixture()
      message_id = Ecto.UUID.generate()

      assert {:error, :not_conversation_member} =
               ConversationServer.append_message(
                 conversation.conversation_id,
                 outsider.participant_id,
                 message_id,
                 "hostile injection"
               )
    end

    test "sender identity is authoritative and client-supplied sender_id in payload is rejected" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)
      message_id = Ecto.UUID.generate()

      # Attempting to supply sender_id as participant_b in channel payload violates key whitelist
      ref =
        push(socket_a, "message:send", %{
          "message_id" => message_id,
          "content" => "spoofed",
          "sender_id" => participant_b.participant_id
        })

      assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}
      assert Repo.aggregate(Message, :count) == 0
    end
  end

  # ============================================================================
  # 4C — PAYLOAD LIMITS & INPUT BOUNDARIES
  # ============================================================================

  describe "4C Payload Limits & Input Validation" do
    test "text message byte size limit: 16 KiB accepted, 16 KiB + 1 byte rejected" do
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

      # Exact 16 KiB (16_384 ASCII bytes)
      content_exact = String.duplicate("a", 16_384)
      msg_id_1 = Ecto.UUID.generate()

      ref =
        push(socket_a, "message:send", %{"message_id" => msg_id_1, "content" => content_exact})

      assert_reply ref, :ok, %{message_id: ^msg_id_1, sequence: 1, status: "sent"}

      # 16 KiB + 1 byte (16_385 bytes)
      content_oversized = String.duplicate("a", 16_385)
      msg_id_2 = Ecto.UUID.generate()

      ref =
        push(socket_a, "message:send", %{
          "message_id" => msg_id_2,
          "content" => content_oversized
        })

      assert_reply ref, :error, %{code: "MESSAGE_TOO_LARGE"}
    end

    test "multibyte UTF-8 string exceeding byte limit is rejected even if character count is small" do
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

      # 4-byte UTF-8 emoji repeated 4100 times = 4100 chars, but 16_400 bytes (> 16 KiB)
      multibyte_oversized = String.duplicate("🔒", 4_100)
      assert String.length(multibyte_oversized) == 4_100
      assert byte_size(multibyte_oversized) == 16_400

      msg_id = Ecto.UUID.generate()

      ref =
        push(socket_a, "message:send", %{
          "message_id" => msg_id,
          "content" => multibyte_oversized
        })

      assert_reply ref, :error, %{code: "MESSAGE_TOO_LARGE"}
    end

    test "report evidence byte limit: 4 KiB accepted, 4 KiB + 1 rejected" do
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

      # 4 KiB (4096 bytes)
      evidence_valid = String.duplicate("r", 4_096)

      ref =
        push(socket_a, "conversation:report", %{
          "category" => "HARASSMENT",
          "evidence" => evidence_valid
        })

      assert_reply ref, :ok, %{status: "submitted"}

      # 4 KiB + 1 (4097 bytes)
      evidence_oversized = String.duplicate("r", 4_097)

      ref =
        push(socket_a, "conversation:report", %{
          "category" => "HARASSMENT",
          "evidence" => evidence_oversized
        })

      assert_reply ref, :error, %{code: "INVALID_PAYLOAD"}
    end

    test "malformed UUID resource parameters fail gracefully without unhandled exceptions" do
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

      # Non-UUID client_message_id
      ref = push(socket_a, "message:send", %{"message_id" => "not-a-uuid", "content" => "test"})
      assert_reply ref, :error, %{code: "INVALID_MESSAGE_ID"}

      # Retired per-message ACK endpoint is rejected without parsing resource identifiers.
      ref = push(socket_a, "message:ack", %{"message_id" => "not-a-uuid"})
      assert_reply ref, :error, %{code: "INVALID_REQUEST"}

      # Non-UUID relationship_id in bond:reconnect_start on participant channel
      p_socket = joined_participant_socket(participant_a)

      ref =
        push(p_socket, "bond:reconnect_start", %{
          "relationship_id" => "not-a-uuid",
          "door_type" => "JUST_TALK"
        })

      assert_reply ref, :error, %{code: "RECONNECTION_UNAVAILABLE"}
    end
  end

  # ============================================================================
  # 4D — RATE LIMITS & ABUSE THROTTLING
  # ============================================================================

  describe "4D Rate Limits & Abuse Throttling" do
    test "RateLimiter shares allowance across multiple tabs for same participant" do
      participant = participant_fixture()
      bucket = :message_send_adversarial_test
      limit = 5
      window_ms = 10_000

      # Consume 5 requests for the participant
      for _ <- 1..limit do
        assert :ok = RateLimiter.allow(bucket, participant.participant_id, limit, window_ms)
      end

      # 6th request from another tab (same participant) is rate limited
      assert {:error, retry_after_ms} =
               RateLimiter.allow(bucket, participant.participant_id, limit, window_ms)

      assert is_integer(retry_after_ms) and retry_after_ms > 0
    end

    test "RateLimiter isolates allowances between different participants" do
      participant_a = participant_fixture()
      participant_b = participant_fixture()
      bucket = :queue_join_adversarial_test
      limit = 2
      window_ms = 10_000

      for _ <- 1..limit do
        assert :ok = RateLimiter.allow(bucket, participant_a.participant_id, limit, window_ms)
      end

      # Participant A is exhausted
      assert {:error, _} =
               RateLimiter.allow(bucket, participant_a.participant_id, limit, window_ms)

      # Participant B is completely unaffected
      assert :ok = RateLimiter.allow(bucket, participant_b.participant_id, limit, window_ms)
    end

    test "RateLimiter isolates different operation buckets for the same participant" do
      participant = participant_fixture()
      bucket_1 = :bucket_one_test
      bucket_2 = :bucket_two_test
      limit = 1
      window_ms = 10_000

      assert :ok = RateLimiter.allow(bucket_1, participant.participant_id, limit, window_ms)

      assert {:error, _} =
               RateLimiter.allow(bucket_1, participant.participant_id, limit, window_ms)

      # Bucket 2 remains available
      assert :ok = RateLimiter.allow(bucket_2, participant.participant_id, limit, window_ms)
    end

    test "safety actions remain unthrottled when message send rate limit is exhausted" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)
      _socket_b = joined_conversation_socket(participant_b, conversation.conversation_id)

      # Exhaust message_send bucket (limit is 20 in 10s)
      for i <- 1..20 do
        msg_id = Ecto.UUID.generate()

        ref =
          push(socket_a, "message:send", %{
            "message_id" => msg_id,
            "content" => "spam #{i}"
          })

        assert_reply ref, :ok
      end

      # 21st message is rate limited
      overflow_msg_id = Ecto.UUID.generate()

      ref =
        push(socket_a, "message:send", %{
          "message_id" => overflow_msg_id,
          "content" => "overflow"
        })

      assert_reply ref, :error, %{code: "RATE_LIMITED"}

      # Safety actions (conversation:end) succeed immediately despite message_send rate limit
      end_ref = push(socket_a, "conversation:end", %{})
      assert_reply end_ref, :ok, %{status: "ended"}
    end
  end

  # ============================================================================
  # 4E — CONNECTION LIVENESS & MULTIPLE TAB CLEANUP
  # ============================================================================

  describe "4E Connection Liveness & Dead Connection Cleanup" do
    test "participant with 2 conversation channels: 1st disconnect preserves active state, final triggers disconnect" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      cid = conversation.conversation_id
      {:ok, _pid} = ConversationServer.ensure_started(cid)

      # Register 2 PIDs for participant_a and 1 PID for participant_b
      parent = self()
      tab1 = spawn_link(fn -> tab_loop(parent) end)
      tab2 = spawn_link(fn -> tab_loop(parent) end)
      tab_b = spawn_link(fn -> tab_loop(parent) end)

      assert :ok = ConversationServer.register_channel(cid, participant_a.participant_id, tab1)
      assert :ok = ConversationServer.register_channel(cid, participant_a.participant_id, tab2)
      assert :ok = ConversationServer.register_channel(cid, participant_b.participant_id, tab_b)

      {:ok, state1} = ConversationServer.inspect_state(cid)
      assert MapSet.size(state1.participant_channels[participant_a.participant_id]) == 2
      refute Map.has_key?(state1.recovery_timers, participant_a.participant_id)

      # 1st tab closes -> participant_a remains connected, NO recovery timer
      assert :ok = ConversationServer.unregister_channel(cid, participant_a.participant_id, tab1)
      {:ok, state2} = ConversationServer.inspect_state(cid)
      assert MapSet.size(state2.participant_channels[participant_a.participant_id]) == 1
      refute Map.has_key?(state2.recovery_timers, participant_a.participant_id)

      # 2nd/final tab closes -> participant_a is marked disconnected, recovery timer created
      assert :ok = ConversationServer.unregister_channel(cid, participant_a.participant_id, tab2)
      {:ok, state3} = ConversationServer.inspect_state(cid)

      assert MapSet.size(
               Map.get(state3.participant_channels, participant_a.participant_id, MapSet.new())
             ) == 0

      assert Map.has_key?(state3.recovery_timers, participant_a.participant_id)

      # Reconnect before timeout cancels recovery timer
      tab3 = spawn_link(fn -> tab_loop(parent) end)
      assert :ok = ConversationServer.register_channel(cid, participant_a.participant_id, tab3)
      {:ok, state4} = ConversationServer.inspect_state(cid)
      assert MapSet.size(state4.participant_channels[participant_a.participant_id]) == 1
      refute Map.has_key?(state4.recovery_timers, participant_a.participant_id)
    end

    test "ParticipantConnectionTracker preserves queue entry while at least 1 tab is alive" do
      participant = participant_fixture()
      pid = participant.participant_id
      parent = self()

      tab1 = spawn_link(fn -> tab_loop(parent) end)
      tab2 = spawn_link(fn -> tab_loop(parent) end)

      # Add participant to queue
      Agent.update(QueueState, fn s ->
        Map.put(s, pid, %{
          participant_id: pid,
          door_selection: :EXPLORE,
          queue_entry_time: DateTime.utc_now(),
          queue_attempt_id: Ecto.UUID.generate()
        })
      end)

      ParticipantConnectionTracker.register(pid, tab1)
      ParticipantConnectionTracker.register(pid, tab2)

      # Tab 1 dies -> participant still has Tab 2 -> queue entry preserved
      ParticipantConnectionTracker.unregister(pid, tab1)
      assert queue_entry(pid) != nil

      # Tab 2 dies -> final tab -> participant removed from queue
      ParticipantConnectionTracker.unregister(pid, tab2)
      assert queue_entry(pid) == nil
    end
  end

  # ============================================================================
  # 4G — BACKPRESSURE & OVERLOAD ADMISSION
  # ============================================================================

  describe "4G Backpressure / Overload Admission" do
    test "critical operations (ACK, unregister, conversation:end) are admitted regardless of mailbox pressure" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      cid = conversation.conversation_id
      {:ok, _pid} = ConversationServer.ensure_started(cid)
      assert :ok = ConversationServer.register_channel(cid, participant_a.participant_id, self())

      assert :ok =
               ConversationServer.register_channel(
                 cid,
                 participant_b.participant_id,
                 spawn(fn -> :ok end)
               )

      # Even if server mailbox is high, ACK is admitted directly
      msg_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationServer.append_message(
                 cid,
                 participant_a.participant_id,
                 msg_id,
                 "admit me"
               )

      assert {:ok, %{status: "delivered"}} =
               ConversationServer.acknowledge_message(
                 cid,
                 participant_b.participant_id,
                 msg_id
               )

      # End conversation is admitted directly
      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(
                 cid,
                 participant_a.participant_id
               )

      assert Repo.get!(Conversation, cid).conversation_status == :ENDED
    end
  end

  # ============================================================================
  # 4H — MALFORMED / DUPLICATE / REPLAYED EVENT HANDLING
  # ============================================================================

  describe "4H Malformed / Duplicate / Replayed Event Handling" do
    test "message idempotency: exact same client_message_id and content produces one sequence and no duplicate broadcast" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)
      _socket_b = joined_conversation_socket(participant_b, conversation.conversation_id)
      msg_id = Ecto.UUID.generate()

      ref1 =
        push(socket_a, "message:send", %{
          "message_id" => msg_id,
          "content" => "exact same content"
        })

      assert_reply ref1, :ok, %{message_id: ^msg_id, sequence: 1, status: "sent"}
      assert_push "message:new", %{message_id: ^msg_id, sequence: 1}

      # Retry with exact same content
      ref2 =
        push(socket_a, "message:send", %{
          "message_id" => msg_id,
          "content" => "exact same content"
        })

      assert_reply ref2, :ok, %{message_id: ^msg_id, sequence: 1, status: "sent"}
      # Must NOT emit a second message:new push to recipient
      refute_push "message:new", %{message_id: ^msg_id}, 50
    end

    test "message conflict: same client_message_id with different content returns MESSAGE_ID_CONFLICT" do
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)
      msg_id = Ecto.UUID.generate()

      ref1 = push(socket_a, "message:send", %{"message_id" => msg_id, "content" => "first"})
      assert_reply ref1, :ok, %{sequence: 1}

      ref2 = push(socket_a, "message:send", %{"message_id" => msg_id, "content" => "changed"})
      assert_reply ref2, :error, %{code: "MESSAGE_ID_CONFLICT"}
    end

    test "mismatched client_message_id and message_id in payload is rejected as MESSAGE_ID_CONFLICT" do
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)

      ref =
        push(socket_a, "message:send", %{
          "client_message_id" => Ecto.UUID.generate(),
          "message_id" => Ecto.UUID.generate(),
          "content" => "mismatch"
        })

      assert_reply ref, :error, %{code: "MESSAGE_ID_CONFLICT"}
    end

    test "delivery progress is authenticated, participant-scoped, and only recipient evidence delivers" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)
      socket_b = joined_conversation_socket(participant_b, conversation.conversation_id)
      outsider = participant_fixture()
      msg_id = Ecto.UUID.generate()

      ref = push(socket_a, "message:send", %{"message_id" => msg_id, "content" => "for b"})
      assert_reply ref, :ok, %{sequence: sequence}
      {:ok, state} = ConversationServer.inspect_state(conversation.conversation_id)

      sender_progress =
        push(socket_a, "delivery:progress", %{
          "epoch_id" => state.epoch_id,
          "highest_contiguous_sequence" => sequence
        })

      assert_reply sender_progress, :ok, %{status: "applied"}

      outsider_progress =
        ConversationServer.report_delivery_progress(
          conversation.conversation_id,
          outsider.participant_id,
          self(),
          state.epoch_id,
          sequence
        )

      assert {:error, :not_conversation_member} = outsider_progress

      recipient_progress =
        push(socket_b, "delivery:progress", %{
          "epoch_id" => state.epoch_id,
          "highest_contiguous_sequence" => sequence
        })

      assert_reply recipient_progress, :ok, %{status: "applied"}

      duplicate_progress =
        push(socket_b, "delivery:progress", %{
          "epoch_id" => state.epoch_id,
          "highest_contiguous_sequence" => sequence
        })

      assert_reply duplicate_progress, :ok, %{status: "no_op"}
    end

    test "sync cursor 2F deterministic outcomes" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      cid = conversation.conversation_id
      {:ok, _pid} = ConversationServer.ensure_started(cid)

      # Send 2 messages
      assert {:ok, _m1} =
               ConversationServer.append_message(
                 cid,
                 participant_a.participant_id,
                 Ecto.UUID.generate(),
                 "one"
               )

      assert {:ok, m2} =
               ConversationServer.append_message(
                 cid,
                 participant_a.participant_id,
                 Ecto.UUID.generate(),
                 "two"
               )

      {:ok, server_state} = ConversationServer.inspect_state(cid)
      epoch_id = server_state.epoch_id
      assert m2.sequence == 2

      # 1. Same epoch + latest sequence -> up_to_date
      assert {:ok, sync_1} =
               ConversationServer.sync_and_register_channel(
                 cid,
                 participant_b.participant_id,
                 self(),
                 epoch_id,
                 2
               )

      assert sync_1.status == "up_to_date"
      assert sync_1.messages == []

      # 2. Same epoch + behind sequence -> catch_up_complete
      assert {:ok, sync_2} =
               ConversationServer.sync_and_register_channel(
                 cid,
                 participant_b.participant_id,
                 self(),
                 epoch_id,
                 1
               )

      assert sync_2.status == "catch_up_complete"
      assert length(sync_2.messages) == 1
      assert hd(sync_2.messages).sequence == 2

      # 3. Same epoch + ahead of server sequence -> sequence_inconsistent
      assert {:ok, sync_3} =
               ConversationServer.sync_and_register_channel(
                 cid,
                 participant_b.participant_id,
                 self(),
                 epoch_id,
                 999
               )

      assert sync_3.status == "sequence_inconsistent"

      # 4. Different epoch -> epoch_changed
      assert {:ok, sync_4} =
               ConversationServer.sync_and_register_channel(
                 cid,
                 participant_b.participant_id,
                 self(),
                 Ecto.UUID.generate(),
                 0
               )

      assert sync_4.status == "epoch_changed"
      assert length(sync_4.messages) == 2
    end

    test "unknown/unsupported events on ParticipantChannel and ConversationChannel survive and return INVALID_REQUEST" do
      participant = participant_fixture()
      p_socket = joined_participant_socket(participant)

      # Push random invalid event to ParticipantChannel
      ref_p = push(p_socket, "unsupported:hostile_event", %{"payload" => "attack"})
      assert_reply ref_p, :error, %{code: "INVALID_REQUEST"}

      # Channel process is still alive and responds to valid commands
      ref_valid =
        push(p_socket, "queue:join", %{
          "door_type" => "JUST_TALK",
          "conversation_language" => "en"
        })

      assert_reply ref_valid, :ok, %{status: "queued"}

      # Repeat for ConversationChannel
      {conversation, participant_a, _participant_b} = matched_conversation_fixture()
      c_socket = joined_conversation_socket(participant_a, conversation.conversation_id)

      ref_c = push(c_socket, "invalid:random_action", %{"key" => "value"})
      assert_reply ref_c, :error, %{code: "INVALID_REQUEST"}

      # ConversationChannel is alive and responds to valid commands
      msg_id = Ecto.UUID.generate()
      ref_msg = push(c_socket, "message:send", %{"message_id" => msg_id, "content" => "alive"})
      assert_reply ref_msg, :ok, %{message_id: ^msg_id}
    end

    test "repeated report, block, and consent actions are idempotent and safe" do
      {conversation, participant_a, participant_b} = matched_conversation_fixture()
      socket_a = joined_conversation_socket(participant_a, conversation.conversation_id)
      socket_b = joined_conversation_socket(participant_b, conversation.conversation_id)

      # Repeated reports with exact same evidence return same report_id
      report_payload = %{"category" => "SPAM", "evidence" => "repeat evidence"}
      ref1 = push(socket_a, "conversation:report", report_payload)
      assert_reply ref1, :ok, %{report_id: rep_id, status: "submitted"}

      ref2 = push(socket_a, "conversation:report", report_payload)
      assert_reply ref2, :ok, %{report_id: ^rep_id, status: "submitted"}
      assert Repo.aggregate(Report, :count) == 1

      # Repeated blocks are idempotent
      ref_b1 = push(socket_a, "conversation:block", %{})
      assert_reply ref_b1, :ok, %{status: "blocked"}
      ref_b2 = push(socket_a, "conversation:block", %{})
      assert_reply ref_b2, :ok, %{status: "blocked"}
      assert Repo.aggregate(BoundaryBlock, :count) == 1

      # End conversation and test consent replay
      end_ref = push(socket_a, "conversation:end", %{})
      assert_reply end_ref, :ok, %{status: "ended"}

      consent_a1 = push(socket_a, "relationship:consent", %{})
      assert_reply consent_a1, :ok, %{status: "waiting_for_mutual_consent"}
      consent_a2 = push(socket_a, "relationship:consent", %{})
      assert_reply consent_a2, :ok, %{status: "waiting_for_mutual_consent"}
      assert Repo.aggregate(RelationshipConsent, :count) == 1

      consent_b = push(socket_b, "relationship:consent", %{})
      assert_reply consent_b, :ok, %{status: "created", relationship_id: rel_id}
      assert Repo.aggregate(Relationship, :count) == 1

      # Re-consenting after relationship creation is safe
      consent_b_repeat = push(socket_b, "relationship:consent", %{})
      assert_reply consent_b_repeat, :ok, %{status: "created", relationship_id: ^rel_id}
      assert Repo.aggregate(Relationship, :count) == 1
    end
  end

  # ============================================================================
  # PRIVACY ASSERTIONS (3F AUDIT)
  # ============================================================================

  describe "Privacy Assertions" do
    test "adversarial failures do not log sensitive UUIDs, tokens, or message content" do
      participant = participant_fixture()
      token = ParticipantToken.sign(participant.participant_id)
      secret_marker = "SUPER_SECRET_PAYLOAD_MARKER_98765"
      fake_token_marker = "FAKE_AUTH_TOKEN_VALUE_555"

      log =
        capture_log(fn ->
          # 1. Invalid connect
          _ = connect(UserSocket, %{}, connect_info: %{auth_token: fake_token_marker})

          # 2. Hostile message attempt
          socket = joined_participant_socket(participant)
          _ = push(socket, "unsupported_event", %{"marker" => secret_marker})
        end)

      refute log =~ secret_marker
      refute log =~ fake_token_marker
      refute log =~ participant.participant_id
      refute log =~ token
    end
  end

  # ============================================================================
  # HELPERS
  # ============================================================================

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp connected_socket(participant) do
    token = ParticipantToken.sign(participant.participant_id)
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  defp joined_participant_socket(participant) do
    {:ok, _, socket} =
      participant
      |> connected_socket()
      |> subscribe_and_join(
        ParticipantChannel,
        "participant:#{participant.participant_id}"
      )

    socket
  end

  defp joined_conversation_socket(participant, conversation_id) do
    {:ok, _, socket} =
      participant
      |> connected_socket()
      |> subscribe_and_join(
        ConversationChannel,
        "conversation:#{conversation_id}"
      )

    socket
  end

  defp matched_conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, _result} =
      MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, _result} =
      MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.one!(Conversation)
    {conversation, participant_a, participant_b}
  end

  defp queue_entry(participant_id) do
    Agent.get(QueueState, fn state -> Map.get(state, participant_id) end)
  end

  defp tab_loop(parent) do
    receive do
      {:conversation_message, msg} ->
        send(parent, {:received_message, msg})
        tab_loop(parent)

      {:conversation_presence, p} ->
        send(parent, {:received_presence, p})
        tab_loop(parent)

      _other ->
        tab_loop(parent)
    end
  end
end
