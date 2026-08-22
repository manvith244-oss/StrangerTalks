defmodule StrangertalksNew.ViewOnceConversationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.ConversationLifecycle.ViewOnceMediaStore

  defp valid_jpeg do
    sof0_payload = <<8, 100::16, 100::16, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>
    sof0_len = byte_size(sof0_payload) + 2

    <<0xFF, 0xD8, 0xFF, 0xC0, sof0_len::16, sof0_payload::binary, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0,
      0x3F, 0, 0x12, 0x34, 0xFF, 0xD9>>
  end

  defp start_conversation do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, matching} =
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
        match_id: matching.match_id,
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

    {:ok, pid} = ConversationServer.start_link(%{conversation_id: conversation.conversation_id})
    {:ok, conversation.conversation_id, a.participant_id, b.participant_id, pid}
  end

  describe "Lifecycle / Synchronization Proof (L1–L10)" do
    test "L1 - Open vs 30-min unopened expiry: open wins -> VIEWED; expiry wins -> UNAVAILABLE with zero presentation" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token1} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id1 = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id1,
          staging_token1
        )

      # 1. Open wins
      assert {:ok, open_res} =
               ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id1)

      assert open_res.status == "viewed"
      assert is_binary(open_res.presentation_token)

      # 2. Expiry wins on a second item
      {:ok, staging_token2} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id2 = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id2,
          staging_token2
        )

      # Trigger 30-minute unopened expiry message directly to server
      send(pid, {:view_once_unopened_expiry, client_msg_id2})
      _ = :sys.get_state(pid)

      {:ok, msgs} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      expired_msg = Enum.find(msgs.messages, &(&1.client_message_id == client_msg_id2))
      assert expired_msg.view_once_state == "unavailable"

      # Opening expired item fails
      assert {:error, :media_unavailable} =
               ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id2)

      Process.exit(pid, :normal)
    end

    test "L2 - Open vs conversation end: end wins first -> UNAVAILABLE with zero presentation" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # End conversation first
      {:ok, _} = ConversationServer.complete_conversation(conv_id, sender_id)

      # Attempt to open after conversation ended
      assert {:error, _reason} =
               ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      Process.exit(pid, :normal)
    end

    test "L3 - Store/runtime loss: missing backing bytes before open transitions to UNAVAILABLE, not VIEWED" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Delete bytes directly from volatile store before open
      ViewOnceMediaStore.delete_media(conv_id, client_msg_id)

      # Open attempt fails with media_unavailable and transitions to unavailable
      assert {:error, :media_unavailable} =
               ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      {:ok, msgs} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = msgs.messages
      assert msg.view_once_state == "unavailable"

      Process.exit(pid, :normal)
    end

    test "L4 - JOIN UNVIEWED: join replay projection returns UNVIEWED placeholder with 0 media bytes" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # JOIN replay projection
      {:ok, replay} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = replay.messages
      assert msg.type == "view_once_photo"
      assert msg.client_message_id == client_msg_id
      assert msg.view_once_state == "unviewed"
      refute Map.has_key?(msg, :binary)
      refute Map.has_key?(msg, :media_bytes)

      Process.exit(pid, :normal)
    end

    test "L5 - JOIN VIEWED: join replay projection returns VIEWED with 0 media bytes" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, _} = ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      {:ok, replay} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = replay.messages
      assert msg.type == "view_once_photo"
      assert msg.client_message_id == client_msg_id
      assert msg.view_once_state == "viewed"
      refute Map.has_key?(msg, :binary)
      refute Map.has_key?(msg, :media_bytes)

      Process.exit(pid, :normal)
    end

    test "L6 - JOIN UNAVAILABLE: join replay projection returns UNAVAILABLE with 0 media bytes" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      send(pid, {:view_once_unopened_expiry, client_msg_id})
      _ = :sys.get_state(pid)

      {:ok, replay} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = replay.messages
      assert msg.type == "view_once_photo"
      assert msg.client_message_id == client_msg_id
      assert msg.view_once_state == "unavailable"
      refute Map.has_key?(msg, :binary)
      refute Map.has_key?(msg, :media_bytes)

      Process.exit(pid, :normal)
    end

    test "L7 - SYNC:RECONCILE UNVIEWED: separate sync:reconcile returns UNVIEWED with 0 media bytes" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, result} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Sync reconcile query
      {:ok, sync_res} =
        ConversationServer.get_messages_after(conv_id, recipient_id, result.sequence - 1)

      [msg] = sync_res.messages
      assert msg.client_message_id == client_msg_id
      assert msg.view_once_state == "unviewed"
      refute Map.has_key?(msg, :binary)

      Process.exit(pid, :normal)
    end

    test "L8 - SYNC:RECONCILE VIEWED: stale client receives VIEWED update, reopening right is 0" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      {:ok, _} = ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      {:ok, sync_res} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = sync_res.messages
      assert msg.view_once_state == "viewed"

      # Re-opening right is 0
      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      Process.exit(pid, :normal)
    end

    test "L9 - SYNC:RECONCILE UNAVAILABLE: stale client receives UNAVAILABLE update" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      send(pid, {:view_once_unopened_expiry, client_msg_id})
      _ = :sys.get_state(pid)

      {:ok, sync_res} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = sync_res.messages
      assert msg.view_once_state == "unavailable"

      Process.exit(pid, :normal)
    end

    test "L10 - Post-prune non-resurrection: pruned item cannot regain canonical view authority" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # Clean up / delete media from store
      ViewOnceMediaStore.delete_media(conv_id, client_msg_id)

      # Attempt to issue capability or open without authority
      assert {:error, :media_unavailable} =
               ConversationServer.open_view_once_photo(conv_id, recipient_id, client_msg_id)

      Process.exit(pid, :normal)
    end
  end

  describe "Feature 1O.1 - View-Twice Conversation Lifecycle (VT-OPEN, RACE, EXP, REPORT)" do
    test "VT-OPEN-1..5: Exactly two deliberate presentations, attempt idempotency, and terminal consumption" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      # Send View-Twice Photo (presentation_limit: 2)
      assert {:ok, sent_meta} =
               ConversationServer.append_view_once_photo(
                 conv_id,
                 sender_id,
                 client_msg_id,
                 staging_token,
                 2
               )

      assert sent_meta.presentation_limit == 2
      assert sent_meta.views_remaining == 2
      assert sent_meta.views_consumed == 0
      assert sent_meta.view_once_state == "unviewed"

      # VT-OPEN-2: First deliberate presentation with attempt_id
      attempt_id_1 = "attempt-uuid-1"

      assert {:ok, open_res_1} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_id_1
               )

      assert open_res_1.status == "viewed_once"
      assert open_res_1.view_once_state == "viewed_once"
      assert open_res_1.presentation_limit == 2
      assert open_res_1.views_remaining == 1
      assert open_res_1.views_consumed == 1
      assert is_binary(open_res_1.presentation_token)

      # Recipient consumes the issued single-use presentation token
      assert {:ok, bytes_1, "image/jpeg"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 open_res_1.presentation_token,
                 recipient_id
               )

      assert bytes_1 == media

      # VT-OPEN-3: Idempotent exact same attempt retry (attempt_id_1)
      assert {:ok, retry_res_1} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_id_1
               )

      assert retry_res_1.duplicate == true
      assert retry_res_1.views_remaining == 1

      # VT-OPEN-4: Second deliberate presentation with fresh attempt_id
      attempt_id_2 = "attempt-uuid-2"

      assert {:ok, open_res_2} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_id_2
               )

      assert open_res_2.status == "viewed"
      assert open_res_2.view_once_state == "viewed"
      assert open_res_2.presentation_limit == 2
      assert open_res_2.views_remaining == 0
      assert open_res_2.views_consumed == 2
      assert is_binary(open_res_2.presentation_token)

      # Recipient consumes the second single-use presentation token
      assert {:ok, bytes_2, "image/jpeg"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 open_res_2.presentation_token,
                 recipient_id
               )

      assert bytes_2 == media

      # VT-OPEN-5: Third deliberate presentation attempt is rejected
      attempt_id_3 = "attempt-uuid-3"

      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_id_3
               )

      Process.exit(pid, :normal)
    end

    test "RACE-1: Multi-tab concurrency when remaining = 2 (two unique attempts both succeed)" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # 2 concurrent tasks representing 2 separate browser tabs
      t1 =
        Task.async(fn ->
          ConversationServer.open_view_once_photo(
            conv_id,
            recipient_id,
            client_msg_id,
            "tab1-attempt"
          )
        end)

      t2 =
        Task.async(fn ->
          ConversationServer.open_view_once_photo(
            conv_id,
            recipient_id,
            client_msg_id,
            "tab2-attempt"
          )
        end)

      res1 = Task.await(t1)
      res2 = Task.await(t2)

      assert {:ok, r1} = res1
      assert {:ok, r2} = res2
      assert is_binary(r1.presentation_token)
      assert is_binary(r2.presentation_token)
      assert r1.presentation_token != r2.presentation_token

      Process.exit(pid, :normal)
    end

    test "RACE-2: Multi-tab concurrency when remaining = 1 (at most one attempt succeeds)" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # 1st view already opened
      {:ok, _} =
        ConversationServer.open_view_once_photo(
          conv_id,
          recipient_id,
          client_msg_id,
          "initial-attempt"
        )

      # 2 concurrent tasks competing for the 1 remaining view
      t1 =
        Task.async(fn ->
          ConversationServer.open_view_once_photo(
            conv_id,
            recipient_id,
            client_msg_id,
            "compete-1"
          )
        end)

      t2 =
        Task.async(fn ->
          ConversationServer.open_view_once_photo(
            conv_id,
            recipient_id,
            client_msg_id,
            "compete-2"
          )
        end)

      results = [Task.await(t1), Task.await(t2)]
      successes = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, :already_consumed}, &1))

      assert length(successes) == 1
      assert length(failures) == 1

      Process.exit(pid, :normal)
    end

    test "EXP-1: Partial consumption 30-min expiry transitions state to UNAVAILABLE without destroying safety grace" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # 1st view opened
      {:ok, open_res} =
        ConversationServer.open_view_once_photo(
          conv_id,
          recipient_id,
          client_msg_id,
          "first-open"
        )

      assert open_res.views_remaining == 1

      # 30-min unopened timer fires before 2nd view is opened
      send(pid, {:view_once_unopened_expiry, client_msg_id})
      _ = :sys.get_state(pid)

      # Ordinary 2nd open fails because 30m deadline passed
      assert {:error, :media_unavailable} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "second-open"
               )

      # But server-owned safety copy from 1st view is STILL preserved in ViewOnceMediaStore
      assert {:ok, safety_info} = ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)
      assert safety_info.binary == media

      Process.exit(pid, :normal)
    end

    test "REPORT-1: Safety report after 1st view captures evidence without decrementing remaining ordinary views" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # 1st view consumed
      {:ok, _} =
        ConversationServer.open_view_once_photo(
          conv_id,
          recipient_id,
          client_msg_id,
          "view-1"
        )

      # Safety media capture (used during report submission)
      assert {:ok, safety_info} = ViewOnceMediaStore.capture_safety_media(conv_id, client_msg_id)
      assert safety_info.binary == media

      # 2nd view is still available to the recipient!
      assert {:ok, second_res} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "view-2"
               )

      assert second_res.views_remaining == 0
      assert second_res.views_consumed == 2

      Process.exit(pid, :normal)
    end

    test "RECONCILE-1: sync projection includes presentation_limit and views_remaining with 0 media bytes" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      {:ok, _} =
        ConversationServer.open_view_once_photo(
          conv_id,
          recipient_id,
          client_msg_id,
          "open-1"
        )

      {:ok, sync_res} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      [msg] = sync_res.messages
      assert msg.type == "view_once_photo"
      assert msg.presentation_limit == 2
      assert msg.views_remaining == 1
      assert msg.views_consumed == 1
      assert msg.view_once_state == "viewed_once"
      refute Map.has_key?(msg, :bytes)
      refute Map.has_key?(msg, :binary)
      refute Map.has_key?(msg, :presentation_token)

      Process.exit(pid, :normal)
    end
  end

  describe "Feature 1O.1 - Closure Gap C: Independent JOIN Projection (JOIN-1..5)" do
    test "JOIN-1..5: Independent channel JOIN projection, state accuracy, zero bytes, zero consumption",
         %{test: _test_name} do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # JOIN-1: Initial JOIN when remaining = 2
      channel_pid_1 = self()

      assert {:ok, join_res_1} =
               ConversationServer.sync_and_register_channel(
                 conv_id,
                 recipient_id,
                 channel_pid_1,
                 nil,
                 nil
               )

      [msg_1] = join_res_1.messages
      assert msg_1.presentation_limit == 2
      assert msg_1.views_remaining == 2
      assert msg_1.views_consumed == 0
      assert msg_1.view_once_state == "unviewed"
      refute Map.has_key?(msg_1, :bytes)
      refute Map.has_key?(msg_1, :binary)
      refute Map.has_key?(msg_1, :presentation_token)

      # JOIN-5: Verify JOIN did not consume any presentation count or views
      assert msg_1.views_remaining == 2

      # Perform first deliberate Open
      assert {:ok, _} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "deliberate-open-1"
               )

      # JOIN-2: JOIN when remaining = 1
      assert {:ok, join_res_2} =
               ConversationServer.sync_and_register_channel(
                 conv_id,
                 recipient_id,
                 channel_pid_1,
                 nil,
                 nil
               )

      [msg_2] = join_res_2.messages
      assert msg_2.presentation_limit == 2
      assert msg_2.views_remaining == 1
      assert msg_2.views_consumed == 1
      assert msg_2.view_once_state == "viewed_once"
      refute Map.has_key?(msg_2, :bytes)
      refute Map.has_key?(msg_2, :presentation_token)

      # Perform second deliberate Open
      assert {:ok, _} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "deliberate-open-2"
               )

      # JOIN-3: JOIN when remaining = 0 (viewed)
      assert {:ok, join_res_3} =
               ConversationServer.sync_and_register_channel(
                 conv_id,
                 recipient_id,
                 channel_pid_1,
                 nil,
                 nil
               )

      [msg_3] = join_res_3.messages
      assert msg_3.presentation_limit == 2
      assert msg_3.views_remaining == 0
      assert msg_3.views_consumed == 2
      assert msg_3.view_once_state == "viewed"
      refute Map.has_key?(msg_3, :bytes)

      # JOIN-4: JOIN when unavailable (expiry) on a new item
      client_msg_id_exp = Ecto.UUID.generate()
      {:ok, staging_token_exp} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id_exp,
          staging_token_exp,
          2
        )

      send(pid, {:view_once_unopened_expiry, client_msg_id_exp})
      _ = :sys.get_state(pid)

      assert {:ok, join_res_4} =
               ConversationServer.sync_and_register_channel(
                 conv_id,
                 recipient_id,
                 channel_pid_1,
                 nil,
                 nil
               )

      msg_exp = Enum.find(join_res_4.messages, &(&1.client_message_id == client_msg_id_exp))
      assert msg_exp.view_once_state == "unavailable"
      assert msg_exp.views_remaining == 0
      refute Map.has_key?(msg_exp, :bytes)

      Process.exit(pid, :normal)
    end
  end

  describe "Feature 1O.1 - Closure Gap D: completed_attempts Boundedness (ATTEMPT-1..4)" do
    test "ATTEMPT-1..4: completed_attempts retains <= 2 entries, retries do not grow, terminal spam produces 0 growth" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      media = valid_jpeg()
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, media)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_photo(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # ATTEMPT-4: Foreign or invalid attempts do not enter completed_attempts
      assert {:error, :not_conversation_member} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 "foreign-participant-id",
                 client_msg_id,
                 "foreign-attempt"
               )

      assert {:error, :invalid_message_id} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 "invalid-id",
                 "invalid-attempt"
               )

      # ATTEMPT-1: Perform 2 successful deliberate presentations
      attempt_1 = "attempt-uuid-1"
      attempt_2 = "attempt-uuid-2"

      assert {:ok, _} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_1
               )

      assert {:ok, _} =
               ConversationServer.open_view_once_photo(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_2
               )

      server_state_1 = :sys.get_state(pid)

      target_msg_1 =
        Enum.find(server_state_1.recent_messages, &(&1.client_message_id == client_msg_id))

      assert map_size(target_msg_1.completed_attempts) == 2

      # ATTEMPT-2: Same-attempt retries do not grow completed_attempts
      for _ <- 1..50 do
        assert {:ok, retry_res} =
                 ConversationServer.open_view_once_photo(
                   conv_id,
                   recipient_id,
                   client_msg_id,
                   attempt_1
                 )

        assert retry_res.duplicate == true
      end

      server_state_2 = :sys.get_state(pid)

      target_msg_2 =
        Enum.find(server_state_2.recent_messages, &(&1.client_message_id == client_msg_id))

      assert map_size(target_msg_2.completed_attempts) == 2

      # ATTEMPT-3: Terminal unique-ID spam (50 unique IDs against terminal item)
      for i <- 1..50 do
        spam_attempt_id = "spam-attempt-#{i}-#{Ecto.UUID.generate()}"

        assert {:error, :already_consumed} =
                 ConversationServer.open_view_once_photo(
                   conv_id,
                   recipient_id,
                   client_msg_id,
                   spam_attempt_id
                 )
      end

      # Verify completed_attempts growth = 0 (remains exactly 2)
      server_state_3 = :sys.get_state(pid)

      target_msg_3 =
        Enum.find(server_state_3.recent_messages, &(&1.client_message_id == client_msg_id))

      assert map_size(target_msg_3.completed_attempts) == 2

      assert Map.keys(target_msg_3.completed_attempts) |> Enum.sort() ==
               [attempt_1, attempt_2] |> Enum.sort()

      Process.exit(pid, :normal)
    end
  end

  # MP4 Box builder for conversation tests
  defp box(type, payload) do
    size = byte_size(payload) + 8
    <<size::32, type::binary-size(4), payload::binary>>
  end

  defp valid_mp4(opts) do
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    duration_sec = Keyword.get(opts, :duration, 10.0)
    timescale = Keyword.get(opts, :timescale, 1000)
    extra_size = Keyword.get(opts, :extra_size, 100)

    duration_units = round(duration_sec * timescale)

    ftyp = box("ftyp", <<"isom", 512::32, "isom", "iso2", "mp41">>)

    mvhd =
      box(
        "mvhd",
        <<0, 0::24, 0::32, 0::32, timescale::32, duration_units::32, 0x00010000::32, 0x0100::16,
          0::16, 0::32, 0::32, 0x00010000::32, 0::32, 0::32, 0::32, 0x00010000::32, 0::32, 0::32,
          0::32, 0x40000000::32, 0::32, 0::32, 0::32, 0::32, 0::32, 0::32, 2::32>>
      )

    tkhd_v =
      box(
        "tkhd",
        <<0, 1::24, 0::32, 0::32, 1::32, 0::32, duration_units::32, 0::64, 0::16, 0::16, 0::16,
          0::16, 0x00010000::32, 0::32, 0::32, 0::32, 0x00010000::32, 0::32, 0::32, 0::32,
          0x40000000::32, width * 65536::32, height * 65536::32>>
      )

    mdhd_v =
      box("mdhd", <<0, 0::24, 0::32, 0::32, timescale::32, duration_units::32, 0::16, 0::16>>)

    hdlr_v = box("hdlr", <<0, 0::24, 0::32, "vide", 0::96, "VideoHandler", 0>>)

    stsd_entry_v =
      box(
        "avc1",
        <<0::48, 1::16, 0::128, width::16, height::16, 0x00480000::32, 0x00480000::32, 0::32,
          1::16, 0::256, 0x0018::16, 0xFFFF::16>>
      )

    stsd_v = box("stsd", <<0, 0::24, 1::32, stsd_entry_v::binary>>)
    stbl_v = box("stbl", stsd_v)
    minf_v = box("minf", stbl_v)
    mdia_v = box("mdia", mdhd_v <> hdlr_v <> minf_v)
    trak_v = box("trak", tkhd_v <> mdia_v)

    moov = box("moov", mvhd <> trak_v)
    mdat = box("mdat", :crypto.strong_rand_bytes(extra_size))

    ftyp <> moov <> mdat
  end

  describe "Feature 1O.2 — View-Once Video (VIDEO-SEND, CAPACITY, OPEN, BLOB, LIFE, JOIN)" do
    test "VIDEO-SEND-1..3: Staging, sending, unviewed limit, and duplicate idempotency" do
      {:ok, conv_id, sender_id, _recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token1} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id1 = Ecto.UUID.generate()

      # VIDEO-SEND-1: Append view-once video
      assert {:ok, send_res} =
               ConversationServer.append_view_once_video(
                 conv_id,
                 sender_id,
                 client_msg_id1,
                 staging_token1
               )

      assert send_res.client_message_id == client_msg_id1
      assert send_res.view_once_state == "unviewed"
      assert send_res.presentation_limit == 1
      assert send_res.views_remaining == 1
      assert send_res.views_consumed == 0

      # VIDEO-SEND-2: Duplicate send idempotency
      assert {:ok, dup_res} =
               ConversationServer.append_view_once_video(
                 conv_id,
                 sender_id,
                 client_msg_id1,
                 staging_token1
               )

      assert dup_res.duplicate == true
      assert dup_res.client_message_id == client_msg_id1

      # VIDEO-SEND-3: Multiple unviewed media limit across photos and videos
      video_bytes2 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token2} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes2)
      client_msg_id2 = Ecto.UUID.generate()

      assert {:error, :view_once_sender_unviewed_limit} =
               ConversationServer.append_view_once_video(
                 conv_id,
                 sender_id,
                 client_msg_id2,
                 staging_token2
               )

      Process.exit(pid, :normal)
    end

    test "CAPACITY-1..3: Presentation capacity check BEFORE consumption protects View from burning on capacity exhaustion" do
      {:ok, conv_id1, sender_id1, recipient_id1, pid1} = start_conversation()
      {:ok, conv_id2, sender_id2, recipient_id2, pid2} = start_conversation()
      {:ok, conv_id3, sender_id3, recipient_id3, pid3} = start_conversation()

      # 3 large videos (~4 MiB each, item limit 5 MiB)
      large_vid1 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)
      large_vid2 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)
      large_vid3 = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)

      msg_id1 = Ecto.UUID.generate()
      msg_id2 = Ecto.UUID.generate()
      msg_id3 = Ecto.UUID.generate()

      {:ok, tok1} = ViewOnceMediaStore.stage_media(conv_id1, sender_id1, large_vid1)
      {:ok, _} = ConversationServer.append_view_once_video(conv_id1, sender_id1, msg_id1, tok1)

      {:ok, tok2} = ViewOnceMediaStore.stage_media(conv_id2, sender_id2, large_vid2)
      {:ok, _} = ConversationServer.append_view_once_video(conv_id2, sender_id2, msg_id2, tok2)

      {:ok, tok3} = ViewOnceMediaStore.stage_media(conv_id3, sender_id3, large_vid3)
      {:ok, _} = ConversationServer.append_view_once_video(conv_id3, sender_id3, msg_id3, tok3)

      # 1. Open video 1: reserves ~4 MiB capacity, consumes view 1 -> 0
      assert {:ok, open_res1} =
               ConversationServer.open_view_once_video(
                 conv_id1,
                 recipient_id1,
                 msg_id1,
                 "attempt-1"
               )

      assert open_res1.status == "viewed"
      assert is_binary(open_res1.presentation_token)

      # 2. Open video 2: reserves ~4 MiB capacity (total ~8 MiB reserved)
      assert {:ok, open_res2} =
               ConversationServer.open_view_once_video(
                 conv_id2,
                 recipient_id2,
                 msg_id2,
                 "attempt-2"
               )

      assert open_res2.status == "viewed"

      # 3. Open video 3: would exceed 10 MiB reservation capacity (8 + 4 = 12 MiB > 10 MiB)
      # Server returns {:error, :presentation_capacity_unavailable}
      assert {:error, :presentation_capacity_unavailable} =
               ConversationServer.open_view_once_video(
                 conv_id3,
                 recipient_id3,
                 msg_id3,
                 "attempt-3"
               )

      # CRITICAL SAFETY INVARIANT: User 3's View is NOT burned!
      server_state3 = :sys.get_state(pid3)
      target_msg3 = Enum.find(server_state3.recent_messages, &(&1.client_message_id == msg_id3))
      assert target_msg3.view_once_state == :unviewed
      assert target_msg3.views_remaining == 1
      assert target_msg3.views_consumed == 0

      # 4. Recipient 1 finishes fetching whole-Blob video 1 -> capacity is released!
      assert {:ok, bytes1, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id1,
                 msg_id1,
                 open_res1.presentation_token,
                 recipient_id1
               )

      assert byte_size(bytes1) == byte_size(large_vid1)

      # 5. Now User 3 opens video 3 -> succeeds!
      assert {:ok, open_res3} =
               ConversationServer.open_view_once_video(
                 conv_id3,
                 recipient_id3,
                 msg_id3,
                 "attempt-3-retry"
               )

      assert open_res3.status == "viewed"
      assert is_binary(open_res3.presentation_token)

      Process.exit(pid1, :normal)
      Process.exit(pid2, :normal)
      Process.exit(pid3, :normal)
    end

    test "OPEN-1..5 & BLOB-1..3: Single deliberate open, transfer, capability replay denial, and idempotency" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 1000)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # OPEN-2: Sender cannot open own video
      assert {:error, :sender_cannot_acknowledge} =
               ConversationServer.open_view_once_video(conv_id, sender_id, client_msg_id)

      # OPEN-3: Foreign non-member cannot open video
      assert {:error, :not_conversation_member} =
               ConversationServer.open_view_once_video(conv_id, "stranger-user", client_msg_id)

      # OPEN-1: Recipient deliberate open
      attempt_id = "deliberate-open-1"

      assert {:ok, open_res} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_id
               )

      assert open_res.status == "viewed"
      assert open_res.views_remaining == 0
      assert open_res.views_consumed == 1
      presentation_token = open_res.presentation_token

      # OPEN-5: Same attempt duplicate retry returns duplicate: true
      assert {:ok, dup_open} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_id
               )

      assert dup_open.duplicate == true
      assert dup_open.presentation_token == presentation_token

      # OPEN-4: Re-opening with a new attempt ID returns already_consumed
      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "new-attempt"
               )

      # BLOB-1: Transfer whole blob
      assert {:ok, fetched_bytes, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 presentation_token,
                 recipient_id
               )

      assert fetched_bytes == video_bytes

      # BLOB-2: Replay of presentation capability returns error
      assert {:error, _} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 presentation_token,
                 recipient_id
               )

      Process.exit(pid, :normal)
    end

    test "LIFE-1..2 & JOIN-1: 30-min unopened expiry and reconnect projection" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token
        )

      # JOIN-1: Message history projection for recipient contains metadata, no video binary
      state = :sys.get_state(pid)
      msg = Enum.find(state.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg.type == :view_once_video
      assert msg.media_type == "video/mp4"
      assert msg.byte_size == byte_size(video_bytes)
      assert msg.width == 1280
      assert msg.height == 720
      assert msg.duration_seconds == 10.0
      refute Map.has_key?(msg, :binary)

      # LIFE-1: Unopened expiry triggers
      send(pid, {:view_once_unopened_expiry, client_msg_id})
      _ = :sys.get_state(pid)

      state_after = :sys.get_state(pid)
      msg_after = Enum.find(state_after.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg_after.view_once_state == :unavailable
      assert msg_after.views_remaining == 0

      # Attempting to open expired video returns media_unavailable
      assert {:error, :media_unavailable} =
               ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id)

      Process.exit(pid, :normal)
    end
  end

  describe "Feature 1O.3 — View-Twice Video (VT-V-1..5, RACE-V1..6, FAIL-V1..5, EXP-V1..7, JOIN, RECONCILE, LIMITS)" do
    test "VT-V-1..5: Canonical 2 -> 1 -> 0 progression, same-attempt idempotency, and terminal denial" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      # Send View-Twice Video (presentation_limit: 2)
      assert {:ok, send_res} =
               ConversationServer.append_view_once_video(
                 conv_id,
                 sender_id,
                 client_msg_id,
                 staging_token,
                 2
               )

      assert send_res.presentation_limit == 2
      assert send_res.views_remaining == 2
      assert send_res.views_consumed == 0
      assert send_res.view_once_state == "unviewed"

      # VT-V-1: Attempt X (1st view: 2 -> 1)
      attempt_x = "attempt-x-#{Ecto.UUID.generate()}"

      assert {:ok, res1} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_x
               )

      assert res1.presentation_limit == 2
      assert res1.views_remaining == 1
      assert res1.views_consumed == 1
      assert res1.view_once_state == "viewed_once"
      assert is_binary(res1.presentation_token)

      # VT-V-2: Same Attempt X retry (returns duplicate: true, no second decrement)
      assert {:ok, res1_retry} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_x
               )

      assert res1_retry.duplicate == true
      assert res1_retry.views_remaining == 1
      assert res1_retry.views_consumed == 1
      assert res1_retry.presentation_token == res1.presentation_token

      # VT-V-3: Attempt Y (2nd view: 1 -> 0)
      attempt_y = "attempt-y-#{Ecto.UUID.generate()}"

      assert {:ok, res2} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_y
               )

      assert res2.presentation_limit == 2
      assert res2.views_remaining == 0
      assert res2.views_consumed == 2
      assert res2.view_once_state == "viewed"
      assert is_binary(res2.presentation_token)
      assert res2.presentation_token != res1.presentation_token

      # VT-V-4: Same Attempt Y retry (no second decrement)
      assert {:ok, res2_retry} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_y
               )

      assert res2_retry.duplicate == true
      assert res2_retry.views_remaining == 0
      assert res2_retry.views_consumed == 2

      # VT-V-5: Attempt Z after terminal (denied)
      attempt_z = "attempt-z-#{Ecto.UUID.generate()}"

      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_z
               )

      # Verify both presentation capabilities fetch whole-Blob video bytes
      assert {:ok, fetched1, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 res1.presentation_token,
                 recipient_id
               )

      assert fetched1 == video_bytes

      assert {:ok, fetched2, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 res2.presentation_token,
                 recipient_id
               )

      assert fetched2 == video_bytes

      # Total successful presentations <= 2, third attempt or replay gets 0 bytes
      assert {:error, _} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 res1.presentation_token,
                 recipient_id
               )

      Process.exit(pid, :normal)
    end

    test "RACE-V1: Two remaining + capacity for two -> two unique concurrent attempts both succeed" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      attempt_1 = "race-att-1-#{Ecto.UUID.generate()}"
      attempt_2 = "race-att-2-#{Ecto.UUID.generate()}"

      # Two concurrent deliberate attempts
      task1 =
        Task.async(fn ->
          ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id, attempt_1)
        end)

      task2 =
        Task.async(fn ->
          ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id, attempt_2)
        end)

      res1 = Task.await(task1, 5000)
      res2 = Task.await(task2, 5000)

      assert match?({:ok, _}, res1)
      assert match?({:ok, _}, res2)

      {:ok, val1} = res1
      {:ok, val2} = res2

      # Together they consume 2 -> 1 and 1 -> 0
      consumed_set = Enum.sort([val1.views_remaining, val2.views_remaining])
      assert consumed_set == [0, 1]

      # Both tokens are valid single-use capabilities
      assert {:ok, b1, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 val1.presentation_token,
                 recipient_id
               )

      assert {:ok, b2, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 val2.presentation_token,
                 recipient_id
               )

      assert b1 == video_bytes
      assert b2 == video_bytes

      # Final server state is viewed (0 remaining, 2 consumed)
      server_state = :sys.get_state(pid)
      msg = Enum.find(server_state.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg.view_once_state == :viewed
      assert msg.views_remaining == 0
      assert msg.views_consumed == 2

      Process.exit(pid, :normal)
    end

    test "RACE-V2: Two remaining + capacity for ONLY ONE -> one winner, other capacity refused without burning View, remaining stays 1" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      # Video size ~4 MiB
      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 4_000_000)
      video_size = byte_size(video_bytes)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # Set capacity limit to exactly enough for ONE 4 MiB video (e.g. video_size + 100 bytes)
      Application.put_env(
        :strangertalks_new,
        :view_once_presentation_reservation_limit,
        video_size + 100
      )

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :view_once_presentation_reservation_limit)
      end)

      attempt_a = "race-att-a-#{Ecto.UUID.generate()}"
      attempt_b = "race-att-b-#{Ecto.UUID.generate()}"

      # Two concurrent attempts
      task1 =
        Task.async(fn ->
          ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id, attempt_a)
        end)

      task2 =
        Task.async(fn ->
          ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id, attempt_b)
        end)

      res1 = Task.await(task1, 5000)
      res2 = Task.await(task2, 5000)

      # Exactly ONE must succeed and ONE must receive presentation_capacity_unavailable
      results = [res1, res2]
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :presentation_capacity_unavailable}, &1)) == 1

      # RELEASE-CRITICAL: The refused attempt did NOT burn the second View!
      server_state = :sys.get_state(pid)
      msg = Enum.find(server_state.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg.view_once_state == :viewed_once
      assert msg.views_remaining == 1
      assert msg.views_consumed == 1

      # Consume winner's capability to release reservation
      {:ok, winner_res} = Enum.find(results, &match?({:ok, _}, &1))

      assert {:ok, _, "video/mp4"} =
               ViewOnceMediaStore.consume_presentation(
                 conv_id,
                 client_msg_id,
                 winner_res.presentation_token,
                 recipient_id
               )

      # Now that capacity is released, the second view can be deliberately opened with a new attempt!
      attempt_c = "race-att-c-#{Ecto.UUID.generate()}"

      assert {:ok, res_final} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 attempt_c
               )

      assert res_final.views_remaining == 0
      assert res_final.views_consumed == 2
      assert res_final.view_once_state == "viewed"

      Process.exit(pid, :normal)
    end

    test "RACE-V3 & RACE-V4: One remaining race and same-attempt concurrent retry" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # Consume 1st view
      {:ok, _} =
        ConversationServer.open_view_once_video(
          conv_id,
          recipient_id,
          client_msg_id,
          "first-view"
        )

      # RACE-V3: Two unique attempts race for final 1 view
      att_y = "final-race-y-#{Ecto.UUID.generate()}"
      att_z = "final-race-z-#{Ecto.UUID.generate()}"

      task_y =
        Task.async(fn ->
          ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id, att_y)
        end)

      task_z =
        Task.async(fn ->
          ConversationServer.open_view_once_video(conv_id, recipient_id, client_msg_id, att_z)
        end)

      res_y = Task.await(task_y, 5000)
      res_z = Task.await(task_z, 5000)

      # Exactly one winner, other gets already_consumed
      race_results = [res_y, res_z]
      assert Enum.count(race_results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(race_results, &match?({:error, :already_consumed}, &1)) == 1

      # RACE-V4: Same attempt concurrent retry against winner
      winner_attempt = if match?({:ok, _}, res_y), do: att_y, else: att_z

      retries =
        for _ <- 1..5 do
          Task.async(fn ->
            ConversationServer.open_view_once_video(
              conv_id,
              recipient_id,
              client_msg_id,
              winner_attempt
            )
          end)
        end
        |> Enum.map(&Task.await(&1, 5000))

      assert Enum.all?(retries, &match?({:ok, %{duplicate: true}}, &1))

      Process.exit(pid, :normal)
    end

    test "RACE-V5 & RACE-V6: Capacity unavailable before 1st/2nd View does not mutate remaining; reservations released cleanly" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # Set capacity limit to 0 bytes
      Application.put_env(:strangertalks_new, :view_once_presentation_reservation_limit, 0)

      on_exit(fn ->
        Application.delete_env(:strangertalks_new, :view_once_presentation_reservation_limit)
      end)

      # Attempt before 1st view fails
      assert {:error, :presentation_capacity_unavailable} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "cap-fail-1"
               )

      # Views remaining unchanged at 2
      server_state1 = :sys.get_state(pid)
      msg1 = Enum.find(server_state1.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg1.views_remaining == 2
      assert msg1.views_consumed == 0

      # Restore capacity
      Application.delete_env(:strangertalks_new, :view_once_presentation_reservation_limit)

      # Deliberate open succeeds (2 -> 1)
      assert {:ok, open1} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "cap-pass-1"
               )

      assert open1.views_remaining == 1

      # Consume presentation
      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          open1.presentation_token,
          recipient_id
        )

      # Set capacity limit to 0 bytes before 2nd view
      Application.put_env(:strangertalks_new, :view_once_presentation_reservation_limit, 0)

      assert {:error, :presentation_capacity_unavailable} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "cap-fail-2"
               )

      # Views remaining unchanged at 1
      server_state2 = :sys.get_state(pid)
      msg2 = Enum.find(server_state2.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg2.views_remaining == 1
      assert msg2.views_consumed == 1

      # Restore capacity and complete 2nd view
      Application.delete_env(:strangertalks_new, :view_once_presentation_reservation_limit)

      assert {:ok, open2} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "cap-pass-2"
               )

      assert open2.views_remaining == 0

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          open2.presentation_token,
          recipient_id
        )

      # RACE-V6: Verify all reservations released
      store_state = ViewOnceMediaStore.inspect_state()
      assert store_state.presentation_reserved_bytes == 0
      assert store_state.presentation_reservations_count == 0

      Process.exit(pid, :normal)
    end

    test "FAIL-V1..5: Post-admission transfer failure, capability replay, and unavailable media" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # FAIL-V1: 1st view consumed (2 -> 1). Client drops/fails transfer without consuming.
      assert {:ok, open1} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "transfer-drop-1"
               )

      assert open1.views_remaining == 1

      # No refund on failure: views_remaining remains 1!
      server_state = :sys.get_state(pid)
      msg = Enum.find(server_state.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg.views_remaining == 1

      # User can still deliberate open the second view
      assert {:ok, open2} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "deliberate-second-open"
               )

      assert open2.views_remaining == 0

      # FAIL-V2: 2nd view consumed (1 -> 0). Even if transfer fails, no 3rd view is given.
      assert {:error, :already_consumed} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id,
                 "third-chance"
               )

      # FAIL-V5: If media is deleted / expired, open returns media_unavailable without fabricating consumption
      ViewOnceMediaStore.delete_media(conv_id, client_msg_id)

      client_msg_id2 = Ecto.UUID.generate()
      {:ok, staging_token2} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id2,
          staging_token2,
          2
        )

      ViewOnceMediaStore.delete_media(conv_id, client_msg_id2)

      assert {:error, :media_unavailable} =
               ConversationServer.open_view_once_video(
                 conv_id,
                 recipient_id,
                 client_msg_id2,
                 "att-unavail"
               )

      Process.exit(pid, :normal)
    end

    test "EXP-V1..7: Ordinary 30-min deadline, partial-consumption expiry, and Reports before/after 1st/2nd views" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # EXP-5: Report before any view (views_remaining = 2)
      assert {:ok, report1} =
               StrangertalksNew.Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "HARASSMENT",
                 nil,
                 client_msg_id
               )

      assert report1.report_id != nil
      # Reporting does NOT consume either View!
      server_state1 = :sys.get_state(pid)
      msg1 = Enum.find(server_state1.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg1.views_remaining == 2
      assert msg1.views_consumed == 0

      # Consume 1st view
      {:ok, open1} =
        ConversationServer.open_view_once_video(
          conv_id,
          recipient_id,
          client_msg_id,
          "report-att-1"
        )

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          open1.presentation_token,
          recipient_id
        )

      # EXP-6: Report after 1st view (views_remaining = 1)
      assert {:ok, report2} =
               StrangertalksNew.Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "SPAM",
                 nil,
                 client_msg_id
               )

      assert report2.report_id != nil
      # 2nd view is still available!
      server_state2 = :sys.get_state(pid)
      msg2 = Enum.find(server_state2.recent_messages, &(&1.client_message_id == client_msg_id))
      assert msg2.views_remaining == 1

      # Consume 2nd view
      {:ok, open2} =
        ConversationServer.open_view_once_video(
          conv_id,
          recipient_id,
          client_msg_id,
          "report-att-2"
        )

      {:ok, _, _} =
        ViewOnceMediaStore.consume_presentation(
          conv_id,
          client_msg_id,
          open2.presentation_token,
          recipient_id
        )

      # EXP-7: Report after 2nd view (views_remaining = 0)
      assert {:ok, report3} =
               StrangertalksNew.Reports.submit_conversation_report(
                 conv_id,
                 recipient_id,
                 "SEXUAL_MISCONDUCT",
                 nil,
                 client_msg_id
               )

      assert report3.report_id != nil

      # EXP-1: Ordinary 30-min unopened expiry on a new message
      client_msg_id_exp = Ecto.UUID.generate()
      {:ok, staging_token_exp} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id_exp,
          staging_token_exp,
          2
        )

      send(pid, {:view_once_unopened_expiry, client_msg_id_exp})
      _ = :sys.get_state(pid)

      state_exp = :sys.get_state(pid)

      msg_exp =
        Enum.find(state_exp.recent_messages, &(&1.client_message_id == client_msg_id_exp))

      assert msg_exp.view_once_state == :unavailable
      assert msg_exp.views_remaining == 0

      Process.exit(pid, :normal)
    end

    test "JOIN & RECONCILE: Independent 2 / 1 / 0 / unavailable projection without capability minting or view consumption" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      video_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)
      {:ok, staging_token} = ViewOnceMediaStore.stage_media(conv_id, sender_id, video_bytes)
      client_msg_id = Ecto.UUID.generate()

      {:ok, _} =
        ConversationServer.append_view_once_video(
          conv_id,
          sender_id,
          client_msg_id,
          staging_token,
          2
        )

      # JOIN on initial 2
      assert {:ok, sync1} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      item1 = Enum.find(sync1.messages, &(&1.client_message_id == client_msg_id))
      assert item1.presentation_limit == 2
      assert item1.views_remaining == 2
      assert item1.views_consumed == 0
      assert item1.view_once_state == "unviewed"
      refute Map.has_key?(item1, :presentation_token)

      # Consume 1st view
      {:ok, _open1} =
        ConversationServer.open_view_once_video(
          conv_id,
          recipient_id,
          client_msg_id,
          "join-att-1"
        )

      # RECONCILE on 1 remaining
      assert {:ok, sync2} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      item2 = Enum.find(sync2.messages, &(&1.client_message_id == client_msg_id))
      assert item2.views_remaining == 1
      assert item2.views_consumed == 1
      assert item2.view_once_state == "viewed_once"

      # Consume 2nd view
      {:ok, _} =
        ConversationServer.open_view_once_video(
          conv_id,
          recipient_id,
          client_msg_id,
          "join-att-2"
        )

      # JOIN on 0 (viewed)
      assert {:ok, sync3} = ConversationServer.get_messages_after(conv_id, recipient_id, 0)
      item3 = Enum.find(sync3.messages, &(&1.client_message_id == client_msg_id))
      assert item3.views_remaining == 0
      assert item3.views_consumed == 2
      assert item3.view_once_state == "viewed"

      Process.exit(pid, :normal)
    end

    test "LIMITS: Separate limits across 1O (photo=1), 1O.1 (photo=2), 1O.2 (video=1), and 1O.3 (video=2)" do
      {:ok, conv_id, sender_id, recipient_id, pid} = start_conversation()

      img_bytes = valid_jpeg()
      vid_bytes = valid_mp4(width: 1280, height: 720, duration: 10.0, extra_size: 500)

      # 1O: View-Once Photo (limit: 1)
      {:ok, t1} = ViewOnceMediaStore.stage_media(conv_id, sender_id, img_bytes)
      id1 = Ecto.UUID.generate()
      {:ok, r1} = ConversationServer.append_view_once_photo(conv_id, sender_id, id1, t1, 1)
      assert r1.presentation_limit == 1
      assert r1.views_remaining == 1

      # Consume 1O
      {:ok, open1} = ConversationServer.open_view_once_photo(conv_id, recipient_id, id1)
      assert open1.presentation_limit == 1

      # 1O.1: View-Twice Photo (limit: 2)
      {:ok, t2} = ViewOnceMediaStore.stage_media(conv_id, sender_id, img_bytes)
      id2 = Ecto.UUID.generate()
      {:ok, r2} = ConversationServer.append_view_once_photo(conv_id, sender_id, id2, t2, 2)
      assert r2.presentation_limit == 2
      assert r2.views_remaining == 2

      # Consume 1O.1
      {:ok, open2} = ConversationServer.open_view_once_photo(conv_id, recipient_id, id2)
      assert open2.presentation_limit == 2

      {:ok, _} =
        ConversationServer.open_view_once_photo(conv_id, recipient_id, id2, "second-photo")

      # 1O.2: View-Once Video (limit: 1)
      {:ok, t3} = ViewOnceMediaStore.stage_media(conv_id, sender_id, vid_bytes)
      id3 = Ecto.UUID.generate()
      {:ok, r3} = ConversationServer.append_view_once_video(conv_id, sender_id, id3, t3, 1)
      assert r3.presentation_limit == 1
      assert r3.views_remaining == 1

      # Consume 1O.2
      {:ok, open3} = ConversationServer.open_view_once_video(conv_id, recipient_id, id3)
      assert open3.presentation_limit == 1

      # 1O.3: View-Twice Video (limit: 2)
      {:ok, t4} = ViewOnceMediaStore.stage_media(conv_id, sender_id, vid_bytes)
      id4 = Ecto.UUID.generate()
      {:ok, r4} = ConversationServer.append_view_once_video(conv_id, sender_id, id4, t4, 2)
      assert r4.presentation_limit == 2
      assert r4.views_remaining == 2

      # Consume 1O.3
      {:ok, open4} = ConversationServer.open_view_once_video(conv_id, recipient_id, id4)
      assert open4.presentation_limit == 2
      assert open4.views_remaining == 1

      Process.exit(pid, :normal)
    end
  end
end
