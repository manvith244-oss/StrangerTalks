defmodule StrangertalksNew.ConversationMessageEditTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  setup do
    fixture = conversation_fixture()

    start_supervised!(
      {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
    )

    fixture
  end

  test "EDIT-APPLY-1 revision 0 applies revision 1 in place with stable identity and ordering",
       context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1, status: "sent", content_revision: 0}} =
             ConversationServer.append_message(conversation_id, author, message_id, "hello")

    {:ok, before} = ConversationServer.inspect_state(conversation_id)
    epoch_id = before.epoch_id

    assert {:ok,
            %{
              status: "applied",
              client_message_id: ^message_id,
              sequence: 1,
              epoch_id: ^epoch_id,
              content: "hello there",
              content_revision: 1,
              edited: true,
              latest_content_status: "sent"
            }} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               message_id,
               0,
               " hello there "
             )

    {:ok, after_edit} = ConversationServer.inspect_state(conversation_id)
    assert after_edit.next_sequence == 2

    assert [%{client_message_id: ^message_id, sequence: 1, content: "hello there"}] =
             after_edit.recent_messages

    assert after_edit.epoch_id == epoch_id
    assert map_size(after_edit.pending) == 1
  end

  test "EDIT-NOOP same normalized content does not revise, mutate, or fan out", context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()
    :ok = ConversationServer.register_channel(conversation_id, author, self())

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, author, message_id, "same")

    flush_mailbox()

    assert {:ok, %{status: "no_op", content_revision: 0}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, " same ")

    refute_received {:conversation_message_edited, _payload}
    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert hd(state.recent_messages).content == "same"
    assert hd(state.recent_messages).peer_applied_content_revision == nil
  end

  test "EDIT-RETRY exact lost reply is ALREADY_CANONICAL without double revision or fanout",
       context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()
    :ok = ConversationServer.register_channel(conversation_id, author, self())
    assert {:ok, _} = ConversationServer.append_message(conversation_id, author, message_id, "v0")
    flush_mailbox()

    assert {:ok, %{status: "applied", content_revision: 1}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "v1")

    assert_received {:conversation_message_edited, %{content_revision: 1}}

    assert {:ok, %{status: "already_canonical", content_revision: 1}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "v1")

    refute_received {:conversation_message_edited, _payload}
  end

  test "EDIT-TRUE-STALE preserves current canonical content and returns it for convergence",
       context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()
    assert {:ok, _} = ConversationServer.append_message(conversation_id, author, message_id, "v0")

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "winner")

    assert {:ok, %{status: "stale", content: "winner", content_revision: 1}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "loser")

    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert hd(state.recent_messages).content == "winner"
    assert state.next_sequence == 2
  end

  test "EDIT-RACE same-participant concurrent writes yield one APPLY and one STALE", context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()
    assert {:ok, _} = ConversationServer.append_message(conversation_id, author, message_id, "v0")

    outcomes =
      ["winner-a", "winner-b"]
      |> Task.async_stream(
        fn content ->
          ConversationServer.edit_message(conversation_id, author, message_id, 0, content)
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result.status end)
      |> Enum.sort()

    assert outcomes == ["applied", "stale"]
    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert hd(state.recent_messages).content_revision == 1
    assert state.next_sequence == 2
  end

  test "EDIT-AUTHORITY rejects peer, foreign, absent, expressive, blank, oversized and forged revision",
       context do
    %{conversation: conversation, participant_a: author, participant_b: peer} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, author, message_id, "text")

    assert {:error, :invalid_request} =
             ConversationServer.edit_message(conversation_id, peer, message_id, 0, "forged")

    assert {:error, :target_absent} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               Ecto.UUID.generate(),
               0,
               "absent"
             )

    expressive_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_expressive_message(
               conversation_id,
               author,
               expressive_id,
               "warm-wave"
             )

    assert {:error, :invalid_request} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               expressive_id,
               0,
               "not text"
             )

    assert {:error, :invalid_request} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, " \n ")

    assert {:error, :message_too_large} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               message_id,
               0,
               String.duplicate("x", ConversationServer.max_message_bytes() + 1)
             )

    assert {:error, :invalid_revision} =
             ConversationServer.edit_message(conversation_id, author, message_id, -1, "bad")

    foreign = conversation_fixture()

    assert {:error, :not_conversation_member} =
             ConversationServer.edit_message(
               conversation_id,
               foreign.participant_a,
               message_id,
               0,
               "foreign"
             )
  end

  test "EDIT-ACCOUNTING replaces pending and replay byte contribution for larger and smaller edits",
       context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, author, message_id, "four")

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               message_id,
               0,
               "twelve-bytes"
             )

    {:ok, larger} = ConversationServer.inspect_state(conversation_id)
    assert larger.pending_bytes == byte_size("twelve-bytes")
    assert larger.replay_bytes == byte_size("twelve-bytes")

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 1, "x")

    {:ok, smaller} = ConversationServer.inspect_state(conversation_id)
    assert smaller.pending_bytes == 1
    assert smaller.replay_bytes == 1
  end

  test "EDIT-BOUNDED retains only current content and current revision", context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, author, message_id, "old")

    assert {:ok, _} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "middle")

    assert {:ok, _} =
             ConversationServer.edit_message(conversation_id, author, message_id, 1, "current")

    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    message = hd(state.recent_messages)
    assert message.content == "current"
    assert message.content_revision == 2
    refute Map.has_key?(message, :revisions)
    refute Map.has_key?(message, :old_text)
    refute inspect(state) =~ "middle"
  end

  test "EDIT-REFERENCES preserves Reply snapshot while new Reply and Pins use current edited text",
       context do
    %{conversation: conversation, participant_a: author, participant_b: peer} = context
    conversation_id = conversation.conversation_id
    target_id = Ecto.UUID.generate()
    old_reply_id = Ecto.UUID.generate()
    new_reply_id = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, author, target_id, "old target")

    assert {:ok, _} = ConversationServer.acknowledge_message(conversation_id, peer, target_id)

    assert {:ok, %{reply_snippet: "old target"}} =
             ConversationServer.append_message(
               conversation_id,
               peer,
               old_reply_id,
               "old reply",
               target_id
             )

    assert {:ok, %{status: "applied"}} =
             ConversationServer.mutate_pin(conversation_id, author, target_id, true, 0)

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               target_id,
               0,
               "edited target"
             )

    assert {:ok, %{reply_snippet: "edited target"}} =
             ConversationServer.append_message(
               conversation_id,
               peer,
               new_reply_id,
               "new reply",
               target_id
             )

    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    old_reply = Enum.find(state.recent_messages, &(&1.message_id == old_reply_id))
    assert old_reply.reply_snippet == "old target"
    assert get_in(state.pins, [author, :items]) |> hd() |> Map.fetch!(:snippet) == "edited target"
  end

  test "DELIVERY-1 through DELIVERY-4 and ACK-RETRY-1 through ACK-RETRY-5 converge monotonically",
       context do
    %{conversation: conversation, participant_a: author, participant_b: recipient} = context
    conversation_id = conversation.conversation_id
    recipient_tab_1 = start_supervised!({Agent, fn -> nil end}, id: :recipient_tab_1)
    recipient_tab_2 = start_supervised!({Agent, fn -> nil end}, id: :recipient_tab_2)
    author_tab = start_supervised!({Agent, fn -> nil end}, id: :author_tab)
    :ok = ConversationServer.register_channel(conversation_id, recipient, recipient_tab_1)
    :ok = ConversationServer.register_channel(conversation_id, recipient, recipient_tab_2)
    :ok = ConversationServer.register_channel(conversation_id, author, author_tab)

    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(conversation_id, author, message_id, "v0")

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "v1")

    {:ok, pending_state} = ConversationServer.inspect_state(conversation_id)
    epoch_id = pending_state.epoch_id
    pending_message = Enum.find(pending_state.recent_messages, &(&1.message_id == message_id))
    assert pending_message.delivery_status == :sent
    assert pending_message.content_revision == 1
    assert pending_message.peer_applied_content_revision == nil

    assert {:error, :invalid_revision} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               recipient,
               recipient_tab_1,
               epoch_id,
               message_id,
               2
             )

    assert {:ok, %{status: "stale"}} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               recipient,
               recipient_tab_1,
               Ecto.UUID.generate(),
               message_id,
               1
             )

    assert {:ok, %{status: "applied", peer_applied_content_revision: 1}} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               recipient,
               recipient_tab_1,
               epoch_id,
               message_id,
               1
             )

    assert {:ok, %{status: "no_op", peer_applied_content_revision: 1}} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               recipient,
               recipient_tab_2,
               epoch_id,
               message_id,
               1
             )

    assert {:ok, %{status: "no_op", peer_applied_content_revision: 1}} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               recipient,
               recipient_tab_2,
               epoch_id,
               message_id,
               0
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conversation_id, recipient, message_id)

    {:ok, delivered_state} = ConversationServer.inspect_state(conversation_id)
    delivered = Enum.find(delivered_state.recent_messages, &(&1.message_id == message_id))
    assert delivered.delivery_status == :delivered
    assert delivered.peer_applied_content_revision == 1

    assert {:ok, %{status: "applied", content_revision: 2, delivery_status: "delivered"}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 1, "v2")

    {:ok, after_second_edit} = ConversationServer.inspect_state(conversation_id)
    revised = Enum.find(after_second_edit.recent_messages, &(&1.message_id == message_id))
    assert revised.delivery_status == :delivered
    assert revised.peer_applied_content_revision == 1

    assert {:ok, %{status: "applied", peer_applied_content_revision: 2}} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               recipient,
               recipient_tab_2,
               epoch_id,
               message_id,
               2
             )

    assert {:error, :invalid_request} =
             ConversationServer.report_content_revision_applied(
               conversation_id,
               author,
               author_tab,
               epoch_id,
               message_id,
               2
             )
  end

  test "SYNC-JOIN-RECONCILE projects only current revision through distinct synchronization owners",
       context do
    %{conversation: conversation, participant_a: author, participant_b: recipient} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()
    join_tab = start_supervised!({Agent, fn -> nil end}, id: :join_projection_tab)

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(conversation_id, author, message_id, "before")

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, "after")

    assert {:ok,
            %{
              messages: [%{client_message_id: ^message_id, content: "after", content_revision: 1}],
              current_message_revisions: [
                %{client_message_id: ^message_id, content: "after", content_revision: 1}
              ]
            }} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               recipient,
               join_tab,
               nil,
               0
             )

    assert {:ok,
            %{
              messages: [],
              current_message_revisions: [
                %{client_message_id: ^message_id, content: "after", content_revision: 1}
              ]
            }} = ConversationServer.get_messages_after(conversation_id, recipient, 1)
  end

  test "EDIT-SAFETY durable report stays unchanged and report status is not an edit oracle",
       context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id

    assert {:ok, report} =
             StrangertalksNew.Reports.submit_conversation_report(
               conversation_id,
               author,
               "HARASSMENT",
               "participant-selected context"
             )

    reported_path_message = Ecto.UUID.generate()
    ordinary_path_message = Ecto.UUID.generate()

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               author,
               reported_path_message,
               "reported path before"
             )

    assert {:ok, _} =
             ConversationServer.append_message(
               conversation_id,
               author,
               ordinary_path_message,
               "ordinary path before"
             )

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               reported_path_message,
               0,
               "reported path after"
             )

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(
               conversation_id,
               author,
               ordinary_path_message,
               0,
               "ordinary path after"
             )

    retained = StrangertalksNew.Reports.get_report(report.report_id)
    assert retained.report_status == :SUBMITTED
    assert retained.reporter_context == "participant-selected context"
    assert retained.reported_message_id == nil
    refute inspect(retained) =~ "reported path before"
    refute inspect(retained) =~ "reported path after"
  end

  test "EDIT-DIAGNOSTIC actual telemetry owner retains only generic outcome class", context do
    %{conversation: conversation, participant_a: author} = context
    conversation_id = conversation.conversation_id
    message_id = Ecto.UUID.generate()
    secret = "private edited body #{System.unique_integer([:positive])}"
    parent = self()
    handler_id = "message-edit-privacy-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :message_edit, :applied],
        fn event, measurements, metadata, _config ->
          send(parent, {:edit_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _} =
             ConversationServer.append_message(conversation_id, author, message_id, "before")

    assert {:ok, %{status: "applied"}} =
             ConversationServer.edit_message(conversation_id, author, message_id, 0, secret)

    assert_receive {:edit_telemetry, [:strangertalks_new, :message_edit, :applied], %{count: 1},
                    %{}}

    refute_received {:edit_telemetry, _, _, _}
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
