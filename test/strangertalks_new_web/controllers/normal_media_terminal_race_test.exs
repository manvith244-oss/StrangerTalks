defmodule StrangertalksNewWeb.NormalMediaTerminalRaceTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore
  alias StrangertalksNew.Repo
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

    {:ok, owner_pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})
    store_pid = Process.whereis(NormalMediaStore)

    on_exit(fn ->
      if Process.alive?(store_pid) do
        try do
          :sys.resume(store_pid)
        catch
          :exit, _reason -> :ok
        end
      end

      NormalMediaStore.delete_conversation(conversation.conversation_id)
      if Process.alive?(owner_pid), do: Process.exit(owner_pid, :normal)
    end)

    {:ok,
     conversation: conversation,
     sender_token: ParticipantToken.sign(a.participant_id),
     recipient_token: ParticipantToken.sign(b.participant_id),
     store_pid: store_pid}
  end

  test "fetch cannot return bytes after durable terminal truth commits while the store call is queued",
       %{conversation: conversation, sender_token: sender_token, recipient_token: recipient_token, store_pid: store_pid} do
    message_id = upload_photo(conversation.conversation_id, sender_token)
    :ok = :sys.suspend(store_pid)

    request =
      Task.async(fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get("/api/conversations/#{conversation.conversation_id}/normal-media/#{message_id}")
      end)

    assert_store_call_queued(store_pid, :fetch_media, 20_000)
    terminalize!(conversation)
    :ok = :sys.resume(store_pid)

    response = Task.await(request, 5_000)
    assert json_response(response, 410)["error"] == "conversation_inactive"
  end

  test "list cannot return media authority after durable terminal truth commits while the store call is queued",
       %{conversation: conversation, sender_token: sender_token, recipient_token: recipient_token, store_pid: store_pid} do
    _message_id = upload_photo(conversation.conversation_id, sender_token)
    :ok = :sys.suspend(store_pid)

    request =
      Task.async(fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{recipient_token}")
        |> get("/api/conversations/#{conversation.conversation_id}/normal-media")
      end)

    assert_store_call_queued(store_pid, :list_media, 20_000)
    terminalize!(conversation)
    :ok = :sys.resume(store_pid)

    response = Task.await(request, 5_000)
    assert json_response(response, 410)["error"] == "conversation_inactive"
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

  defp terminalize!(conversation) do
    conversation
    |> Ecto.Changeset.change(conversation_status: :ENDED, conversation_completed: true)
    |> Repo.update!()
  end

  defp assert_store_call_queued(_store_pid, request_name, 0) do
    flunk("normal-media #{request_name} call never reached the suspended store")
  end

  defp assert_store_call_queued(store_pid, request_name, attempts) do
    queued? =
      case Process.info(store_pid, :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", _from, request} when is_tuple(request) -> elem(request, 0) == request_name
            _other -> false
          end)

        _ ->
          false
      end

    if queued? do
      :ok
    else
      :erlang.yield()
      assert_store_call_queued(store_pid, request_name, attempts - 1)
    end
  end
end
