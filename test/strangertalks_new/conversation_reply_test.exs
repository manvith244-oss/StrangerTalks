defmodule StrangertalksNew.ConversationReplyTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  setup do
    fixture = conversation_fixture()

    on_exit(fn ->
      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    fixture
  end

  test "derive_snippet trims whitespace, collapses newlines, and truncates within 160 graphemes and 512 bytes" do
    # Simple whitespace collapse
    assert ConversationServer.derive_snippet("   hello \n\n  world\t\tfoo   ") ==
             "hello world foo"

    # Multi-byte UTF-8 graphemes
    emoji_str = String.duplicate("✨", 200)
    snippet = ConversationServer.derive_snippet(emoji_str)
    assert String.ends_with?(snippet, "…")
    grapheme_count = String.length(String.replace(snippet, "…", ""))
    assert grapheme_count <= 160
    assert byte_size(snippet) <= 512
    assert String.valid?(snippet)

    # Long English text
    long_text = String.duplicate("The quick brown fox jumps over the lazy dog. ", 10)
    long_snippet = ConversationServer.derive_snippet(long_text)
    assert String.ends_with?(long_snippet, "…")
    assert byte_size(long_snippet) <= 512
  end

  test "lookup_reply_target: returns FOUND for delivered target and sets correct author relation",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "Original peer text"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # Peer looks up target (sender was participant_a, requester is participant_b -> "other_participant")
    assert {:ok,
            %{
              status: "found",
              reply_to_client_message_id: ^msg_id,
              reply_author_relation: "other_participant",
              reply_snippet: "Original peer text"
            }} = ConversationServer.lookup_reply_target(conv_id, context.participant_b, msg_id)

    # Author looks up own target (sender was participant_a, requester is participant_a -> "same_author")
    assert {:ok,
            %{
              status: "found",
              reply_to_client_message_id: ^msg_id,
              reply_author_relation: "same_author",
              reply_snippet: "Original peer text"
            }} = ConversationServer.lookup_reply_target(conv_id, context.participant_a, msg_id)
  end

  test "lookup_reply_target: returns CONFIRMED_UNAVAILABLE when target is evicted or absent",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    missing_id = Ecto.UUID.generate()

    assert {:ok,
            %{
              status: "confirmed_unavailable",
              reply_to_client_message_id: ^missing_id
            }} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_a, missing_id)
  end

  test "delivery state filtering: pending and failed targets MUST NOT return FOUND or increment evicted",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_pending = Ecto.UUID.generate()
    msg_failed = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_pending,
               "pending msg"
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_failed,
               "failed msg"
             )

    # Expire msg_failed -> delivery_status: :failed
    send(pid, {:expire_message, msg_failed})
    _ = :sys.get_state(pid)

    # Pending target (:sent) in recent_messages -> rejected as invalid_request
    assert {:error, :invalid_request} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_b, msg_pending)

    # Failed target (:failed) in recent_messages -> rejected as invalid_request
    assert {:error, :invalid_request} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_b, msg_failed)
  end

  test "telemetry emission and exclusion: :sent and :failed targets emit zero reply_target_evicted and zero reply_target_found",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    parent = self()
    handler_id = "reply-telemetry-test-#{System.unique_integer([:positive])}"

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
    msg_delivered = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_pending,
               "pending message"
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_failed,
               "failed message"
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_delivered,
               "delivered message"
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(
               conv_id,
               context.participant_b,
               msg_delivered
             )

    send(pid, {:expire_message, msg_failed})
    _ = :sys.get_state(pid)

    # 1. Lookup delivery_status: :sent -> rejected with :invalid_request
    assert {:error, :invalid_request} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_b, msg_pending)

    # Must NOT emit any reply_target telemetry
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :evicted], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :found], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :check_failed], _, _}

    # 2. Lookup delivery_status: :failed -> rejected with :invalid_request
    assert {:error, :invalid_request} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_b, msg_failed)

    # Must NOT emit any reply_target telemetry
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :evicted], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :found], _, _}
    refute_received {:telemetry_event, [:strangertalks_new, :reply_target, :check_failed], _, _}

    # 3. Genuinely evicted target -> emits exactly ONE reply_target_evicted
    evicted_id = Ecto.UUID.generate()

    assert {:ok, %{status: "confirmed_unavailable"}} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_a, evicted_id)

    assert_received {:telemetry_event, [:strangertalks_new, :reply_target, :evicted], %{count: 1},
                     meta_evicted}

    refute Map.has_key?(meta_evicted, :reply_to_client_message_id)
    refute Map.has_key?(meta_evicted, :message_id)
    refute Map.has_key?(meta_evicted, :reply_snippet)
    refute Map.has_key?(meta_evicted, :content)

    # 4. Delivered target -> emits exactly ONE reply_target_found
    assert {:ok, %{status: "found"}} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_b, msg_delivered)

    assert_received {:telemetry_event, [:strangertalks_new, :reply_target, :found], %{count: 1},
                     meta_found}

    refute Map.has_key?(meta_found, :reply_to_client_message_id)
    refute Map.has_key?(meta_found, :message_id)
    refute Map.has_key?(meta_found, :reply_snippet)
    refute Map.has_key?(meta_found, :content)

    # Ensure no other telemetry messages received
    refute_received {:telemetry_event, _, _, _}
  end

  test "lookup_reply_target is read-only and does not mutate sequence, pending, or replay",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "Message 1"
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    {:ok, state_before} = ConversationServer.inspect_state(conv_id)

    assert {:ok, %{status: "found"}} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_a, msg_id)

    {:ok, state_after} = ConversationServer.inspect_state(conv_id)
    assert state_before.next_sequence == state_after.next_sequence
    assert state_before.pending_count == state_after.pending_count
    assert state_before.recent_messages == state_after.recent_messages
  end

  test "sending a valid reply attaches canonical metadata, delivers to recipient, and formats replay identically",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    recipient_pid = self()
    :ok = ConversationServer.register_channel(conv_id, context.participant_b, recipient_pid)

    original_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               original_id,
               "Original prompt"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, original_id)

    # Flush mailbox
    receive do
      {:conversation_message, _} -> :ok
    after
      0 -> :ok
    end

    # Participant B replies to Participant A's message
    reply_id = Ecto.UUID.generate()

    assert {:ok,
            %{
              message_id: ^reply_id,
              sequence: 2,
              status: "sent",
              reply_to_client_message_id: ^original_id,
              reply_author_relation: "other_participant",
              reply_snippet: "Original prompt"
            }} =
             ConversationServer.append_message(
               conv_id,
               context.participant_b,
               reply_id,
               "I hear you loud and clear",
               original_id
             )

    # Recipient (participant_a) receives delivery with reply metadata
    assert_receive {:conversation_message, delivery_payload}
    assert delivery_payload.message_id == reply_id
    assert delivery_payload.reply_to_client_message_id == original_id
    assert delivery_payload.reply_author_relation == "other_participant"
    assert delivery_payload.reply_snippet == "Original prompt"

    # ACK reply
    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_a, reply_id)

    # Sync / Replay formatting for participant A
    {:ok, sync} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        delivery_payload.epoch_id,
        0
      )

    assert [
             %{message_id: ^original_id},
             %{
               message_id: ^reply_id,
               reply_to_client_message_id: ^original_id,
               reply_author_relation: "other_participant",
               reply_snippet: "Original prompt"
             }
           ] = sync.messages
  end

  test "send-time revalidation rejects reply if target aged out or lacks delivered proof",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    unseen_id = Ecto.UUID.generate()
    reply_id = Ecto.UUID.generate()

    # Reply to non-existent / evicted target -> rejected with :invalid_request
    assert {:error, :invalid_request} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "reply to ghost",
               unseen_id
             )

    {:ok, state} = ConversationServer.inspect_state(conv_id)
    assert state.next_sequence == 1
    assert state.pending_count == 0
    assert state.recent_messages == []
  end

  test "idempotency: same ID/content/reply_target converges; changed target produces conflict",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    orig_1 = Ecto.UUID.generate()
    orig_2 = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(conv_id, context.participant_a, orig_1, "msg 1")

    assert {:ok, _} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, orig_1)

    assert {:ok, _} =
             ConversationServer.append_message(conv_id, context.participant_a, orig_2, "msg 2")

    assert {:ok, _} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, orig_2)

    reply_id = Ecto.UUID.generate()

    # First send with reply target orig_1
    assert {:ok, %{sequence: 3, status: "sent"}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "reply text",
               orig_1
             )

    # Exact duplicate retry with same target orig_1 -> idempotent success
    assert {:ok, %{sequence: 3, duplicate: true, reply_to_client_message_id: ^orig_1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "reply text",
               orig_1
             )

    # Duplicate retry with DIFFERENT target orig_2 -> MESSAGE_ID_CONFLICT
    assert {:error, :message_id_conflict} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "reply text",
               orig_2
             )

    # Duplicate retry with NO target -> MESSAGE_ID_CONFLICT
    assert {:error, :message_id_conflict} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "reply text",
               nil
             )
  end

  test "already-accepted reply duplicate retry succeeds even after original target ages out",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    original_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               original_id,
               "original"
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, original_id)

    reply_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 2}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "my reply",
               original_id
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, reply_id)

    # Flood 55 messages to evict original_id from recent_messages
    for i <- 1..55 do
      id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationServer.append_message(conv_id, context.participant_a, id, "flood #{i}")

      assert {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, id)
    end

    {:ok, state} = ConversationServer.inspect_state(conv_id)
    # Original is evicted from recent_messages
    refute Enum.any?(state.recent_messages, &(&1.message_id == original_id))

    # Retry of already-accepted reply_id with same content and target original_id succeeds via completed idempotency!
    assert {:ok, %{sequence: 2, duplicate: true, reply_to_client_message_id: ^original_id}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               reply_id,
               "my reply",
               original_id
             )
  end

  test "reply target remains valid after completed metadata is TTL-pruned if still in recent_messages",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    orig_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               orig_id,
               "target msg"
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, orig_id)

    {:ok, state} = ConversationServer.inspect_state(conv_id)
    completed_at = state.completed[orig_id].completed_at

    # Prune completed metadata (simulate 10m TTL)
    send(pid, {:prune_completed, orig_id, completed_at})
    _ = :sys.get_state(pid)

    {:ok, state_pruned} = ConversationServer.inspect_state(conv_id)
    assert state_pruned.completed == %{}

    # Target lookup still returns FOUND because delivery_status: :delivered is in recent_messages!
    assert {:ok, %{status: "found", reply_snippet: "target msg"}} =
             ConversationServer.lookup_reply_target(conv_id, context.participant_a, orig_id)

    # Reply send still succeeds!
    reply_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 2, status: "sent", reply_to_client_message_id: ^orig_id}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_b,
               reply_id,
               "reply after completed TTL",
               orig_id
             )
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

    %{
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
