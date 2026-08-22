defmodule StrangertalksNewWeb.ViewOnceMediaControllerTest do
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
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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
     sender_id: a.participant_id,
     recipient_id: b.participant_id,
     sender_token: ParticipantToken.sign(a.participant_id),
     recipient_token: ParticipantToken.sign(b.participant_id)}
  end

  describe "POST /api/conversations/:conversation_id/view-once/stage" do
    test "stages valid photo and returns staging_token", %{
      conn: conn,
      conversation: conv,
      sender_token: token
    } do
      media = valid_jpeg()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/api/conversations/#{conv.conversation_id}/view-once/stage", media)

      assert json_response(conn, 200)["staging_token"] != nil
    end

    test "rejects staging without authorization", %{conn: conn, conversation: conv} do
      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/api/conversations/#{conv.conversation_id}/view-once/stage", valid_jpeg())

      assert response(conn, 401)
    end

    test "rejects outsider attempting to stage photo", %{conn: conn, conversation: conv} do
      {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
      outsider_token = ParticipantToken.sign(outsider.participant_id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{outsider_token}")
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/api/conversations/#{conv.conversation_id}/view-once/stage", valid_jpeg())

      assert response(conn, 403)
    end
  end

  describe "Release-Critical Proof A: One-Shot Byte Presentation (P1–P8)" do
    test "P1 - First fetch: winning canonical open allows exactly one authorized presentation returning media bytes",
         %{
           conn: conn,
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id,
           recipient_token: recipient_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert response(conn1, 200) == media
      assert get_resp_header(conn1, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn1, "cache-control") == ["no-store, private"]
      assert get_resp_header(conn1, "x-content-type-options") == ["nosniff"]
    end

    test "P2 - Exact replay: re-using the exact same consumed capability returns 410 / 0 bytes",
         %{
           conn: conn,
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id,
           recipient_token: recipient_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert response(conn1, 200) == media

      # Exact replay fetch returns 410 with 0 media bytes
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert response(conn2, 410)
      refute response(conn2, 410) == media
    end

    test "P3 - Concurrent double fetch: using same valid capability in two concurrent requests produces at most 1 byte response",
         %{
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id,
           recipient_token: recipient_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token

      # Launch 2 concurrent tasks using Phoenix ConnTest
      task1 =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{recipient_token}")
          |> get(
            "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
          )
        end)

      task2 =
        Task.async(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer #{recipient_token}")
          |> get(
            "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
          )
        end)

      res1 = Task.await(task1, 5_000)
      res2 = Task.await(task2, 5_000)

      statuses = [res1.status, res2.status]
      assert Enum.count(statuses, &(&1 == 200)) == 1
      assert Enum.count(statuses, &(&1 == 410)) == 1
    end

    test "P4 - Sibling session misuse: second tab/session of recipient cannot reuse consumed capability",
         %{
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id,
           recipient_token: recipient_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token

      # Session 1 fetches
      conn1 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert response(conn1, 200) == media

      # Sibling tab / Session 2 attempts fetch with same token
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert response(conn2, 410)
    end

    test "P5 - Sender denial: sender cannot fetch capability or presentation bytes",
         %{
           conn: conn,
           conversation: conv,
           sender_id: sender_id,
           sender_token: sender_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Sender open attempt is rejected by conversation server
      assert {:error, :sender_cannot_acknowledge} =
               ConversationServer.open_view_once_photo(
                 conv.conversation_id,
                 sender_id,
                 client_msg_id
               )

      # Sender direct HTTP get attempt with fake/empty token fails
      conn_res =
        conn
        |> put_req_header("authorization", "Bearer #{sender_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=invalid"
        )

      assert response(conn_res, 410)
    end

    test "P6 - Foreign participant denial: unrelated outsider cannot fetch capability or bytes",
         %{
           conn: conn,
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token

      {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
      outsider_token = ParticipantToken.sign(outsider.participant_id)

      conn_res =
        conn
        |> put_req_header("authorization", "Bearer #{outsider_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert response(conn_res, 403)
    end

    test "P7 - Foreign conversation / stale epoch: request for wrong conversation returns 0 bytes",
         %{
           conn: conn,
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id,
           recipient_token: recipient_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token
      foreign_conv_id = Ecto.UUID.generate()

      conn_res =
        conn
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{foreign_conv_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      assert conn_res.status in [403, 404]
    end

    test "P8 - Post-consumption failure: interruption after one-shot authorization remains VIEWED and allows zero re-open",
         %{
           conn: conn,
           conversation: conv,
           sender_id: sender_id,
           recipient_id: recipient_id,
           recipient_token: recipient_token
         } do
      media = valid_jpeg()

      {:ok, staging_token} =
        ViewOnceMediaStore.stage_media(conv.conversation_id, sender_id, media)

      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv.conversation_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Recipient opens once
      {:ok, open_result} =
        ConversationServer.open_view_once_photo(
          conv.conversation_id,
          recipient_id,
          client_msg_id
        )

      pres_token = open_result.presentation_token

      # First fetch consumes presentation capability
      _conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get(
          "/api/conversations/#{conv.conversation_id}/view-once/#{client_msg_id}?token=#{pres_token}"
        )

      # ConversationServer state remains viewed
      {:ok, msgs} = ConversationServer.get_messages_after(conv.conversation_id, recipient_id, 0)
      [msg] = msgs.messages
      assert msg.view_once_state == "viewed"

      # Second open attempt cannot issue another presentation right
      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_photo(
                 conv.conversation_id,
                 recipient_id,
                 client_msg_id
               )
    end
  end
end
