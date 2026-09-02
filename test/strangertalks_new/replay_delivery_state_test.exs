defmodule StrangertalksNew.ReplayDeliveryStateTest do
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

  test "accepted text replay entry starts with canonical sent state", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent", sequence: 1}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg_id, "hello")

    {:ok, state} = ConversationServer.inspect_state(conv_id)

    assert [%{message_id: ^msg_id, delivery_status: :sent, sequence: 1, content: "hello"}] =
             state.recent_messages
  end

  test "ACK updates replay entry to delivered while preserving sequence, content, and single entry",
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
               "hello world"
             )

    # Recipient ACKs
    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    {:ok, state} = ConversationServer.inspect_state(conv_id)
    # Exactly 1 entry in recent_messages
    assert [
             %{
               message_id: ^msg_id,
               delivery_status: :delivered,
               sequence: 1,
               content: "hello world"
             }
           ] =
             state.recent_messages

    # Pending is empty, completed has metadata
    assert state.pending == %{}
    assert Map.has_key?(state.completed, msg_id)
    assert state.completed[msg_id].final_state == :delivered
  end

  test "terminal failure updates replay entry to failed", context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "test expire"
             )

    # Manually trigger expiry
    send(pid, {:expire_message, msg_id})
    _ = :sys.get_state(pid)

    {:ok, state} = ConversationServer.inspect_state(conv_id)

    assert [%{message_id: ^msg_id, delivery_status: :failed, sequence: 1, content: "test expire"}] =
             state.recent_messages

    assert state.pending == %{}
    assert state.completed[msg_id].final_state == :failed
  end

  test "delivered and failed states remain truthful after completed entry is pruned", context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_delivered = Ecto.UUID.generate()
    msg_failed = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_delivered,
               "msg 1"
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_failed,
               "msg 2"
             )

    # ACK first message -> delivered
    assert {:ok, _} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_delivered)

    # Expire second message -> failed
    send(pid, {:expire_message, msg_failed})
    _ = :sys.get_state(pid)

    {:ok, state} = ConversationServer.inspect_state(conv_id)
    completed_time_delivered = state.completed[msg_delivered].completed_at
    completed_time_failed = state.completed[msg_failed].completed_at

    # Prune both from completed map (simulate 10-minute TTL expiration)
    send(pid, {:prune_completed, msg_delivered, completed_time_delivered})
    send(pid, {:prune_completed, msg_failed, completed_time_failed})
    _ = :sys.get_state(pid)

    {:ok, pruned_state} = ConversationServer.inspect_state(conv_id)
    assert pruned_state.completed == %{}
    assert pruned_state.pending == %{}

    # recent_messages still retains exact terminal states
    assert [
             %{message_id: ^msg_delivered, delivery_status: :delivered},
             %{message_id: ^msg_failed, delivery_status: :failed}
           ] = pruned_state.recent_messages

    # Sync / Replay for sender (sees delivered as "delivered", failed as "failed")
    {:ok, sync_sender} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        pruned_state.epoch_id,
        0
      )

    assert [
             %{message_id: ^msg_delivered, status: "delivered", mine: true},
             %{message_id: ^msg_failed, status: "failed", mine: true}
           ] = sync_sender.messages

    # Sync / Replay for recipient (sees delivered as "delivered", failed as "skipped_terminal_failure")
    recipient_pid = spawn(fn -> receive do: (_ -> :ok) end)

    {:ok, sync_recipient} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_b,
        recipient_pid,
        pruned_state.epoch_id,
        0
      )

    assert [
             %{message_id: ^msg_delivered, status: "delivered", mine: false},
             %{message_id: ^msg_failed, disposition: "skipped_terminal_failure"}
           ] = sync_recipient.messages

    # Verify that failed message was NEVER converted to "delivered" despite completed map being empty!
    refute Enum.any?(
             sync_recipient.messages,
             &(&1.message_id == msg_failed and Map.get(&1, :status) == "delivered")
           )
  end

  test "idempotent retry behaves identically with replay delivery_status", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1, status: "sent"}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg_id, "hello")

    # In-flight duplicate retry
    assert {:ok, %{sequence: 1, status: "sent", duplicate: true}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg_id, "hello")

    # ACK
    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # Post-ACK duplicate retry
    assert {:ok, %{sequence: 1, status: "delivered", duplicate: true}} =
             ConversationServer.append_message(conv_id, context.participant_a, msg_id, "hello")

    # Content conflict
    assert {:error, :message_id_conflict} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "different"
             )
  end

  test "recent_messages retains 50 entries / 256 KB bounds with delivery_status", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    for i <- 1..60 do
      msg_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationServer.append_message(
                 conv_id,
                 context.participant_a,
                 msg_id,
                 "msg #{i}"
               )

      assert {:ok, _} =
               ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)
    end

    {:ok, state} = ConversationServer.inspect_state(conv_id)
    assert length(state.recent_messages) == 50
    assert hd(state.recent_messages).sequence == 11
    assert List.last(state.recent_messages).sequence == 60
    assert Enum.all?(state.recent_messages, &(&1.delivery_status == :delivered))
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
