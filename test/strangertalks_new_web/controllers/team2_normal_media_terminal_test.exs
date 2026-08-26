defmodule StrangertalksNewWeb.Team2NormalMediaTerminalTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, NormalMediaStore}
  alias StrangertalksNewWeb.ParticipantToken

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  setup do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: true,
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

    {:ok, pid} = ConversationServer.ensure_started(conversation.conversation_id)

    on_exit(fn ->
      NormalMediaStore.delete_conversation(conversation.conversation_id)

      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
      end
    end)

    {:ok,
     conversation: conversation,
     participant_a: participant_a,
     participant_b: participant_b,
     token_a: ParticipantToken.sign(participant_a.participant_id)}
  end

  test "normal-media upload loses authority after durable End", %{
    conn: conn,
    conversation: conversation,
    participant_a: participant_a,
    token_a: token_a
  } do
    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(
               conversation.conversation_id,
               participant_a.participant_id
             )

    assert {:error, :terminal_conversation} =
             ConversationServer.ensure_started(conversation.conversation_id)

    message_id = Ecto.UUID.generate()

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token_a}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo",
        valid_jpeg()
      )

    assert json_response(response, 410)["error"] == "conversation_inactive"

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(conversation.conversation_id, message_id)
  end
end
