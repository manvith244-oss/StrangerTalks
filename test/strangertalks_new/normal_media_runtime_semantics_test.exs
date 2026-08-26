defmodule StrangertalksNew.NormalMediaRuntimeSemanticsTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  test "concurrent media accepts get unique deterministic ordinals at one Conversation boundary" do
    runtime = live_conversation()

    tasks =
      for index <- 1..20 do
        Task.async(fn ->
          binary = "media-#{index}"
          id = Ecto.UUID.generate()

          {id,
           NormalMediaStore.put_media(
             runtime.conversation.conversation_id,
             runtime.a.participant_id,
             id,
             binary,
             metadata(binary)
           )}
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    entries =
      Enum.map(results, fn {id, result} ->
        assert {:ok, entry, :created} = result
        assert entry.client_message_id == id
        entry
      end)

    assert Enum.map(entries, & &1.anchor_sequence) |> Enum.uniq() == [0]
    assert entries |> Enum.map(& &1.anchor_ordinal) |> Enum.sort() == Enum.to_list(1..20)

    assert {:ok, listed} =
             NormalMediaStore.list_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id
             )

    assert Enum.map(listed, & &1.anchor_ordinal) == Enum.to_list(1..20)
    assert length(Enum.uniq_by(listed, & &1.client_message_id)) == 20
  end

  test "failed member authorization and duplicate authorization both resume ConversationServer" do
    runtime = live_conversation()
    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})
    id = Ecto.UUID.generate()
    binary = "member-bound"

    assert {:error, :not_conversation_member} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               outsider.participant_id,
               id,
               binary,
               metadata(binary)
             )

    assert {:ok, _entry, :created} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               id,
               binary,
               metadata(binary)
             )

    assert {:ok, _entry, :duplicate} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               id,
               binary,
               metadata(binary)
             )

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               Ecto.UUID.generate(),
               "ConversationServer still accepts text"
             )
  end

  test "media racing safety terminalization converges to terminal truth with no surviving media" do
    runtime = live_conversation()
    message_id = Ecto.UUID.generate()
    binary = "terminal-race-media"
    parent = self()
    owner_ref = Process.monitor(runtime.owner_pid)

    media_task =
      Task.async(fn ->
        send(parent, {:race_ready, self()})

        receive do
          :go ->
            NormalMediaStore.put_media(
              runtime.conversation.conversation_id,
              runtime.a.participant_id,
              message_id,
              binary,
              metadata(binary)
            )
        end
      end)

    terminal_task =
      Task.async(fn ->
        send(parent, {:race_ready, self()})

        receive do
          :go -> ConversationServer.trigger_safety_terminate(runtime.conversation.conversation_id)
        end
      end)

    media_pid = media_task.pid
    terminal_pid = terminal_task.pid
    assert_receive {:race_ready, ^media_pid}
    assert_receive {:race_ready, ^terminal_pid}
    send(media_pid, :go)
    send(terminal_pid, :go)

    media_result = Task.await(media_task, 10_000)
    assert :ok = Task.await(terminal_task, 10_000)

    assert match?({:ok, _entry, :created}, media_result) or
             media_result in [
               {:error, :conversation_terminating},
               {:error, :conversation_unavailable},
               {:error, :conversation_inactive}
             ]

    assert_receive {:DOWN, ^owner_ref, :process, _, :normal}, 10_000

    assert_eventually(fn ->
      NormalMediaStore.fetch_media(runtime.conversation.conversation_id, message_id) ==
        {:error, :media_unavailable}
    end)

    state = NormalMediaStore.inspect_state()
    refute Map.has_key?(state.conversation_bytes, runtime.conversation.conversation_id)

    refute Enum.any?(state.media, fn {{conversation_id, _message_id}, _entry} ->
             conversation_id == runtime.conversation.conversation_id
           end)
  end

  test "NormalMediaStore restart causes expected volatile loss while Conversation text survives and media can start fresh" do
    runtime = live_conversation()
    old_id = put_media(runtime, "volatile")
    old_store = Process.whereis(NormalMediaStore)
    old_ref = Process.monitor(old_store)

    Process.exit(old_store, :kill)
    assert_receive {:DOWN, ^old_ref, :process, ^old_store, :killed}

    new_store = await_new_store(old_store, 20_000)
    assert is_pid(new_store)
    refute new_store == old_store

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, old_id)

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               Ecto.UUID.generate(),
               "text survives volatile media loss"
             )

    new_id = put_media(runtime, "fresh")

    assert {:ok, "fresh", "image/jpeg"} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, new_id)
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

  defp assert_eventually(fun, attempts \\ 20_000)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      :erlang.yield()
      assert_eventually(fun, attempts - 1)
    end
  end

  defp await_new_store(_old_store, 0) do
    flunk("NormalMediaStore supervisor did not restart the volatile store")
  end

  defp await_new_store(old_store, attempts) do
    case Process.whereis(NormalMediaStore) do
      pid when is_pid(pid) and pid != old_store -> pid
      _ ->
        :erlang.yield()
        await_new_store(old_store, attempts - 1)
    end
  end
end
