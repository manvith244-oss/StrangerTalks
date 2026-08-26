defmodule StrangertalksNew.NormalMediaHostileStoreTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  setup do
    old_conversation_limit =
      Application.get_env(:strangertalks_new, :normal_media_conversation_byte_limit)

    old_global_limit = Application.get_env(:strangertalks_new, :normal_media_global_byte_limit)

    on_exit(fn ->
      restore_env(:normal_media_conversation_byte_limit, old_conversation_limit)
      restore_env(:normal_media_global_byte_limit, old_global_limit)
    end)

    :ok
  end

  test "per-Conversation capacity is exact, rejection is accounting-neutral, and text survives" do
    %{conversation: conversation, a: a} = live_conversation()
    configure_limits(10, 100)

    assert_created(conversation, a, "123456")
    assert_created(conversation, a, "7890")
    assert_accounting(%{conversation.conversation_id => 10}, 10)

    rejected_id = Ecto.UUID.generate()

    assert {:error, :normal_media_conversation_capacity} =
             NormalMediaStore.put_media(
               conversation.conversation_id,
               a.participant_id,
               rejected_id,
               "x",
               metadata("x")
             )

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(conversation.conversation_id, rejected_id)

    assert_accounting(%{conversation.conversation_id => 10}, 10)

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conversation.conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               "text survives media capacity"
             )
  end

  test "global capacity spans Conversations, cleanup releases exact bytes, and capacity is reusable" do
    first = live_conversation()
    second = live_conversation()
    third = live_conversation()
    configure_limits(10, 10)

    assert_created(first.conversation, first.a, "123456")
    assert_created(second.conversation, second.a, "7890")

    assert_accounting(
      %{first.conversation.conversation_id => 6, second.conversation.conversation_id => 4},
      10
    )

    blocked_id = Ecto.UUID.generate()

    assert {:error, :normal_media_global_capacity} =
             NormalMediaStore.put_media(
               third.conversation.conversation_id,
               third.a.participant_id,
               blocked_id,
               "x",
               metadata("x")
             )

    assert_accounting(
      %{first.conversation.conversation_id => 6, second.conversation.conversation_id => 4},
      10
    )

    assert :ok = NormalMediaStore.delete_conversation(first.conversation.conversation_id)
    assert_accounting(%{second.conversation.conversation_id => 4}, 4)

    assert_created(third.conversation, third.a, "abcdef")

    assert_accounting(
      %{second.conversation.conversation_id => 4, third.conversation.conversation_id => 6},
      10
    )
  end

  test "many Conversations under concurrent global pressure remain bounded and reuse released capacity" do
    configure_limits(100, 20)
    runtimes = for _ <- 1..10, do: live_conversation()

    tasks =
      Enum.map(runtimes, fn runtime ->
        Task.async(fn ->
          result =
            NormalMediaStore.put_media(
              runtime.conversation.conversation_id,
              runtime.a.participant_id,
              Ecto.UUID.generate(),
              "load",
              metadata("load")
            )

          {runtime, result}
        end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    accepted = Enum.filter(results, fn {_runtime, result} -> match?({:ok, _, :created}, result) end)

    rejected =
      Enum.filter(results, fn {_runtime, result} ->
        match?({:error, :normal_media_global_capacity}, result)
      end)

    assert length(accepted) == 5
    assert length(rejected) == 5

    expected =
      Map.new(accepted, fn {runtime, _result} ->
        {runtime.conversation.conversation_id, 4}
      end)

    assert_accounting(expected, 20)

    {rejected_runtime, _} = hd(rejected)

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               rejected_runtime.conversation.conversation_id,
               rejected_runtime.a.participant_id,
               Ecto.UUID.generate(),
               "text survives global media pressure"
             )

    {released_runtime, _} = hd(accepted)
    assert :ok = NormalMediaStore.delete_conversation(released_runtime.conversation.conversation_id)

    expected_after_release = Map.delete(expected, released_runtime.conversation.conversation_id)
    assert_accounting(expected_after_release, 16)

    assert_created(rejected_runtime.conversation, rejected_runtime.a, "load")

    assert_accounting(
      Map.put(expected_after_release, rejected_runtime.conversation.conversation_id, 4),
      20
    )

    assert Process.alive?(Process.whereis(NormalMediaStore))
  end

  test "concurrent uploads cannot materially exceed the per-Conversation limit" do
    %{conversation: conversation, a: a} = live_conversation()
    configure_limits(10, 100)

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          NormalMediaStore.put_media(
            conversation.conversation_id,
            a.participant_id,
            Ecto.UUID.generate(),
            "xx",
            metadata("xx")
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    created = Enum.count(results, &match?({:ok, _entry, :created}, &1))
    rejected = Enum.count(results, &match?({:error, :normal_media_conversation_capacity}, &1))

    assert created == 5
    assert rejected == 15
    assert_accounting(%{conversation.conversation_id => 10}, 10)

    assert {:ok, items} = NormalMediaStore.list_media(conversation.conversation_id, a.participant_id)
    assert length(items) == 5
  end

  test "duplicate storms create one logical item and never double-charge bytes" do
    %{conversation: conversation, a: a} = live_conversation()
    configure_limits(100, 100)
    client_message_id = Ecto.UUID.generate()
    binary = "same"

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          NormalMediaStore.put_media(
            conversation.conversation_id,
            a.participant_id,
            client_message_id,
            binary,
            metadata(binary)
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _entry, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _entry, :duplicate}, &1)) == 19
    assert_accounting(%{conversation.conversation_id => 4}, 4)

    assert {:ok, [item]} = NormalMediaStore.list_media(conversation.conversation_id, a.participant_id)
    assert item.client_message_id == client_message_id
  end

  test "peer reuse of a client id conflicts while the same id remains isolated across Conversations" do
    first = live_conversation()
    second = live_conversation()
    configure_limits(100, 100)
    client_message_id = Ecto.UUID.generate()
    binary = "media"

    assert {:ok, _entry, :created} =
             NormalMediaStore.put_media(
               first.conversation.conversation_id,
               first.a.participant_id,
               client_message_id,
               binary,
               metadata(binary)
             )

    assert {:error, :normal_media_identity_conflict} =
             NormalMediaStore.put_media(
               first.conversation.conversation_id,
               first.b.participant_id,
               client_message_id,
               binary,
               metadata(binary)
             )

    assert {:ok, _entry, :created} =
             NormalMediaStore.put_media(
               second.conversation.conversation_id,
               second.a.participant_id,
               client_message_id,
               binary,
               metadata(binary)
             )

    assert_accounting(
      %{first.conversation.conversation_id => 5, second.conversation.conversation_id => 5},
      10
    )
  end

  test "item-size boundary accepts exactly 5 MiB and rejects one byte over without phantom accounting" do
    %{conversation: conversation, a: a} = live_conversation()
    max = NormalMediaStore.max_item_bytes()
    configure_limits(max * 2, max * 2)
    exact = :binary.copy(<<0x41>>, max)

    assert {:ok, _entry, :created} =
             NormalMediaStore.put_media(
               conversation.conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               exact,
               metadata(exact)
             )

    assert_accounting(%{conversation.conversation_id => max}, max)

    over = exact <> <<0x42>>

    assert {:error, :normal_media_too_large} =
             NormalMediaStore.put_media(
               conversation.conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               over,
               metadata(over)
             )

    assert_accounting(%{conversation.conversation_id => max}, max)
  end

  test "zero-byte store payload is rejected without charging capacity" do
    %{conversation: conversation, a: a} = live_conversation()
    configure_limits(100, 100)

    assert {:error, :normal_media_too_large} =
             NormalMediaStore.put_media(
               conversation.conversation_id,
               a.participant_id,
               Ecto.UUID.generate(),
               "",
               metadata("")
             )

    assert_accounting(%{}, 0)
  end

  test "duplicate stale DOWN from an old owner cannot erase media belonging to a reconstructed owner" do
    %{conversation: conversation, a: a, owner_pid: owner_pid} = live_conversation()
    configure_limits(100, 100)
    assert_created(conversation, a, "old")

    state = NormalMediaStore.inspect_state()
    %{ref: old_ref} = Map.fetch!(state.owners, conversation.conversation_id)

    Process.unlink(owner_pid)
    owner_monitor = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :killed}

    assert_eventually(fn ->
      NormalMediaStore.fetch_media(conversation.conversation_id, Ecto.UUID.generate()) ==
        {:error, :media_unavailable}
    end)

    {:ok, replacement_pid} =
      ConversationServer.start_link(%{conversation_id: conversation.conversation_id})

    on_exit(fn ->
      if Process.alive?(replacement_pid), do: Process.exit(replacement_pid, :normal)
    end)

    new_id = assert_created(conversation, a, "new")
    send(Process.whereis(NormalMediaStore), {:DOWN, old_ref, :process, owner_pid, :killed})
    _ = NormalMediaStore.inspect_state()

    assert {:ok, "new", "image/jpeg"} =
             NormalMediaStore.fetch_media(conversation.conversation_id, new_id)

    assert_accounting(%{conversation.conversation_id => 3}, 3)
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

  defp assert_created(conversation, participant, binary) do
    id = Ecto.UUID.generate()

    assert {:ok, _entry, :created} =
             NormalMediaStore.put_media(
               conversation.conversation_id,
               participant.participant_id,
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

  defp configure_limits(conversation_limit, global_limit) do
    Application.put_env(
      :strangertalks_new,
      :normal_media_conversation_byte_limit,
      conversation_limit
    )

    Application.put_env(:strangertalks_new, :normal_media_global_byte_limit, global_limit)
  end

  defp assert_accounting(expected_conversation_bytes, expected_total) do
    state = NormalMediaStore.inspect_state()
    assert state.conversation_bytes == expected_conversation_bytes
    assert state.total_bytes == expected_total

    actual_total = state.media |> Map.values() |> Enum.map(& &1.byte_size) |> Enum.sum()
    assert actual_total == state.total_bytes

    for {conversation_id, expected_bytes} <- expected_conversation_bytes do
      actual =
        state.media
        |> Map.values()
        |> Enum.filter(&(&1.conversation_id == conversation_id))
        |> Enum.map(& &1.byte_size)
        |> Enum.sum()

      assert actual == expected_bytes
    end

    assert Enum.all?(Map.values(state.conversation_bytes), &(&1 >= 0))
    assert state.total_bytes >= 0
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      :erlang.yield()
      assert_eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
