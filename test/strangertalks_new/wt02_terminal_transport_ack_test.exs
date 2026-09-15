defmodule StrangertalksNew.WT02TerminalTransportAckTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Repo

  @terminal_constraint "wt02_team6_reject_terminal_ended_at"

  setup do
    fixture = conversation_fixture()
    drop_terminal_constraint()

    on_exit(fn ->
      drop_terminal_constraint()

      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    fixture
  end

  test "text retry executes no payload transmission and does not rearm while TERMINATING",
       context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             append(context, context.participant_a, message_id, "freeze text retry")

    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    assert {:ok, before} = state(context)
    retry_token = before.pending[message_id].retry_token
    assert retry_token

    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    send(pid, {:retry_message, message_id, retry_token})
    _ = :sys.get_state(pid)

    refute_receive {:conversation_message, %{message_id: ^message_id}}, 100

    assert {:ok, after_retry} = state(context)
    assert after_retry.lifecycle_status == :TERMINATING
    assert after_retry.pending[message_id].retry_ref == nil
    assert after_retry.pending[message_id].retry_token == nil
    assert after_retry.pending_count == 1
  end

  test "expressive retry inherits the TERMINATING transmission freeze", context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent", expressive: %{id: "warm-wave"}}} =
             ConversationServer.append_expressive_message(
               conversation_id(context),
               context.participant_a,
               message_id,
               "warm-wave"
             )

    assert_receive {:conversation_message, %{message_id: ^message_id, type: "expressive"}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    assert {:ok, before} = state(context)
    retry_token = before.pending[message_id].retry_token

    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    send(pid, {:retry_message, message_id, retry_token})
    _ = :sys.get_state(pid)

    refute_receive {:conversation_message, %{message_id: ^message_id}}, 100

    assert {:ok, after_retry} = state(context)
    assert after_retry.pending[message_id].retry_ref == nil
    assert after_retry.pending[message_id].retry_token == nil
  end

  test "voice retry executes no payload transmission and does not rearm while TERMINATING",
       context do
    register_both(context)
    {voice_note_id, attrs, binary} = voice_note_fixture()

    assert {:ok, %{voice_note_id: ^voice_note_id, status: "sent_to_server"}} =
             ConversationServer.append_voice_note(
               conversation_id(context),
               context.participant_a,
               attrs,
               binary
             )

    assert_receive {:conversation_voice_note, %{voice_note_id: ^voice_note_id}}

    assert_receive {:conversation_voice_note_status,
                    %{voice_note_id: ^voice_note_id, status: "sent_to_server"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    assert {:ok, before} = state(context)
    retry_token = before.pending_voice_notes[voice_note_id].retry_token
    assert retry_token

    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    send(pid, {:retry_voice_note, voice_note_id, retry_token})
    _ = :sys.get_state(pid)

    refute_receive {:conversation_voice_note, %{voice_note_id: ^voice_note_id}}, 100

    assert {:ok, after_retry} = state(context)
    assert after_retry.lifecycle_status == :TERMINATING
    assert after_retry.pending_voice_notes[voice_note_id].retry_ref == nil
    assert after_retry.pending_voice_notes[voice_note_id].retry_token == nil
  end

  test "valid text ACK settles while TERMINATING without retransmitting content", context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             append(context, context.participant_a, message_id, "ack after freeze")

    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    assert {:ok, %{message_id: ^message_id, status: "delivered"}} =
             ConversationServer.acknowledge_message(
               conversation_id(context),
               context.participant_b,
               message_id
             )

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"}}
    refute_receive {:conversation_message, %{message_id: ^message_id}}, 100

    assert {:ok, settled} = state(context)
    refute Map.has_key?(settled.pending, message_id)
    assert settled.completed[message_id].final_state == :delivered
  end

  test "valid delivery progress settles while TERMINATING without retransmitting content",
       context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             append(context, context.participant_a, message_id, "progress after freeze")

    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    assert {:ok, %{status: "applied", highest_contiguous_sequence: 1}} =
             report_progress(context, context.participant_b, 1)

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"}}
    refute_receive {:conversation_message, %{message_id: ^message_id}}, 100

    assert {:ok, settled} = state(context)
    assert settled.delivery_progress[context.participant_b] == 1
    assert settled.completed[message_id].final_state == :delivered
  end

  test "valid voice ACK settles while TERMINATING without retransmitting content", context do
    register_both(context)
    {voice_note_id, attrs, binary} = voice_note_fixture()

    assert {:ok, %{voice_note_id: ^voice_note_id}} =
             ConversationServer.append_voice_note(
               conversation_id(context),
               context.participant_a,
               attrs,
               binary
             )

    assert_receive {:conversation_voice_note, %{voice_note_id: ^voice_note_id}}

    assert_receive {:conversation_voice_note_status,
                    %{voice_note_id: ^voice_note_id, status: "sent_to_server"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    assert {:ok, %{voice_note_id: ^voice_note_id, status: "delivered"}} =
             ConversationServer.acknowledge_voice_note(
               conversation_id(context),
               context.participant_b,
               voice_note_id
             )

    assert_receive {:conversation_voice_note_status,
                    %{voice_note_id: ^voice_note_id, status: "delivered"}}

    refute_receive {:conversation_voice_note, %{voice_note_id: ^voice_note_id}}, 100

    assert {:ok, settled} = state(context)
    refute Map.has_key?(settled.pending_voice_notes, voice_note_id)
    assert settled.completed_voice_notes[voice_note_id].final_state == :delivered
  end

  test "reconnect cannot register or replay buffered content while TERMINATING", context do
    conversation_id = conversation_id(context)
    {:ok, pid} = ConversationServer.ensure_started(conversation_id)

    assert :ok =
             ConversationServer.register_channel(conversation_id, context.participant_a, self())

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             append(context, context.participant_a, message_id, "buffered before freeze")

    refute_receive {:conversation_message, %{message_id: ^message_id}}, 50
    drain_mailbox()
    force_lifecycle(pid, :TERMINATING)

    assert {:error, :conversation_inactive} =
             ConversationServer.register_channel(conversation_id, context.participant_b, self())

    refute_receive {:conversation_message, %{message_id: ^message_id}}, 100
  end

  test "ordinary TTL expiry remains ordinary while TERMINATING", context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             append(context, context.participant_a, message_id, "ordinary ttl")

    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    send(pid, {:expire_message, message_id})
    _ = :sys.get_state(pid)

    assert_receive {:conversation_message_status,
                    %{message_id: ^message_id, status: "failed", reason: "delivery_expired"}}

    assert {:ok, expired} = state(context)
    assert expired.completed[message_id].final_state == :failed
  end

  test "delivery settled during TERMINATING is not later terminal-failed", context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             append(context, context.participant_a, message_id, "delivered before End commit")

    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    force_lifecycle(pid, :TERMINATING)
    drain_mailbox()

    assert {:ok, %{status: "applied"}} = report_progress(context, context.participant_b, 1)
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"}}

    force_lifecycle(pid, :ACTIVE)
    drain_mailbox()

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(
               conversation_id(context),
               context.participant_a
             )

    refute_receive {:conversation_message_status, %{message_id: ^message_id, status: "failed"}},
                   100
  end

  test "explicit End persistence failure restores transport retry authority", context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             append(context, context.participant_a, message_id, "retry after failed End")

    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(conversation_id(context))
    assert {:ok, before} = state(context)
    retry_token = before.pending[message_id].retry_token
    drain_mailbox()

    add_terminal_constraint()

    try do
      assert {:error, :end_not_committed} =
               ConversationServer.complete_conversation(
                 conversation_id(context),
                 context.participant_a
               )
    after
      drop_terminal_constraint()
    end

    assert {:ok, rolled_back} = state(context)
    assert rolled_back.lifecycle_status == :ACTIVE
    assert rolled_back.terminal_intent == nil
    assert Map.has_key?(rolled_back.pending, message_id)

    send(pid, {:retry_message, message_id, retry_token})
    _ = :sys.get_state(pid)

    assert_receive {:conversation_message, %{message_id: ^message_id}}, 200
  end

  defp register_both(context) do
    conversation_id = conversation_id(context)
    {:ok, _pid} = ConversationServer.ensure_started(conversation_id)

    assert :ok =
             ConversationServer.register_channel(conversation_id, context.participant_a, self())

    assert :ok =
             ConversationServer.register_channel(conversation_id, context.participant_b, self())

    drain_mailbox()
  end

  defp append(context, sender_id, message_id, content) do
    ConversationServer.append_message(conversation_id(context), sender_id, message_id, content)
  end

  defp state(context), do: ConversationServer.inspect_state(conversation_id(context))
  defp conversation_id(context), do: context.conversation.conversation_id

  defp report_progress(context, participant_id, sequence) do
    {:ok, current} = state(context)
    channel_pid = current.participant_channels[participant_id] |> Enum.at(0)

    ConversationServer.report_delivery_progress(
      conversation_id(context),
      participant_id,
      channel_pid,
      current.epoch_id,
      sequence
    )
  end

  defp force_lifecycle(pid, lifecycle_status) do
    :sys.replace_state(pid, fn state -> %{state | lifecycle_status: lifecycle_status} end)
  end

  defp voice_note_fixture do
    binary = <<"RIFF", 0, 0, 0, 0, "WAVEfmt ">>
    voice_note_id = Ecto.UUID.generate()

    attrs = %{
      voice_note_id: voice_note_id,
      media_type: "audio/wav",
      duration_ms: 1_200,
      byte_size: byte_size(binary),
      content_hash: :crypto.hash(:sha256, binary)
    }

    {voice_note_id, attrs, binary}
  end

  defp add_terminal_constraint do
    drop_terminal_constraint()

    Repo.query!("""
    ALTER TABLE conversations
    ADD CONSTRAINT #{@terminal_constraint}
    CHECK (ended_at IS NULL)
    """)

    :ok
  end

  defp drop_terminal_constraint do
    Repo.query!("""
    ALTER TABLE conversations
    DROP CONSTRAINT IF EXISTS #{@terminal_constraint}
    """)

    :ok
  end

  defp drain_mailbox do
    receive do
      _message -> drain_mailbox()
    after
      0 -> :ok
    end
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
