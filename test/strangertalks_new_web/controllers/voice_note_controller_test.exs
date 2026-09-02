defmodule StrangertalksNewWeb.VoiceNoteControllerTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.VoiceNoteStore
  alias StrangertalksNew.Message
  alias StrangertalksNew.Repo
  alias StrangertalksNewWeb.ParticipantToken

  setup do
    fixture = conversation_fixture()
    :ok = VoiceNoteStore.delete_conversation(fixture.conversation.conversation_id)

    on_exit(fn ->
      VoiceNoteStore.delete_conversation(fixture.conversation.conversation_id)
      Application.delete_env(:strangertalks_new, :voice_note_global_byte_limit)

      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        _ ->
          :ok
      end
    end)

    fixture
  end

  test "upload requires a valid token and conversation membership", context do
    id = Ecto.UUID.generate()
    assert %{status: 401} = upload(build_conn(), context, id, webm(), nil)

    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})

    assert %{status: 403} =
             upload(
               build_conn(),
               context,
               id,
               webm(),
               ParticipantToken.sign(outsider.participant_id)
             )
  end

  test "approved signatures pass while mismatches, bad duration, and oversized bodies fail",
       context do
    for {type, binary} <- [
          {"audio/webm", webm()},
          {"audio/ogg", "OggSdata"},
          {"audio/mp4", <<0, 0, 0, 12, "ftyp", "data">>}
        ] do
      response =
        upload(
          build_conn(),
          context,
          Ecto.UUID.generate(),
          binary,
          token(context.participant_a),
          type
        )

      assert response.status == 200
    end

    assert upload(
             build_conn(),
             context,
             Ecto.UUID.generate(),
             "not-webm",
             token(context.participant_a)
           ).status == 422

    assert upload(
             build_conn(),
             context,
             Ecto.UUID.generate(),
             webm(),
             token(context.participant_a),
             "audio/webm",
             "0"
           ).status == 422

    assert upload(
             build_conn(),
             context,
             Ecto.UUID.generate(),
             webm() <> :binary.copy(<<0>>, 1_048_576),
             token(context.participant_a)
           ).status == 413
  end

  test "exact retries are idempotent and conflicting ID reuse is rejected", context do
    id = Ecto.UUID.generate()
    first = upload(build_conn(), context, id, webm(), token(context.participant_a))
    second = upload(build_conn(), context, id, webm(), token(context.participant_a))

    conflict =
      upload(build_conn(), context, id, webm() <> "changed", token(context.participant_a))

    assert first.status == 200
    assert second.status == 200
    assert conflict.status == 409
    assert VoiceNoteStore.inspect_metadata().total_bytes == byte_size(webm())
  end

  test "only the derived recipient can download and acknowledge", context do
    register_both(context)
    id = Ecto.UUID.generate()
    assert upload(build_conn(), context, id, webm(), token(context.participant_a)).status == 200
    assert_receive {:conversation_voice_note, %{voice_note_id: ^id, sequence: 1}}

    assert download(build_conn(), context, id, token(context.participant_a)).status == 403
    recipient = download(build_conn(), context, id, token(context.participant_b))
    assert recipient.status == 200
    assert get_resp_header(recipient, "cache-control") == ["no-store, private"]
    assert recipient.resp_body == webm()

    assert {:error, :sender_cannot_acknowledge} =
             ConversationServer.acknowledge_voice_note(
               context.conversation.conversation_id,
               context.participant_a,
               id
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_voice_note(
               context.conversation.conversation_id,
               context.participant_b,
               id
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_voice_note(
               context.conversation.conversation_id,
               context.participant_b,
               id
             )

    assert VoiceNoteStore.inspect_metadata().total_bytes == 0
  end

  test "pending, global, upload-lock, expiry, and terminal cleanup release capacity once",
       context do
    assert :ok = VoiceNoteStore.begin_upload(context.participant_a)
    assert {:error, :upload_in_progress} = VoiceNoteStore.begin_upload(context.participant_a)
    assert :ok = VoiceNoteStore.finish_upload(context.participant_a)

    register_both(context)

    ids =
      for _ <- 1..3 do
        id = Ecto.UUID.generate()

        assert upload(build_conn(), context, id, webm(), token(context.participant_a)).status ==
                 200

        id
      end

    assert upload(
             build_conn(),
             context,
             Ecto.UUID.generate(),
             webm(),
             token(context.participant_a)
           ).status == 413

    {:ok, state} = ConversationServer.inspect_state(context.conversation.conversation_id)
    expiring = hd(ids)
    note = state.pending_voice_notes[expiring]
    {:ok, pid} = ConversationServer.lookup(context.conversation.conversation_id)
    send(pid, {:expire_voice_note, expiring, note.expiry_token})
    send(pid, {:expire_voice_note, expiring, note.expiry_token})
    _ = :sys.get_state(pid)
    assert VoiceNoteStore.inspect_metadata().total_bytes == byte_size(webm()) * 2

    :ok = ConversationServer.trigger_safety_terminate(context.conversation.conversation_id)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert VoiceNoteStore.inspect_metadata().total_bytes == 0
  end

  test "global capacity rejects atomically without retaining bytes", context do
    Application.put_env(:strangertalks_new, :voice_note_global_byte_limit, byte_size(webm()) - 1)

    response =
      upload(build_conn(), context, Ecto.UUID.generate(), webm(), token(context.participant_a))

    assert response.status == 413
    assert VoiceNoteStore.inspect_metadata().total_bytes == 0
  end

  test "recipient reconnection replays chronological metadata and stale retry tokens are harmless",
       context do
    conversation_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, context.participant_a, self())
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    assert upload(build_conn(), context, first, webm(), token(context.participant_a)).status ==
             200

    assert upload(build_conn(), context, second, webm(), token(context.participant_a)).status ==
             200

    refute_receive {:conversation_voice_note, _}

    :ok = ConversationServer.register_channel(conversation_id, context.participant_b, self())
    assert_receive {:conversation_voice_note, %{voice_note_id: ^first, sequence: 1}}
    assert_receive {:conversation_voice_note, %{voice_note_id: ^second, sequence: 2}}
    {:ok, state} = ConversationServer.inspect_state(conversation_id)
    stale = state.pending_voice_notes[first].retry_token
    send(pid, {:retry_voice_note, first, stale})
    send(pid, {:retry_voice_note, first, stale})
    _ = :sys.get_state(pid)
    assert_receive {:conversation_voice_note, %{voice_note_id: ^first}}
    refute_receive {:conversation_voice_note, %{voice_note_id: ^first}}, 50
  end

  test "voice delivery is memory-only and leaves persistent counters and safety records unchanged",
       context do
    before_count = context.conversation.voice_note_count

    assert upload(
             build_conn(),
             context,
             Ecto.UUID.generate(),
             webm(),
             token(context.participant_a)
           ).status == 200

    assert Repo.aggregate(Message, :count, :message_id) == 0

    assert Repo.get!(Conversation, context.conversation.conversation_id).voice_note_count ==
             before_count

    assert Repo.aggregate(StrangertalksNew.Report, :count, :report_id) == 0
    assert Repo.aggregate(StrangertalksNew.SafetyReview, :count, :safety_review_id) == 0
  end

  defp upload(conn, context, id, body, bearer, type \\ "audio/webm", duration \\ "1000") do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", type)
      |> put_req_header("x-voice-duration-ms", duration)

    conn = if bearer, do: put_req_header(conn, "authorization", "Bearer #{bearer}"), else: conn

    post(
      conn,
      "/api/conversations/#{context.conversation.conversation_id}/voice-notes/#{id}",
      body
    )
  end

  defp download(conn, context, id, bearer),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{bearer}")
      |> get("/api/conversations/#{context.conversation.conversation_id}/voice-notes/#{id}")

  defp token(id), do: ParticipantToken.sign(id)
  defp webm, do: <<0x1A, 0x45, 0xDF, 0xA3, "voice">>

  defp register_both(context) do
    {:ok, _} = ConversationServer.ensure_started(context.conversation.conversation_id)

    :ok =
      ConversationServer.register_channel(
        context.conversation.conversation_id,
        context.participant_a,
        self()
      )

    :ok =
      ConversationServer.register_channel(
        context.conversation.conversation_id,
        context.participant_b,
        self()
      )
  end

  defp conversation_fixture do
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
      participant_a: a.participant_id,
      participant_b: b.participant_id
    }
  end
end
