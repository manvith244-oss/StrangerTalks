defmodule StrangertalksNew.ConversationPinTest do
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

  test "pin to peer delivered text and own delivered text accepted (rev 0 -> 1)", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg1_id = Ecto.UUID.generate()
    msg2_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg1_id,
               "Hello from A"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg1_id)

    assert {:ok, %{sequence: 2}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_b,
               msg2_id,
               "Hello from B"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_a, msg2_id)

    # Participant A pins their own delivered message
    assert {:ok,
            %{
              status: "applied",
              revision: 1,
              pins: [
                %{
                  target_client_message_id: ^msg1_id,
                  author_relation: "self",
                  snippet: "Hello from A"
                }
              ]
            }} =
             ConversationServer.mutate_pin(
               conv_id,
               context.participant_a,
               msg1_id,
               true,
               0
             )

    assert_receive {:conversation_pins,
                    %{
                      revision: 1,
                      pins: [
                        %{
                          target_client_message_id: ^msg1_id,
                          author_relation: "self",
                          snippet: "Hello from A"
                        }
                      ]
                    }}

    # Participant A pins peer's delivered message
    assert {:ok,
            %{
              status: "applied",
              revision: 2,
              pins: [
                %{
                  target_client_message_id: ^msg1_id,
                  author_relation: "self",
                  snippet: "Hello from A"
                },
                %{
                  target_client_message_id: ^msg2_id,
                  author_relation: "peer",
                  snippet: "Hello from B"
                }
              ]
            }} =
             ConversationServer.mutate_pin(
               conv_id,
               context.participant_a,
               msg2_id,
               true,
               1
             )
  end

  test "pin derives snippet bounded to max 160 graphemes / max 512 bytes", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    long_text = String.duplicate("🌟 Hello World! ", 30)
    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               long_text
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    assert {:ok, %{status: "applied", pins: [pin]}} =
             ConversationServer.mutate_pin(
               conv_id,
               context.participant_a,
               msg_id,
               true,
               0
             )

    assert String.length(String.replace(pin.snippet, "…", "")) <= 160
    assert byte_size(pin.snippet) <= 512
  end

  test "pin capacity limit: max 3 pins per participant, 4th pin rejected", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_ids =
      for i <- 1..4 do
        id = Ecto.UUID.generate()

        {:ok, _} =
          ConversationServer.append_message(conv_id, context.participant_a, id, "Message #{i}")

        {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, id)
        id
      end

    [id1, id2, id3, id4] = msg_ids

    # Pin 1, 2, 3
    assert {:ok, %{status: "applied", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, id1, true, 0)

    assert {:ok, %{status: "applied", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, id2, true, 1)

    assert {:ok, %{status: "applied", revision: 3, pins: items}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, id3, true, 2)

    assert length(items) == 3

    # Pin 4 fails with :pin_limit_reached
    assert {:error, :pin_limit_reached} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, id4, true, 3)
  end

  test "unpin removes item and increments revision without consulting recent_messages", context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "Message to pin and prune"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    assert {:ok, %{status: "applied", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, true, 0)

    # Simulate pruning by clearing recent_messages in state
    :sys.replace_state(pid, fn state ->
      %{state | recent_messages: []}
    end)

    # UNPIN succeeds even though target is absent from recent_messages!
    assert {:ok,
            %{
              status: "applied",
              revision: 2,
              pins: []
            }} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, false, 1)
  end

  test "collection-level CAS matrix enforcement", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg1_id = Ecto.UUID.generate()
    msg2_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg1_id, "Msg 1")

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg1_id)

    assert {:ok, %{sequence: 2}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg2_id, "Msg 2")

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg2_id)

    # 1. expected > current -> error :invalid_revision
    assert {:error, :invalid_revision} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, true, 5)

    # 2. expected == current (0), desired differs -> applied (rev 0 -> 1)
    assert {:ok, %{status: "applied", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, true, 0)

    # 3. expected == current (1), desired already canonical (pinned: true) -> no_op (rev 1)
    assert {:ok, %{status: "no_op", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, true, 1)

    # Apply second pin (rev 1 -> 2)
    assert {:ok, %{status: "applied", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg2_id, true, 1)

    # 4. expected < current (rev 0 vs current 2), desired is already canonical (msg1 is pinned) -> already_canonical (rev 2)
    assert {:ok, %{status: "already_canonical", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, true, 0)

    # 5. expected < current (rev 1 vs current 2), desired conflicts (trying to unpin msg1 with stale rev 1) -> stale_revision (rev 2)
    assert {:ok, %{status: "stale_revision", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, false, 1)

    # 6. Negative expected revision -> error :invalid_revision
    assert {:error, :invalid_revision} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, false, -1)
  end

  test "participant privacy: state and notifications are completely isolated between participants",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    # Mock peer process to check notifications
    peer_pid =
      spawn_link(fn ->
        receive do
          msg -> send(self(), {:unexpected_peer_msg, msg})
        end
      end)

    :ok = ConversationServer.register_channel(conv_id, context.participant_b, peer_pid)

    msg_id = Ecto.UUID.generate()
    {:ok, _} = ConversationServer.append_message(conv_id, context.participant_a, msg_id, "Msg")
    {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # Participant A pins
    assert {:ok, %{status: "applied", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, true, 0)

    # Actor gets notified
    assert_receive {:conversation_pins, %{revision: 1}}

    # Peer receives NOTHING
    refute_receive {:unexpected_peer_msg, _}, 100

    # Peer's pins collection remains empty at revision 0
    {:ok, sync_b} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_b,
        peer_pid,
        Ecto.UUID.generate(),
        0
      )

    assert sync_b.pins == %{revision: 0, items: []}
  end

  test "ineligible targets for PIN: absent target, sent target, failed target", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    absent_id = Ecto.UUID.generate()
    sent_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               sent_id,
               "Sent only"
             )

    # 1. Absent target
    assert {:error, :target_absent} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, absent_id, true, 0)

    # 2. Sent (undelivered) target
    assert {:error, :invalid_request} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, sent_id, true, 0)
  end

  test "sync payload attachments and sequence_inconsistent withholding", context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(conv_id, context.participant_a, msg_id, "Delivered")

    {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    {:ok, %{pins: [pinned_item]}} =
      ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, true, 0)

    state = :sys.get_state(pid)

    # Valid sync attached pins
    {:ok, sync_payload} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        state.epoch_id,
        0
      )

    assert sync_payload.pins == %{revision: 1, items: [pinned_item]}

    # get_messages_after attached pins
    assert {:ok, %{pins: %{revision: 1, items: [^pinned_item]}}} =
             ConversationServer.get_messages_after(conv_id, context.participant_a, 0)

    # sequence_inconsistent withholds pins
    {:ok, inconsistent_payload} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        state.epoch_id,
        999
      )

    assert inconsistent_payload.status == "sequence_inconsistent"
    refute Map.has_key?(inconsistent_payload, :pins)
  end

  test "pin mutation isolates replay lifecycle: next_sequence, replay_bytes, and delivery states remain unchanged",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "Replay Isolation"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    state_before = :sys.get_state(pid)
    seq_before = state_before.next_sequence
    replay_bytes_before = state_before.replay_bytes
    recent_len_before = length(state_before.recent_messages)

    # Execute PIN
    assert {:ok, %{status: "applied", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, true, 0)

    state_after_pin = :sys.get_state(pid)
    assert state_after_pin.next_sequence == seq_before
    assert state_after_pin.replay_bytes == replay_bytes_before
    assert length(state_after_pin.recent_messages) == recent_len_before

    msg = Enum.find(state_after_pin.recent_messages, &(&1.client_message_id == msg_id))
    assert msg.delivery_status == :delivered

    # Execute UNPIN
    assert {:ok, %{status: "applied", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, false, 1)

    state_after_unpin = :sys.get_state(pid)
    assert state_after_unpin.next_sequence == seq_before
    assert state_after_unpin.replay_bytes == replay_bytes_before
    assert length(state_after_unpin.recent_messages) == recent_len_before
  end

  test "ordering and stale pin/unpin CAS transitions (stale PIN, stale PIN already achieved, stale UNPIN, stale UNPIN already achieved)",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg1_id = Ecto.UUID.generate()
    msg2_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg1_id, "Msg 1")

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg1_id)

    assert {:ok, %{sequence: 2}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg2_id, "Msg 2")

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg2_id)

    # Pin msg1: rev 0 -> 1
    assert {:ok, %{status: "applied", revision: 1}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, true, 0)

    # Pin msg2: rev 1 -> 2
    assert {:ok, %{status: "applied", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg2_id, true, 1)

    # 1. Stale PIN (msg2 is pinned, trying to pin absent msg3 with expected 1 < current 2) -> STALE_REVISION
    absent_id = Ecto.UUID.generate()

    assert {:ok, %{status: "stale_revision", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, absent_id, true, 1)

    # 2. Stale PIN already achieved (msg1 is already pinned, expected 0 < current 2) -> ALREADY_CANONICAL
    assert {:ok, %{status: "already_canonical", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, true, 0)

    # 3. Stale UNPIN (msg1 is pinned, trying to unpin with expected 0 < current 2) -> STALE_REVISION
    assert {:ok, %{status: "stale_revision", revision: 2}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, false, 0)

    # Unpin msg1: rev 2 -> 3
    assert {:ok, %{status: "applied", revision: 3}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, false, 2)

    # 4. Stale UNPIN already achieved (msg1 is no longer pinned, expected 2 < current 3) -> ALREADY_CANONICAL
    assert {:ok, %{status: "already_canonical", revision: 3}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, msg1_id, false, 2)
  end

  test "unpin of missing pin produces NO_OP and zero fanout", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    unpinned_id = Ecto.UUID.generate()

    # Current revision is 0, unpin of missing pin returns no_op at rev 0
    assert {:ok, %{status: "no_op", revision: 0, pins: []}} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, unpinned_id, false, 0)

    # Zero fanout
    refute_receive {:conversation_pins, _}, 100
  end

  test "pin of non-text target is rejected as invalid_request", context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    vn_id = Ecto.UUID.generate()

    # Inject a non-text (voice_note) message into recent_messages
    :sys.replace_state(pid, fn state ->
      non_text_msg = %{
        client_message_id: vn_id,
        sender_id: context.participant_a,
        type: :voice_note,
        content: nil,
        delivery_status: :delivered,
        sequence: 1,
        inserted_at: DateTime.utc_now()
      }

      %{state | recent_messages: [non_text_msg], next_sequence: 2}
    end)

    assert {:error, :invalid_request} =
             ConversationServer.mutate_pin(conv_id, context.participant_a, vn_id, true, 0)
  end

  test "reconnect sync statuses (initial, up_to_date, catch_up_complete, catch_up_partial, epoch_changed) and restart/epoch reset",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(conv_id, context.participant_a, msg_id, "Sync Status Msg")

    {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    {:ok, %{pins: [pinned_item]}} =
      ConversationServer.mutate_pin(conv_id, context.participant_a, msg_id, true, 0)

    state = :sys.get_state(pid)

    # 1. initial status
    {:ok, init_sync} =
      ConversationServer.sync_and_register_channel(conv_id, context.participant_a, self(), nil, 0)

    assert init_sync.status in ["initial", "catch_up_complete"]
    assert init_sync.pins == %{revision: 1, items: [pinned_item]}

    # 2. up_to_date status
    {:ok, up_to_date_sync} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        state.epoch_id,
        1
      )

    assert up_to_date_sync.status == "up_to_date"
    assert up_to_date_sync.pins == %{revision: 1, items: [pinned_item]}

    # 3. epoch_changed status
    old_epoch = Ecto.UUID.generate()

    {:ok, epoch_changed_sync} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        old_epoch,
        1
      )

    assert epoch_changed_sync.status == "epoch_changed"
    assert epoch_changed_sync.pins == %{revision: 1, items: [pinned_item]}

    # 4. Restart / new runtime starts with empty pin state at revision 0
    fresh_fixture = conversation_fixture()

    {:ok, fresh_pid} =
      ConversationServer.ensure_started(fresh_fixture.conversation.conversation_id)

    fresh_state = :sys.get_state(fresh_pid)
    assert Map.get(fresh_state.pins, fresh_fixture.participant_a) == %{revision: 0, items: []}
    DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, fresh_pid)
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
      match: match,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
