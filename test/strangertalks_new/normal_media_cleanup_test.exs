defmodule StrangertalksNew.NormalMediaCleanupTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore
  alias StrangertalksNew.Repo

  test "sweep retains ACTIVE, PENDING, and PAUSED media" do
    cases =
      for {status, binary} <- [{:ACTIVE, "a"}, {:PENDING, "bb"}, {:PAUSED, "ccc"}] do
        runtime = live_conversation()
        media_id = put_media(runtime, binary)
        set_status!(runtime.conversation, status)
        {runtime, media_id, binary}
      end

    sweep()

    for {runtime, media_id, binary} <- cases do
      assert {:ok, ^binary, "image/jpeg"} =
               NormalMediaStore.fetch_media(runtime.conversation.conversation_id, media_id)
    end

    assert NormalMediaStore.inspect_state().total_bytes == 6
  end

  test "sweep removes every terminal status and releases counters exactly" do
    for {status, binary} <- [
          {:ENDED, "a"},
          {:COMPLETED, "bb"},
          {:ABANDONED, "ccc"},
          {:FAILED, "dddd"}
        ] do
      runtime = live_conversation()
      _media_id = put_media(runtime, binary)
      set_status!(runtime.conversation, status)
    end

    assert NormalMediaStore.inspect_state().total_bytes == 10
    sweep()

    state = NormalMediaStore.inspect_state()
    assert state.total_bytes == 0
    assert state.conversation_bytes == %{}
    assert state.media == %{}
  end

  test "missing Conversation is swept and repeated cleanup never drives counters negative" do
    runtime = live_conversation()
    media_id = put_media(runtime, "temporary")

    Repo.delete!(runtime.conversation)
    sweep()

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, media_id)

    assert :ok = NormalMediaStore.delete_conversation(runtime.conversation.conversation_id)
    assert :ok = NormalMediaStore.delete_conversation(runtime.conversation.conversation_id)
    sweep()

    state = NormalMediaStore.inspect_state()
    assert state.total_bytes == 0
    assert state.conversation_bytes == %{}
  end

  test "normal ConversationServer exit drops volatile media and releases capacity" do
    runtime = live_conversation()
    media_id = put_media(runtime, "owner-bound")
    store_pid = Process.whereis(NormalMediaStore)
    owner_ref = Process.monitor(runtime.owner_pid)

    Process.unlink(runtime.owner_pid)
    Process.exit(runtime.owner_pid, :normal)
    assert_receive {:DOWN, ^owner_ref, :process, _pid, :normal}

    await_media_unavailable(runtime.conversation.conversation_id, media_id, 20_000)
    _ = :sys.get_state(store_pid)

    state = NormalMediaStore.inspect_state()
    assert state.total_bytes == 0
    assert state.conversation_bytes == %{}
  end

  test "sweep racing a valid ACTIVE upload cannot delete accepted media" do
    runtime = live_conversation()
    id = Ecto.UUID.generate()
    binary = "race"

    task =
      Task.async(fn ->
        NormalMediaStore.put_media(
          runtime.conversation.conversation_id,
          runtime.a.participant_id,
          id,
          binary,
          metadata(binary)
        )
      end)

    send(Process.whereis(NormalMediaStore), :sweep_inactive)

    assert {:ok, _entry, :created} = Task.await(task, 5_000)
    _ = NormalMediaStore.inspect_state()

    assert {:ok, "race", "image/jpeg"} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, id)

    assert NormalMediaStore.inspect_state().total_bytes == 4
  end

  defp live_conversation do
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

    %{conversation: conversation, a: a, b: b, owner_pid: owner_pid}
  end

  defp put_media(runtime, binary) do
    id = Ecto.UUID.generate()

    assert {:ok, _entry, :created} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               id,
               binary,
               metadata(binary)
             )

    id
  end

  defp metadata(binary) do
    %{
      media_type: "image/jpeg",
      width: 1,
      height: 1,
      content_hash: :crypto.hash(:sha256, binary)
    }
  end

  defp set_status!(conversation, status) do
    conversation
    |> Ecto.Changeset.change(conversation_status: status)
    |> Repo.update!()
  end

  defp sweep do
    send(Process.whereis(NormalMediaStore), :sweep_inactive)
    _ = NormalMediaStore.inspect_state()
    :ok
  end

  defp await_media_unavailable(_conversation_id, _media_id, 0) do
    flunk("normal media remained available after owner exit")
  end

  defp await_media_unavailable(conversation_id, media_id, attempts) do
    case NormalMediaStore.fetch_media(conversation_id, media_id) do
      {:error, :media_unavailable} ->
        :ok

      _ ->
        :erlang.yield()
        await_media_unavailable(conversation_id, media_id, attempts - 1)
    end
  end
end
