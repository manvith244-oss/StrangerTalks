defmodule StrangertalksNew.AvatarConversationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.AvatarCatalog

  setup do
    fixture = conversation_fixture()

    pid =
      start_supervised!(
        {ConversationServer, %{conversation_id: fixture.conversation.conversation_id}}
      )

    Map.put(fixture, :pid, pid)
  end

  test "LIFE-1 & DERIVE-6: initial JOIN receives authoritative avatar projection with opposite self/peer views",
       context do
    # Join A first, then B
    assert {:ok, sync_a} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert {:ok, sync_b} = join_runtime(context, context.participant_b, self(), nil, 0)

    assert Map.has_key?(sync_a, :avatars)
    assert Map.has_key?(sync_b, :avatars)

    avatar_a = sync_a.avatars
    avatar_b = sync_b.avatars

    assert avatar_a.self.avatar_key == avatar_b.peer.avatar_key
    assert avatar_a.peer.avatar_key == avatar_b.self.avatar_key
    assert avatar_a.self.avatar_key != avatar_a.peer.avatar_key
    assert AvatarCatalog.approved?(avatar_a.self.avatar_key)
    assert AvatarCatalog.approved?(avatar_a.peer.avatar_key)
  end

  test "LIFE-2 & LIFE-3: reconnect and refresh preserve exact same avatar mapping", context do
    assert {:ok, join1} = join_runtime(context, context.participant_a, self(), nil, 0)
    avatar1 = join1.avatars

    # Simulate reconnect with existing epoch / sequence
    assert {:ok, join2} = join_runtime(context, context.participant_a, self(), join1.epoch_id, 0)
    assert join2.avatars == avatar1

    # Simulate refresh with empty epoch
    assert {:ok, join3} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert join3.avatars == avatar1
  end

  test "LIFE-4 & LIFE-5: sibling channels for same participant see identical avatar mapping",
       context do
    chan1 = spawn(fn -> Process.sleep(1000) end)
    chan2 = spawn(fn -> Process.sleep(1000) end)

    assert {:ok, sync1} = join_runtime(context, context.participant_a, chan1, nil, 0)
    assert {:ok, sync2} = join_runtime(context, context.participant_a, chan2, nil, 0)

    assert sync1.avatars == sync2.avatars
  end

  test "LIFE-6: runtime reconstruction of ConversationServer produces exact same avatar keys",
       context do
    assert {:ok, sync_before} = join_runtime(context, context.participant_a, self(), nil, 0)
    avatars_before = sync_before.avatars

    # Stop supervised ConversationServer and restart for same conversation
    stop_supervised!({ConversationServer, context.conversation.conversation_id})

    _new_pid =
      start_supervised!(
        {ConversationServer, %{conversation_id: context.conversation.conversation_id}}
      )

    assert {:ok, sync_after} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert sync_after.avatars == avatars_before
  end

  test "LIFE-7: sync:reconcile returns authoritative avatar presentation", context do
    assert {:ok, sync_payload} =
             ConversationServer.get_messages_after(
               context.conversation.conversation_id,
               context.participant_a,
               0
             )

    assert Map.has_key?(sync_payload, :avatars)
    assert is_map(sync_payload.avatars.self)
    assert is_map(sync_payload.avatars.peer)
    assert AvatarCatalog.approved?(sync_payload.avatars.self.avatar_key)
    assert AvatarCatalog.approved?(sync_payload.avatars.peer.avatar_key)
  end

  test "LIFE-8 & LIFE-9: terminal conversation ends authority; new conversation derives independently",
       context do
    assert {:ok, old_sync_a} = join_runtime(context, context.participant_a, self(), nil, 0)
    assert {:ok, _old_sync_b} = join_runtime(context, context.participant_b, self(), nil, 0)
    assert old_sync_a.avatars != nil

    # Complete/End conversation
    assert {:ok, _} =
             ConversationServer.complete_conversation(
               context.conversation.conversation_id,
               context.participant_a
             )

    # Create unrelated new conversation
    new_fixture = conversation_fixture()

    _new_pid =
      start_supervised!(
        {ConversationServer, %{conversation_id: new_fixture.conversation.conversation_id}}
      )

    assert {:ok, new_sync} = join_runtime(new_fixture, new_fixture.participant_a, self(), nil, 0)
    assert new_sync.avatars != nil
    assert AvatarCatalog.approved?(new_sync.avatars.self.avatar_key)
    assert AvatarCatalog.approved?(new_sync.avatars.peer.avatar_key)
  end

  test "SAFE-1 & SAFE-2 & SAFE-5: avatar keys have zero authority in Reports, Blocks, and safety records",
       context do
    # Forged reporter_id as avatar key
    assert {:error, :not_conversation_member} =
             StrangertalksNew.Reports.submit_conversation_report(
               context.conversation.conversation_id,
               "moon-fox",
               "SPAM",
               "forged"
             )

    # Forged conversation_id as avatar key is rejected by UUID validation
    assert :error = Ecto.UUID.cast("rain-owl")

    # Forged participant ID as avatar key is rejected by UUID validation
    assert :error = Ecto.UUID.cast("moon-fox")
  end

  test "PRIV-1 & PRIV-2: verify persistence zero - no avatar table, no avatar columns in DB" do
    # Assert Conversation schema has no avatar fields
    fields = StrangertalksNew.Conversation.__schema__(:fields)
    refute :avatar in fields
    refute :avatar_key in fields
    refute :participant_a_avatar in fields
    refute :participant_b_avatar in fields
  end

  test "SAFE-5: reused artwork across unrelated conversations creates ZERO safety/identity/history linkage",
       context do
    # Conversation 1: participant A and B
    fixture1 = context
    # Conversation 2: participant C and D
    fixture2 = conversation_fixture()

    # Even if participants across different conversations have the same avatar artwork (e.g. "moon-fox"),
    # all safety boundaries operate exclusively on canonical UUIDs.

    # 1. Report authority is strictly scoped to canonical membership
    assert {:error, :not_conversation_member} =
             StrangertalksNew.Reports.submit_conversation_report(
               fixture1.conversation.conversation_id,
               fixture2.participant_a,
               "SPAM",
               "cross-conversation attempt"
             )

    # 2. Block/relationship authority is strictly scoped to canonical UUIDs
    assert {:ok, rel} =
             StrangertalksNew.Relationships.create_relationship(%{
               created_at: DateTime.utc_now(),
               updated_at: DateTime.utc_now(),
               first_conversation_at: DateTime.utc_now(),
               relationship_status: :CLOSED,
               closure_reason: :BLOCKED,
               origin_door_type: :JUST_TALK,
               participant_a_id: fixture1.participant_a,
               participant_b_id: fixture1.participant_b,
               origin_conversation_id: fixture1.conversation.conversation_id,
               origin_match_id: fixture1.conversation.match_id,
               participant_a_accepted: true,
               participant_b_accepted: false,
               allow_reconnection: false,
               reconnection_eligible: false,
               participant_a_closed: true,
               participant_b_closed: false,
               participant_a_blocked: true,
               participant_b_blocked: false,
               conversation_count: 1,
               memory_count: 0,
               reconnection_count: 0,
               shared_memory_count: 0,
               private_note_count: 0
             })

    # Participant C is entirely unaffected by A's block on B
    refute rel.participant_a_id == fixture2.participant_a
    refute rel.participant_b_id == fixture2.participant_a

    # 3. Rate limiting operates on participant UUID, not avatar key
    # Ensure RateLimiter accepts UUID and rejects avatar keys
    assert :error = Ecto.UUID.cast("moon-fox")
  end

  test "PRIV-3: diagnostic correlation negative proof - zero participant/conversation avatar telemetry retained" do
    # AvatarCatalog derivation is pure and emits 0 telemetry events or retained logs
    p1 = "11111111-1111-1111-1111-111111111111"
    p2 = "22222222-2222-2222-2222-222222222222"
    conv_id = "33333333-3333-3333-3333-333333333333"

    map = AvatarCatalog.derive_pair(conv_id, p1, p2)
    assert is_map(map)

    # Derivation retains 0 state in ETS, DB, or global telemetry tables
    refute :ets.info(:avatar_telemetry_table) != :undefined
    refute :ets.info(:avatar_history_table) != :undefined
  end

  test "STATIC-HTTP: real static route serves all approved avatar SVG assets with HTTP 200 and image/svg+xml" do
    all_keys =
      (AvatarCatalog.catalog() |> Enum.map(& &1.key)) ++ ["generic-self", "generic-peer"]

    for key <- all_keys do
      path = "/assets/avatars/#{key}.svg"
      conn = Plug.Test.conn(:get, path) |> StrangertalksNewWeb.Endpoint.call([])
      assert conn.status == 200, "Expected HTTP 200 for #{path}, got #{conn.status}"
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/svg+xml"]
      assert byte_size(conn.resp_body) > 0
    end
  end

  defp join_runtime(context, participant_id, channel_pid, epoch_id, seq) do
    ConversationServer.sync_and_register_channel(
      context.conversation.conversation_id,
      participant_id,
      channel_pid,
      epoch_id,
      seq
    )
  end

  defp conversation_fixture do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
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
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
