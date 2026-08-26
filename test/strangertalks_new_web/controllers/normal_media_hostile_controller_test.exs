defmodule StrangertalksNewWeb.NormalMediaHostileControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken

  defp valid_jpeg(width \\ 100, height \\ 100) do
    sof0_payload = <<8, height::16, width::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
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

    {:ok, owner_pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})

    on_exit(fn ->
      NormalMediaStore.delete_conversation(conversation.conversation_id)
      if Process.alive?(owner_pid), do: Process.exit(owner_pid, :normal)
    end)

    {:ok,
     conversation: conversation,
     a: a,
     sender_token: ParticipantToken.sign(a.participant_id),
     recipient_token: ParticipantToken.sign(b.participant_id)}
  end

  test "upload, list, and fetch all require participant authentication", %{
    conversation: conversation,
    sender_token: sender_token
  } do
    message_id = upload_photo(conversation.conversation_id, sender_token)

    upload =
      build_conn()
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{Ecto.UUID.generate()}/photo",
        valid_jpeg()
      )

    assert json_response(upload, 401)["error"] == "invalid_token"

    list = get(build_conn(), "/api/conversations/#{conversation.conversation_id}/normal-media")
    assert json_response(list, 401)["error"] == "invalid_token"

    fetch =
      get(
        build_conn(),
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}"
      )

    assert json_response(fetch, 401)["error"] == "invalid_token"
  end

  test "a valid outsider identity cannot upload, list, or fetch Conversation media", %{
    conversation: conversation,
    sender_token: sender_token
  } do
    message_id = upload_photo(conversation.conversation_id, sender_token)
    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
    outsider_token = ParticipantToken.sign(outsider.participant_id)

    upload =
      build_conn()
      |> put_req_header("authorization", "Bearer #{outsider_token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(
        "/api/conversations/#{conversation.conversation_id}/normal-media/#{Ecto.UUID.generate()}/photo",
        valid_jpeg()
      )

    assert json_response(upload, 403)["error"] == "not_conversation_member"

    list =
      build_conn()
      |> put_req_header("authorization", "Bearer #{outsider_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media")

    assert json_response(list, 403)["error"] == "not_conversation_member"

    fetch =
      build_conn()
      |> put_req_header("authorization", "Bearer #{outsider_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}")

    assert json_response(fetch, 403)["error"] == "not_conversation_member"
  end

  test "guessed Conversation and media ids fail closed without revealing bytes", %{
    conversation: conversation,
    recipient_token: recipient_token
  } do
    guessed_conversation = Ecto.UUID.generate()
    guessed_media = Ecto.UUID.generate()

    wrong_conversation =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{guessed_conversation}/normal-media/#{guessed_media}")

    assert json_response(wrong_conversation, 404)["error"] == "conversation_not_found"

    wrong_media =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{guessed_media}")

    assert json_response(wrong_media, 404)["error"] == "media_unavailable"
  end

  test "zero-byte, scriptable, truncated, excessive-dimension, and kind-mismatched payloads are rejected",
       %{conversation: conversation, sender_token: token} do
    assert_media_error(conversation, token, "", "photo", 422, "malformed_media")

    assert_media_error(
      conversation,
      token,
      "<html><script>alert(1)</script></html>",
      "photo",
      422,
      "malformed_media"
    )

    jpeg = valid_jpeg()
    truncated = binary_part(jpeg, 0, byte_size(jpeg) - 2)
    assert_media_error(conversation, token, truncated, "photo", 422, "malformed_media")

    assert_media_error(
      conversation,
      token,
      valid_jpeg(2049, 100),
      "photo",
      422,
      "media_dimensions_too_large"
    )

    assert_media_error(
      conversation,
      token,
      valid_jpeg(),
      "video",
      422,
      "media_kind_mismatch"
    )

    assert NormalMediaStore.inspect_state().total_bytes == 0
  end

  test "unsupported GIF and arbitrary binary never become normal media", %{
    conversation: conversation,
    sender_token: token
  } do
    assert_media_error(conversation, token, "GIF89a-not-allowed", "photo", 422, "malformed_media")

    response = media_request(conversation, token, <<1, 2, 3, 4, 5>>, "photo")

    assert response.status in [415, 422]
    assert NormalMediaStore.inspect_state().total_bytes == 0
  end

  test "malicious Content-Length values cannot bypass the bounded body reader", %{
    conversation: conversation,
    sender_token: token
  } do
    path =
      "/api/conversations/#{conversation.conversation_id}/normal-media/#{Ecto.UUID.generate()}/photo"

    too_large =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("content-length", Integer.to_string(NormalMediaStore.max_item_bytes() + 1))
      |> post(path, valid_jpeg())

    assert json_response(too_large, 413)["error"] == "normal_media_too_large"

    invalid =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("content-length", "not-a-number")
      |> post(path, valid_jpeg())

    assert json_response(invalid, 400)["error"] == "invalid_body"
    assert NormalMediaStore.inspect_state().total_bytes == 0
  end

  test "terminal Conversation truth rejects upload, list, and fetch authority", %{
    conversation: conversation,
    sender_token: sender_token,
    recipient_token: recipient_token
  } do
    message_id = upload_photo(conversation.conversation_id, sender_token)

    conversation
    |> Ecto.Changeset.change(conversation_status: :ENDED, conversation_completed: true)
    |> Repo.update!()

    upload = media_request(conversation, sender_token, valid_jpeg(), "photo")
    assert json_response(upload, 410)["error"] == "conversation_inactive"

    list =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media")

    assert json_response(list, 410)["error"] == "conversation_inactive"

    fetch =
      build_conn()
      |> put_req_header("authorization", "Bearer #{recipient_token}")
      |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}")

    assert json_response(fetch, 410)["error"] == "conversation_inactive"
  end

  test "rapid valid upload spam is bounded by the participant media rate limit", %{
    conversation: conversation,
    sender_token: token
  } do
    statuses =
      for _ <- 1..11 do
        media_request(conversation, token, valid_jpeg(), "photo").status
      end

    assert Enum.take(statuses, 10) == List.duplicate(201, 10)
    assert List.last(statuses) == 429

    assert {:ok, items} =
             NormalMediaStore.list_media(conversation.conversation_id, conversation.participant_a_id)

    assert length(items) == 10
  end

  test "rapid malformed upload spam is rate-bounded, accounting-neutral, and text remains healthy", %{
    conversation: conversation,
    a: a,
    sender_token: token
  } do
    store_pid = Process.whereis(NormalMediaStore)

    statuses =
      for _ <- 1..12 do
        media_request(
          conversation,
          token,
          "<html><script>malformed-spam</script></html>",
          "photo"
        ).status
      end

    assert Enum.take(statuses, 10) == List.duplicate(422, 10)
    assert Enum.drop(statuses, 10) == [429, 429]
    assert Process.whereis(NormalMediaStore) == store_pid
    assert Process.alive?(store_pid)

    state = NormalMediaStore.inspect_state()
    assert state.total_bytes == 0
    assert state.conversation_bytes == %{}

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation.conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               "text survives malformed media spam"
             )
  end

  test "rapid list and fetch polling are independently rate-bounded", %{
    conversation: conversation,
    sender_token: sender_token,
    recipient_token: recipient_token
  } do
    message_id = upload_photo(conversation.conversation_id, sender_token)

    list_statuses =
      for _ <- 1..121 do
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get("/api/conversations/#{conversation.conversation_id}/normal-media")
        |> Map.fetch!(:status)
      end

    assert Enum.take(list_statuses, 120) == List.duplicate(200, 120)
    assert List.last(list_statuses) == 429

    fetch_statuses =
      for _ <- 1..121 do
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}")
        |> Map.fetch!(:status)
      end

    assert Enum.take(fetch_statuses, 120) == List.duplicate(200, 120)
    assert List.last(fetch_statuses) == 429
  end

  defp upload_photo(conversation_id, token) do
    message_id = Ecto.UUID.generate()

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/octet-stream")
    |> post("/api/conversations/#{conversation_id}/normal-media/#{message_id}/photo", valid_jpeg())
    |> json_response(201)

    message_id
  end

  defp media_request(conversation, token, body, kind) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/octet-stream")
    |> post(
      "/api/conversations/#{conversation.conversation_id}/normal-media/#{Ecto.UUID.generate()}/#{kind}",
      body
    )
  end

  defp assert_media_error(conversation, token, body, kind, status, error) do
    response = media_request(conversation, token, body, kind)
    assert json_response(response, status)["error"] == error
  end
end
