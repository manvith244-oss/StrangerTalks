defmodule StrangertalksNewWeb.T05ViewEpochAuthorityTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore
  alias StrangertalksNewWeb.ParticipantToken

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  setup do
    {:ok, sender} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, recipient} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: sender.participant_id,
        participant_b_id: recipient.participant_id,
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
        participant_a_id: sender.participant_id,
        participant_b_id: recipient.participant_id,
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

    {:ok, pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})

    on_exit(fn ->
      ViewOnceMediaStore.delete_conversation(conversation.conversation_id)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok,
     conversation: conversation,
     sender_id: sender.participant_id,
     recipient_id: recipient.participant_id,
     recipient_token: ParticipantToken.sign(recipient.participant_id),
     server_pid: pid}
  end

  test "T05-VIEW-002 J RED: HTTP byte fetch rejects capability from a superseded Conversation epoch", %{
    conn: conn,
    conversation: conversation,
    sender_id: sender_id,
    recipient_id: recipient_id,
    recipient_token: recipient_token,
    server_pid: server_pid
  } do
    media = valid_jpeg()
    client_message_id = Ecto.UUID.generate()

    {:ok, staging_token} =
      ViewOnceMediaStore.stage_media(conversation.conversation_id, sender_id, media)

    assert {:ok, _} =
             ConversationServer.append_view_once_photo(
               conversation.conversation_id,
               sender_id,
               client_message_id,
               staging_token
             )

    assert {:ok, open_result} =
             ConversationServer.open_view_once_photo(
               conversation.conversation_id,
               recipient_id,
               client_message_id,
               "old-epoch-open"
             )

    {:ok, before_rollover} = ConversationServer.inspect_state(conversation.conversation_id)
    old_epoch = before_rollover.epoch_id
    new_epoch = Ecto.UUID.generate()
    refute new_epoch == old_epoch

    :sys.replace_state(server_pid, fn state -> %{state | epoch_id: new_epoch} end)

    {:ok, after_rollover} = ConversationServer.inspect_state(conversation.conversation_id)
    assert after_rollover.epoch_id == new_epoch

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get(
        "/api/conversations/#{conversation.conversation_id}/view-once/#{client_message_id}?token=#{open_result.presentation_token}"
      )

    assert response(conn, 400)
    assert json_response(conn, 400)["error"]["code"] == "INVALID_REQUEST"
  end
end
