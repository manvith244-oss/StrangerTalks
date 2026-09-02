defmodule StrangertalksNew.ConversationMessageUnsendTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  setup do
    fixture = conversation_fixture()

    start_supervised!(
      {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
    )

    fixture
  end

  test "UNSEND-APPLY atomically preserves identity and delivery while tombstoning content, snapshotting, and clearing references",
       context do
    %{conversation: conversation, participant_a: author, participant_b: peer} = context
    conversation_id = conversation.conversation_id
    target_id = Ecto.UUID.generate()
    reply_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation_id,
               author,
               target_id,
               "current secret"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conversation_id, peer, target_id)

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               peer,
               reply_id,
               "reply survives",
               target_id
             )

    assert {:ok, %{status: "applied"}} =
             ConversationServer.mutate_reaction(conversation_id, peer, target_id, "❤️", 0)

    assert {:ok, %{status: "applied"}} =
             ConversationServer.mutate_pin(conversation_id, peer, target_id, true, 0)

    {:ok, before} = ConversationServer.inspect_state(conversation_id)

    assert {:ok,
            %{
              status: "applied",
              availability: "unsent",
              unsent: true,
              client_message_id: ^target_id,
              sequence: 1,
              content_revision: 0,
              delivery_status: "delivered"
            } = result} = ConversationServer.unsend_message(conversation_id, author, target_id, 0)

    refute Map.has_key?(result, :content)
    refute Map.has_key?(result, :safety_snapshot)

    {:ok, after_unsend} = ConversationServer.inspect_state(conversation_id)
    assert after_unsend.epoch_id == before.epoch_id
    assert after_unsend.next_sequence == before.next_sequence
    assert length(after_unsend.recent_messages) == length(before.recent_messages)

    target = Enum.find(after_unsend.recent_messages, &(&1.client_message_id == target_id))
    reply = Enum.find(after_unsend.recent_messages, &(&1.client_message_id == reply_id))

    assert target.sequence == 1
    assert target.availability == :unsent
    assert target.content == nil
    assert target.delivery_status == :delivered
    assert target.reactions == %{}
    assert target.safety_snapshot == %{content: "current secret", content_revision: 0}
    assert reply.content == "reply survives"
    assert reply.reply_to_client_message_id == target_id
    assert reply.reply_snippet == "Unsent message"

    assert get_in(after_unsend.pins, [peer, :items]) == [
             %{
               target_client_message_id: target_id,
               author_relation: "peer",
               snippet: "Unsent message",
               unavailable_reason: "unsent"
             }
           ]

    assert after_unsend.replay_bytes ==
             byte_size("Message unsent") + byte_size("current secret") +
               byte_size("reply survives")

    assert {:error, :invalid_request} =
             ConversationServer.mutate_reaction(conversation_id, peer, target_id, "😂", 0)

    assert {:error, :invalid_request} =
             ConversationServer.mutate_pin(conversation_id, author, target_id, true, 0)

    assert {:ok, %{status: "applied", pins: []}} =
             ConversationServer.mutate_pin(conversation_id, peer, target_id, false, 1)
  end

  test "UNSEND-REPLY-TEXT supports own Reply-bearing text without replacing its logical record",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()
    reply_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_b,
               target_id,
               "peer target"
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(
               conversation_id,
               context.participant_a,
               target_id
             )

    assert {:ok, %{sequence: 2}} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               reply_id,
               "own reply body",
               target_id
             )

    assert {:ok, %{status: "applied", sequence: 2}} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               reply_id,
               0
             )

    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    reply = Enum.find(state.recent_messages, &(&1.client_message_id == reply_id))
    assert reply.availability == :unsent
    assert reply.content == nil
    assert reply.reply_to_client_message_id == target_id
    assert reply.reply_snippet == "peer target"
  end

  test "UNSEND-RETRY is ALREADY_CANONICAL with one snapshot and no duplicate fanout", context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()
    :ok = ConversationServer.register_channel(conversation_id, context.participant_a, self())

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               target_id,
               "once"
             )

    flush_mailbox()

    assert {:ok, %{status: "applied"}} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               target_id,
               0
             )

    assert_received {:conversation_message_unsent, %{client_message_id: ^target_id}}
    {:ok, once} = ConversationServer.inspect_state(conversation_id)

    assert {:ok, %{status: "already_canonical", content_revision: 0}} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               target_id,
               0
             )

    refute_received {:conversation_message_unsent, _payload}
    {:ok, twice} = ConversationServer.inspect_state(conversation_id)
    assert twice.next_sequence == once.next_sequence
    assert twice.replay_bytes == once.replay_bytes
    assert hd(twice.recent_messages).safety_snapshot == %{content: "once", content_revision: 0}
  end

  test "EDIT-WINS and UNSEND-WINS serialize through the current content revision without resurrection",
       context do
    conversation_id = context.conversation.conversation_id
    edit_wins_id = Ecto.UUID.generate()
    unsend_wins_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               edit_wins_id,
               "v0"
             )

    assert {:ok, %{status: "applied", content_revision: 1}} =
             ConversationServer.edit_message(
               conversation_id,
               context.participant_a,
               edit_wins_id,
               0,
               "v1"
             )

    assert {:ok, %{status: "stale", content: "v1", content_revision: 1}} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               edit_wins_id,
               0
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               unsend_wins_id,
               "available"
             )

    assert {:ok, %{status: "applied"}} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               unsend_wins_id,
               0
             )

    assert {:ok, %{status: "unavailable", availability: "unsent"}} =
             ConversationServer.edit_message(
               conversation_id,
               context.participant_a,
               unsend_wins_id,
               0,
               "must not return"
             )

    {:ok, state} = ConversationServer.inspect_state(conversation_id)

    assert Enum.find(state.recent_messages, &(&1.client_message_id == edit_wins_id)).content ==
             "v1"

    assert Enum.find(state.recent_messages, &(&1.client_message_id == unsend_wins_id)).content ==
             nil

    refute inspect(state) =~ "must not return"
  end

  test "UNSEND-AUTHORITY rejects peer, absent, expressive, voice-note, malformed, and terminal targets without side effects",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               target_id,
               "text"
             )

    {:ok, baseline} = ConversationServer.inspect_state(conversation_id)

    assert {:error, :invalid_request} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_b,
               target_id,
               0
             )

    assert {:error, :target_absent} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               Ecto.UUID.generate(),
               0
             )

    expressive_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_expressive_message(
               conversation_id,
               context.participant_a,
               expressive_id,
               "warm-wave"
             )

    assert {:error, :invalid_request} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               expressive_id,
               0
             )

    binary = <<"RIFF", 0, 0, 0, 0, "WAVEfmt ">>
    voice_note_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_voice_note(
               conversation_id,
               context.participant_a,
               %{
                 voice_note_id: voice_note_id,
                 media_type: "audio/wav",
                 duration_ms: 1_000,
                 byte_size: byte_size(binary),
                 content_hash: :crypto.hash(:sha256, binary)
               },
               binary
             )

    assert {:error, :invalid_request} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               voice_note_id,
               0
             )

    assert {:error, :invalid_revision} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               target_id,
               -1
             )

    {:ok, after_rejections} = ConversationServer.inspect_state(conversation_id)
    target = Enum.find(after_rejections.recent_messages, &(&1.client_message_id == target_id))
    assert target.content == "text"
    assert target.sequence == 1
    assert after_rejections.epoch_id == baseline.epoch_id
    refute Map.has_key?(target, :safety_snapshot)
  end

  test "SNAPSHOT-AUTHORITY and BYTE-ACCOUNTING retain only current canonical edit plus bounded tombstone",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               target_id,
               "original X"
             )

    assert {:ok, _} =
             ConversationServer.edit_message(
               conversation_id,
               context.participant_a,
               target_id,
               0,
               "canonical Y"
             )

    assert {:ok, %{status: "applied"}} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               target_id,
               1
             )

    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    target = hd(state.recent_messages)
    assert target.safety_snapshot == %{content: "canonical Y", content_revision: 1}
    assert state.replay_bytes == byte_size("Message unsent") + byte_size("canonical Y")
    assert state.pending_bytes == byte_size("Message unsent")
    refute inspect(state) =~ "original X"
    refute inspect(state) =~ "modified browser Z"
    refute Map.has_key?(target, :revisions)
    refute Map.has_key?(target, :history)
  end

  test "SNAPSHOT-LIFETIME actual replay pruning removes tombstone and snapshot and generically sanitizes surviving references",
       context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()
    reply_id = Ecto.UUID.generate()
    secret = "pruned safety secret"

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               target_id,
               secret
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(
               conversation_id,
               context.participant_b,
               target_id
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_b,
               reply_id,
               "reply remains",
               target_id
             )

    assert {:ok, _} =
             ConversationServer.acknowledge_message(
               conversation_id,
               context.participant_a,
               reply_id
             )

    assert {:ok, _} =
             ConversationServer.mutate_pin(
               conversation_id,
               context.participant_b,
               target_id,
               true,
               0
             )

    assert {:ok, _} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               target_id,
               0
             )

    for index <- 1..49 do
      message_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ConversationServer.append_message(
                 conversation_id,
                 context.participant_a,
                 message_id,
                 "filler #{index}"
               )

      assert {:ok, _} =
               ConversationServer.acknowledge_message(
                 conversation_id,
                 context.participant_b,
                 message_id
               )
    end

    {:ok, pruned} = ConversationServer.inspect_state(conversation_id)
    refute Enum.any?(pruned.recent_messages, &(&1.client_message_id == target_id))
    surviving_reply = Enum.find(pruned.recent_messages, &(&1.client_message_id == reply_id))
    assert surviving_reply.reply_snippet == "Message unavailable"

    assert get_in(pruned.pins, [context.participant_b, :items]) |> hd() |> Map.fetch!(:snippet) ==
             "Message unavailable"

    refute inspect(pruned) =~ secret
  end

  test "UNSEND-DIAGNOSTIC retained telemetry contains only a coarse outcome", context do
    conversation_id = context.conversation.conversation_id
    target_id = Ecto.UUID.generate()
    secret = "diagnostic secret #{System.unique_integer([:positive])}"
    parent = self()
    handler_id = "message-unsend-privacy-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :message_unsend, :applied],
        fn event, measurements, metadata, _config ->
          send(parent, {:unsend_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               context.participant_a,
               target_id,
               secret
             )

    assert {:ok, _} =
             ConversationServer.unsend_message(
               conversation_id,
               context.participant_a,
               target_id,
               0
             )

    assert_receive {:unsend_telemetry, [:strangertalks_new, :message_unsend, :applied],
                    %{count: 1}, %{}}
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
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
