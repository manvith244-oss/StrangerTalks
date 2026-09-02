defmodule StrangertalksNewWeb.NormalMediaControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken

  defp valid_jpeg(entropy \\ 0x12) do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, entropy, 0x34, 0xFF, 0xD9>>
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
      NormalMediaStore.delete_conversation(conversation.conversation_id)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok,
     conversation: conversation,
     sender_id: a.participant_id,
     recipient_id: b.participant_id,
     sender_token: ParticipantToken.sign(a.participant_id),
     recipient_token: ParticipantToken.sign(b.participant_id)}
  end

  test "normal photo is stored once and can be reopened repeatedly by the peer", %{
    conn: conn,
    conversation: conversation,
    sender_token: sender_token,
    recipient_token: recipient_token
  } do
    media = valid_jpeg()
    message_id = Ecto.UUID.generate()
    path = "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo"

    first =
      conn
      |> put_req_header("authorization", "Bearer #{sender_token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(path, media)

    payload = json_response(first, 201)
    assert payload["client_message_id"] == message_id
    assert payload["kind"] == "photo"
    assert payload["idempotent"] == false
    assert payload["anchor_sequence"] == 0
    assert payload["anchor_ordinal"] == 1
    refute Map.has_key?(payload, "filename")

    duplicate =
      build_conn()
      |> put_req_header("authorization", "Bearer #{sender_token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(path, media)

    duplicate_payload = json_response(duplicate, 200)
    assert duplicate_payload["idempotent"] == true
    assert duplicate_payload["anchor_sequence"] == 0
    assert duplicate_payload["anchor_ordinal"] == 1

    list =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media")
      |> json_response(200)

    assert [%{"client_message_id" => ^message_id, "mine" => false}] = list["items"]

    media_path = "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}"

    first_open =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get(media_path)

    second_open =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get(media_path)

    assert response(first_open, 200) == media
    assert response(second_open, 200) == media
    assert get_resp_header(second_open, "cache-control") == ["no-store, private"]
    assert get_resp_header(second_open, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(second_open, "content-disposition") == ["inline"]
  end

  test "media accepted then text accepted anchors media before text", %{
    conn: conn,
    conversation: conversation,
    sender_id: sender_id,
    sender_token: token
  } do
    media_id = Ecto.UUID.generate()

    media =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{media_id}/photo",
        valid_jpeg()
      )
      |> json_response(201)

    assert media["anchor_sequence"] == 0

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation.conversation_id,
               sender_id,
               Ecto.UUID.generate(),
               "text after media"
             )
  end

  test "text accepted then media accepted anchors text before media", %{
    conn: conn,
    conversation: conversation,
    sender_id: sender_id,
    sender_token: token
  } do
    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation.conversation_id,
               sender_id,
               Ecto.UUID.generate(),
               "text before media"
             )

    media_id = Ecto.UUID.generate()

    media =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{media_id}/photo",
        valid_jpeg()
      )
      |> json_response(201)

    assert media["anchor_sequence"] == 1
    assert media["anchor_ordinal"] == 1
  end

  test "media1 text media2 keeps canonical boundaries and stable retry anchor", %{
    conn: conn,
    conversation: conversation,
    sender_id: sender_id,
    sender_token: token,
    recipient_token: recipient_token
  } do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    first_path =
      "/api/conversations/#{conversation.conversation_id}/normal-media/#{first_id}/photo"

    first =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(first_path, valid_jpeg())
      |> json_response(201)

    assert first["anchor_sequence"] == 0

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation.conversation_id,
               sender_id,
               Ecto.UUID.generate(),
               "middle text"
             )

    second =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{second_id}/photo",
        valid_jpeg(0x13)
      )
      |> json_response(201)

    assert second["anchor_sequence"] == 1

    retry =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(first_path, valid_jpeg())
      |> json_response(200)

    assert retry["idempotent"] == true
    assert retry["anchor_sequence"] == 0
    assert retry["anchor_ordinal"] == 1

    items =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media")
      |> json_response(200)
      |> Map.fetch!("items")

    assert Enum.map(items, &{&1["client_message_id"], &1["anchor_sequence"]}) == [
             {first_id, 0},
             {second_id, 1}
           ]
  end

  test "server ignores declared MIME and rejects spoofed active content", %{
    conn: conn,
    conversation: conversation,
    sender_token: token
  } do
    message_id = Ecto.UUID.generate()

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "image/jpeg")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo",
        "<script>alert('not an image')</script>"
      )

    assert json_response(response, 422)["error"] == "malformed_media"
  end

  test "oversized body is rejected before it can become a media message", %{
    conn: conn,
    conversation: conversation,
    sender_token: token
  } do
    message_id = Ecto.UUID.generate()
    oversized = :binary.copy(<<0xFF>>, 1_048_577)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo",
        oversized
      )

    assert json_response(response, 413)["error"] == "normal_media_too_large"

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(conversation.conversation_id, message_id)
  end

  test "wrong participant and wrong Conversation cannot retrieve normal media", %{
    conn: conn,
    conversation: conversation,
    sender_token: sender_token
  } do
    message_id = Ecto.UUID.generate()

    conn
    |> put_req_header("authorization", "Bearer #{sender_token}")
    |> put_req_header("content-type", "application/octet-stream")
    |> post(
      "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo",
      valid_jpeg()
    )
    |> json_response(201)

    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
    outsider_token = ParticipantToken.sign(outsider.participant_id)

    outsider_response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{outsider_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}")

    assert response(outsider_response, 403)

    wrong_conversation_response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{sender_token}")
      |> get("/api/conversations/#{Ecto.UUID.generate()}/normal-media/#{message_id}")

    assert response(wrong_conversation_response, 404)
  end

  test "terminal Conversation access fails closed", %{
    conn: conn,
    conversation: conversation,
    sender_token: sender_token,
    recipient_token: recipient_token
  } do
    message_id = Ecto.UUID.generate()

    conn
    |> put_req_header("authorization", "Bearer #{sender_token}")
    |> put_req_header("content-type", "application/octet-stream")
    |> post(
      "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo",
      valid_jpeg()
    )
    |> json_response(201)

    conversation
    |> Ecto.Changeset.change(conversation_status: :ENDED, conversation_completed: true)
    |> Repo.update!()

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}")

    assert response(response, 410)
  end

  test "same client id with different bytes cannot overwrite the first media", %{
    conn: conn,
    conversation: conversation,
    sender_token: token
  } do
    message_id = Ecto.UUID.generate()
    path = "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}/photo"

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/octet-stream")
    |> post(path, valid_jpeg(0x12))
    |> json_response(201)

    conflict =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(path, valid_jpeg(0x13))

    assert json_response(conflict, 409)["error"] == "normal_media_identity_conflict"
  end
end
