defmodule StrangertalksNew.NormalMediaFailureIsolationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.NormalMediaStore

  setup do
    old_module = Application.get_env(:strangertalks_new, :normal_media_conversations_module)

    on_exit(fn ->
      if is_nil(old_module) do
        Application.delete_env(:strangertalks_new, :normal_media_conversations_module)
      else
        Application.put_env(:strangertalks_new, :normal_media_conversations_module, old_module)
      end
    end)

    :ok
  end

  test "temporary durable Conversation lookup failure cannot crash the store or erase active media" do
    runtime = live_conversation()
    media_id = put_media(runtime, "survive-db-outage")
    store_pid = Process.whereis(NormalMediaStore)
    before = NormalMediaStore.inspect_state()

    Application.put_env(
      :strangertalks_new,
      :normal_media_conversations_module,
      StrangertalksNew.TestFailingNormalMediaConversations
    )

    send(store_pid, :sweep_inactive)
    after_failed_sweep = NormalMediaStore.inspect_state()

    assert Process.whereis(NormalMediaStore) == store_pid
    assert Process.alive?(store_pid)
    assert after_failed_sweep.total_bytes == before.total_bytes
    assert after_failed_sweep.conversation_bytes == before.conversation_bytes

    assert {:ok, "survive-db-outage", "image/jpeg"} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, media_id)
  end

  test "invalid internal metadata is rejected without crashing the store or suspending ConversationServer" do
    runtime = live_conversation()
    store_pid = Process.whereis(NormalMediaStore)

    invalid_metadata = [
      %{content_hash: <<1, 2, 3>>},
      %{media_type: "image/jpeg"},
      %{content_hash: nil, media_type: "image/jpeg"},
      %{content_hash: :not_binary, media_type: "image/jpeg"},
      %{content_hash: <<0::256>>, media_type: nil},
      %{content_hash: <<0::256>>, media_type: :jpeg},
      %{content_hash: <<1, 2, 3>>, media_type: "image/jpeg"},
      %{content_hash: <<0::256>>, media_type: "text/html"}
    ]

    for {metadata, index} <- Enum.with_index(invalid_metadata) do
      assert {:error, :invalid_normal_media_metadata} =
               NormalMediaStore.put_media(
                 runtime.conversation.conversation_id,
                 runtime.a.participant_id,
                 Ecto.UUID.generate(),
                 "bad-metadata-#{index}",
                 metadata
               )
    end

    assert {:error, :invalid_normal_media_metadata} =
             NormalMediaStore.put_media(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               Ecto.UUID.generate(),
               "not-a-map",
               :not_a_map
             )

    assert Process.whereis(NormalMediaStore) == store_pid
    assert Process.alive?(store_pid)
    assert NormalMediaStore.inspect_state().total_bytes == 0
    assert NormalMediaStore.inspect_state().conversation_bytes == %{}

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               runtime.conversation.conversation_id,
               runtime.a.participant_id,
               Ecto.UUID.generate(),
               "text remains healthy"
             )
  end

  test "malformed Conversation runtime state cannot crash the media store or remain suspended" do
    runtime = live_conversation()
    existing_id = put_media(runtime, "unrelated-media")
    before = NormalMediaStore.inspect_state()
    store_pid = Process.whereis(NormalMediaStore)

    malformed_conversation_id = Ecto.UUID.generate()

    owner_pid =
      start_supervised!({StrangertalksNew.TestMalformedNormalMediaOwner, malformed_conversation_id})

    assert :pong = GenServer.call(owner_pid, :ping, 1_000)

    binary = "malformed-runtime"

    assert {:error, :conversation_unavailable} =
             NormalMediaStore.put_media(
               malformed_conversation_id,
               runtime.a.participant_id,
               Ecto.UUID.generate(),
               binary,
               %{
                 media_type: "image/jpeg",
                 width: 1,
                 height: 1,
                 content_hash: :crypto.hash(:sha256, binary)
               }
             )

    assert Process.whereis(NormalMediaStore) == store_pid
    assert Process.alive?(store_pid)
    assert :pong = GenServer.call(owner_pid, :ping, 1_000)

    after_failure = NormalMediaStore.inspect_state()
    assert after_failure.total_bytes == before.total_bytes
    assert after_failure.conversation_bytes == before.conversation_bytes

    assert {:ok, "unrelated-media", "image/jpeg"} =
             NormalMediaStore.fetch_media(runtime.conversation.conversation_id, existing_id)
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
               %{
                 media_type: "image/jpeg",
                 width: 1,
                 height: 1,
                 content_hash: :crypto.hash(:sha256, binary)
               }
             )

    id
  end
end
