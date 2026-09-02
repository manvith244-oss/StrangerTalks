defmodule StrangertalksNew.ConversationPresenceTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  defp create_active_conversation do
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

    {:ok, pid} =
      start_supervised(
        {ConversationServer,
         %{
           conversation_id: conversation.conversation_id,
           participant_a_id: conversation.participant_a_id,
           participant_b_id: conversation.participant_b_id,
           door_type: conversation.door_type
         }}
      )

    {conversation, pid}
  end

  describe "1F Aggregation Matrix" do
    test "single visible session derives to connected" do
      {conv, _pid} = create_active_conversation()
      session_pid = self()

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid,
          :visible
        )

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "single unknown session derives to connected" do
      {conv, _pid} = create_active_conversation()
      session_pid = self()

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid
        )

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "single hidden session derives to away" do
      {conv, _pid} = create_active_conversation()
      session_pid = self()

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid,
          :hidden
        )

      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "multi-session: visible + hidden derives to connected" do
      {conv, _pid} = create_active_conversation()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)
      session2 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session2)

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session1,
          :visible
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :hidden
        )

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "multi-session: unknown + hidden derives to connected" do
      {conv, _pid} = create_active_conversation()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)
      session2 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session2)

      # session1 remains :unknown
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :hidden
        )

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "multi-session: hidden + hidden derives to away" do
      {conv, _pid} = create_active_conversation()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)
      session2 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session2)

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session1,
          :hidden
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :hidden
        )

      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "zero active sessions derives to nil (no indicator)" do
      {conv, _pid} = create_active_conversation()

      assert {:ok, nil} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end
  end

  describe "Session lifecycle and exact PID tracking" do
    test "exact PID unregister leaves sibling session active and authoritative" do
      {conv, _pid} = create_active_conversation()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)
      session2 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session2)

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session1,
          :visible
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :hidden
        )

      # Unregister visible session1 -> remaining session2 is hidden -> derives to away
      :ok =
        ConversationServer.unregister_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session1
        )

      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "unregistered / stale session cannot update visibility" do
      {conv, _pid} = create_active_conversation()
      stale_session = spawn_link(fn -> Process.sleep(:infinity) end)

      assert {:error, :invalid_session} =
               ConversationServer.update_session_visibility(
                 conv.conversation_id,
                 conv.participant_a_id,
                 stale_session,
                 :visible
               )
    end

    test "replacement session does not inherit old session hidden visibility and stale session mutations fail" do
      {conv, _pid} = create_active_conversation()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session1,
          :hidden
        )

      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )

      # Old session disappears
      :ok =
        ConversationServer.unregister_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session1
        )

      assert {:ok, nil} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )

      # Replacement session joins -> starts with independent truth (:unknown -> "connected"), NOT inheriting old session's :hidden
      session2 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session2)

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )

      # Stale old session mutation cannot alter replacement session or participant presence
      assert {:error, :invalid_session} =
               ConversationServer.update_session_visibility(
                 conv.conversation_id,
                 conv.participant_a_id,
                 session1,
                 :hidden
               )

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "hidden reconnect initialization starts independent and updates immediately upon report" do
      {conv, _pid} = create_active_conversation()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session1,
          :hidden
        )

      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )

      # Session disconnects
      :ok =
        ConversationServer.unregister_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session1
        )

      # Rejoined session joins -> starts independent (:unknown -> "connected")
      session_rejoin = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session_rejoin
        )

      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )

      # Rejoined session immediately reports hidden document.visibilityState
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session_rejoin,
          :hidden
        )

      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_a_id
               )
    end

    test "duplicate visibility update returns no_op" do
      {conv, _pid} = create_active_conversation()
      session_pid = self()

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session_pid,
          :hidden
        )

      assert {:ok, :no_op} =
               ConversationServer.update_session_visibility(
                 conv.conversation_id,
                 conv.participant_a_id,
                 session_pid,
                 :hidden
               )
    end

    test "fanout occurs only when derived participant presence changes" do
      {conv, _pid} = create_active_conversation()
      peer_receiver = self()
      session1 = spawn_link(fn -> Process.sleep(:infinity) end)
      session2 = spawn_link(fn -> Process.sleep(:infinity) end)

      # Register peer B so it can receive presence messages
      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_b_id,
          peer_receiver
        )

      assert_receive {:conversation_presence, %{status: nil}}

      # Register session 1 for A (status becomes connected)
      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session1)

      assert_receive {:conversation_presence, %{status: "connected"}}

      # Register session 2 for A (derived presence remains connected -> NO fanout to peer)
      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_a_id, session2)

      refute_receive {:conversation_presence, _}, 100

      # Set session 2 to visible (derived presence remains connected -> NO fanout)
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :visible
        )

      refute_receive {:conversation_presence, _}, 100

      # Set session 1 to hidden (session 2 is visible -> derived presence remains connected -> NO fanout)
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session1,
          :hidden
        )

      refute_receive {:conversation_presence, _}, 100

      # Set session 2 to hidden (all sessions hidden -> derived presence changes to away -> fanout!)
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :hidden
        )

      assert_receive {:conversation_presence, %{status: "away"}}

      # Set session 2 back to hidden -> duplicate -> no_op -> NO fanout
      {:ok, :no_op} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session2,
          :hidden
        )

      refute_receive {:conversation_presence, _}, 100
    end
  end

  describe "Snapshots and sync reconciliation" do
    test "joining channel receives initial presence snapshot of peer" do
      {conv, _pid} = create_active_conversation()
      session_a = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          session_a
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_a_id,
          session_a,
          :hidden
        )

      # Participant B joins -> receives snapshot of A as "away"
      :ok =
        ConversationServer.register_channel(conv.conversation_id, conv.participant_b_id, self())

      assert_receive {:conversation_presence, %{status: "away"}}
    end

    test "get_messages_after / sync:reconcile returns peer_presence" do
      {conv, _pid} = create_active_conversation()
      session_b = spawn_link(fn -> Process.sleep(:infinity) end)

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_b_id,
          session_b
        )

      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_b_id,
          session_b,
          :visible
        )

      {:ok, sync_payload} =
        ConversationServer.get_messages_after(conv.conversation_id, conv.participant_a_id, 0)

      assert sync_payload.peer_presence == "connected"
    end
  end

  describe "Delivery Separation (Presence NEVER establishes message delivery)" do
    test "presence transitions do NOT transition message from sent to delivered" do
      {conv, _pid} = create_active_conversation()
      sender_pid = self()
      session_b = spawn_link(fn -> Process.sleep(:infinity) end)

      # 1. Registered sender ConversationChannel PID
      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_a_id,
          sender_pid
        )

      # 2. Registered recipient ConversationChannel PID + session join
      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_b_id,
          session_b
        )

      # A sends a message -> initial status :sent
      msg_id = Ecto.UUID.generate()

      {:ok, msg} =
        ConversationServer.append_message(
          conv.conversation_id,
          conv.participant_a_id,
          msg_id,
          "Hello peer"
        )

      assert msg.status == "sent"

      assert_sent = fn ->
        {:ok, st} = ConversationServer.inspect_state(conv.conversation_id)
        m = Enum.find(st.recent_messages, &(&1.message_id == msg_id))
        assert m.delivery_status == :sent
      end

      assert_sent.()

      # 3. Connected state (initial state when recipient registered)
      assert {:ok, "connected"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_b_id
               )

      assert_sent.()

      # 4. Visibility visible
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_b_id,
          session_b,
          :visible
        )

      assert_sent.()

      # 5. Visibility hidden
      {:ok, :applied} =
        ConversationServer.update_session_visibility(
          conv.conversation_id,
          conv.participant_b_id,
          session_b,
          :hidden
        )

      assert_sent.()

      # 6. Temporarily away state
      assert {:ok, "away"} =
               ConversationServer.get_participant_presence(
                 conv.conversation_id,
                 conv.participant_b_id
               )

      assert_sent.()

      # 7. Presence fanout
      assert_receive {:conversation_presence, %{status: "away"}}
      assert_sent.()

      # 8. Local Reconnecting… / session unregister
      :ok =
        ConversationServer.unregister_channel(
          conv.conversation_id,
          conv.participant_b_id,
          session_b
        )

      assert_sent.()

      # 9. Session return (rejoin) + 10. Visibility unknown
      session_b2 = self()

      :ok =
        ConversationServer.register_channel(
          conv.conversation_id,
          conv.participant_b_id,
          session_b2
        )

      assert_sent.()

      # 11. Presence snapshot via get_messages_after
      {:ok, sync_payload} =
        ConversationServer.get_messages_after(conv.conversation_id, conv.participant_a_id, 0)

      assert sync_payload.peer_presence == "connected"
      assert_sent.()

      # SOLE DELIVERED AUTHORITY: authenticated recipient applied-progress report
      {:ok, state} = ConversationServer.inspect_state(conv.conversation_id)

      {:ok, result} =
        ConversationServer.report_delivery_progress(
          conv.conversation_id,
          conv.participant_b_id,
          session_b2,
          state.epoch_id,
          1
        )

      assert result.highest_contiguous_sequence == 1
      assert result.status == "applied"

      {:ok, state_after} = ConversationServer.inspect_state(conv.conversation_id)
      stored_msg_after = Enum.find(state_after.recent_messages, &(&1.message_id == msg_id))
      assert stored_msg_after.delivery_status == :delivered
    end
  end
end
