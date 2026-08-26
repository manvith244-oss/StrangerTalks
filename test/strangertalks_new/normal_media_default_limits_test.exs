defmodule StrangertalksNew.NormalMediaDefaultLimitsTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  @item_limit 5_242_880
  @conversation_limit 20_971_520
  @global_limit 67_108_864

  setup do
    old_conversation_limit =
      Application.get_env(:strangertalks_new, :normal_media_conversation_byte_limit)

    old_global_limit = Application.get_env(:strangertalks_new, :normal_media_global_byte_limit)

    Application.delete_env(:strangertalks_new, :normal_media_conversation_byte_limit)
    Application.delete_env(:strangertalks_new, :normal_media_global_byte_limit)

    on_exit(fn ->
      restore_env(:normal_media_conversation_byte_limit, old_conversation_limit)
      restore_env(:normal_media_global_byte_limit, old_global_limit)
    end)

    :ok
  end

  test "default item limit accepts just under and exact 5 MiB and rejects one byte over" do
    runtime = live_conversation()
    exact = :binary.copy(<<0x41>>, @item_limit)
    under = binary_part(exact, 0, @item_limit - 1)
    over = exact <> <<0x42>>

    assert NormalMediaStore.max_item_bytes() == @item_limit
    assert_created(runtime, under)
    assert_created(runtime, exact)

    assert {:error, :normal_media_too_large} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               Ecto.UUID.generate(),
               over,
               metadata(over)
             )

    state = NormalMediaStore.inspect_state()
    assert state.conversation_bytes[runtime.conversation.conversation_id] == @item_limit * 2 - 1
    assert state.total_bytes == @item_limit * 2 - 1
  end

  test "default per-Conversation limit proves one byte under, exact 20 MiB, and one byte over" do
    runtime = live_conversation()
    exact_item = :binary.copy(<<0x51>>, @item_limit)
    almost_item = binary_part(exact_item, 0, @item_limit - 1)

    for _ <- 1..3, do: assert_created(runtime, exact_item)
    assert_created(runtime, almost_item)

    state = NormalMediaStore.inspect_state()
    assert state.conversation_bytes[runtime.conversation.conversation_id] == @conversation_limit - 1

    assert_created(runtime, <<0x52>>)

    state = NormalMediaStore.inspect_state()
    assert state.conversation_bytes[runtime.conversation.conversation_id] == @conversation_limit
    assert state.total_bytes == @conversation_limit

    rejected_id = Ecto.UUID.generate()

    assert {:error, :normal_media_conversation_capacity} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               rejected_id,
               <<0x53>>,
               metadata(<<0x53>>)
             )

    assert {:error, :media_unavailable} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, rejected_id)

    assert NormalMediaStore.inspect_state().total_bytes == @conversation_limit
  end

  test "default global limit reaches exactly 64 MiB, rejects one byte over, then reuses released capacity" do
    runtimes = for _ <- 1..4, do: live_conversation()
    exact_item = :binary.copy(<<0x61>>, @item_limit)
    four_mib = binary_part(exact_item, 0, 4_194_304)

    [first, second, third, fourth] = runtimes

    for runtime <- [first, second, third] do
      for _ <- 1..4, do: assert_created(runtime, exact_item)
    end

    assert_created(fourth, four_mib)
    assert NormalMediaStore.inspect_state().total_bytes == @global_limit

    blocked_id = Ecto.UUID.generate()

    assert {:error, :normal_media_global_capacity} =
             NormalMediaStore.put_media(
               fourth.conversation.conversation_id,
               fourth.a.participant_id,
               blocked_id,
               <<0x62>>,
               metadata(<<0x62>>)
             )

    assert NormalMediaStore.inspect_state().total_bytes == @global_limit

    assert :ok = NormalMediaStore.delete_conversation(first.conversation.conversation_id)
    assert NormalMediaStore.inspect_state().total_bytes == @global_limit - @conversation_limit

    assert_created(fourth, <<0x63>>)
    assert NormalMediaStore.inspect_state().total_bytes == @global_limit - @conversation_limit + 1
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

  defp assert_created(runtime, binary) do
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

  defp restore_env(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore_env(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
