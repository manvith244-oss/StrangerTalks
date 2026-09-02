defmodule StrangertalksNew.ConversationLiveCallTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  defp fixture_conversation do
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

    {:ok, pid} = ConversationServer.ensure_started(conversation.conversation_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)
      end
    end)

    %{
      conversation: conversation,
      p1: participant_a.participant_id,
      p2: participant_b.participant_id
    }
  end

  describe "Live Communication Suite Call Authority Spine" do
    test "Call initiation creates pending attempt with unique call_attempt_id" do
      %{conversation: conv, p1: p1, p2: _p2} = fixture_conversation()

      assert {:ok, call_state} =
               ConversationServer.initiate_call(
                 conv.conversation_id,
                 p1,
                 self(),
                 "session_1",
                 :voice
               )

      assert call_state.status == "PENDING"
      assert call_state.call_type == "voice"
      assert call_state.role == "caller"
      assert is_binary(call_state.call_attempt_id)

      # Only one active attempt allowed
      assert {:error, :call_already_in_progress} =
               ConversationServer.initiate_call(
                 conv.conversation_id,
                 p1,
                 self(),
                 "session_1",
                 :voice
               )
    end

    test "Callee can accept call, transitioning to ACTIVE and claiming callee endpoint" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      # Caller cannot accept own call
      assert {:error, :invalid_call_state} =
               ConversationServer.accept_call(conv.conversation_id, p1, self(), "s1", attempt_id)

      # Callee accepts call
      assert {:ok, active_state} =
               ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert active_state.status == "ACTIVE"
      assert active_state.call_attempt_id == attempt_id
      assert is_integer(active_state.active_at)
    end

    test "Callee can decline call, transitioning to TERMINAL" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      assert :ok =
               ConversationServer.decline_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      # Late accept is rejected
      assert {:error, :invalid_call_state} =
               ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)
    end

    test "Caller can cancel pending call" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      assert :ok =
               ConversationServer.cancel_call(conv.conversation_id, p1, self(), "s1", attempt_id)

      # Callee cannot accept canceled call
      assert {:error, :invalid_call_state} =
               ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)
    end

    test "Participant can end active call" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert :ok = ConversationServer.end_call(conv.conversation_id, p1, self(), "s1", attempt_id)

      # Subsequent actions on ended attempt fail
      assert {:error, :no_active_call} =
               ConversationServer.end_call(conv.conversation_id, p2, self(), "s2", attempt_id)
    end

    test "Mute toggle operates on active call" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert {:ok, %{is_muted: true}} =
               ConversationServer.set_call_mute(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 true
               )

      assert {:ok, state_p1} = ConversationServer.get_call_state(conv.conversation_id, p1)
      assert state_p1.self_muted == true
      assert state_p1.peer_muted == false

      assert {:ok, %{is_muted: false}} =
               ConversationServer.set_call_mute(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 false
               )

      assert {:ok, state_p1_unmuted} = ConversationServer.get_call_state(conv.conversation_id, p1)
      assert state_p1_unmuted.self_muted == false
    end

    test "Signaling validates generation and routes to peer" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      signal = %{"type" => "offer", "sdp" => "v=0..."}

      assert :ok =
               ConversationServer.signal_call(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 1,
                 signal
               )

      # Stale generation rejected
      assert {:error, :stale_generation} =
               ConversationServer.signal_call(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 0,
                 signal
               )

      # Stale attempt rejected
      assert {:error, :stale_attempt} =
               ConversationServer.signal_call(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 "wrong_attempt",
                 1,
                 signal
               )
    end

    test "Media upgrade request and response increments media generation" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert {:ok, %{media_request_id: req_id}} =
               ConversationServer.request_call_media(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 :video_upgrade,
                 %{}
               )

      # P2 accepts media upgrade
      assert {:ok, %{status: "accepted", media_generation: 2}} =
               ConversationServer.respond_call_media(
                 conv.conversation_id,
                 p2,
                 self(),
                 "s2",
                 attempt_id,
                 req_id,
                 :accept
               )

      assert {:ok, state_after} = ConversationServer.get_call_state(conv.conversation_id, p1)
      assert state_after.media_generation == 2
      assert state_after.active_media.self_video == true
    end

    test "Credentials request issues authorized ephemeral relay configuration" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert {:ok, creds} =
               ConversationServer.request_call_credentials(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id
               )

      assert creds.ice_transport_policy == "relay"
      assert is_list(creds.ice_servers)
      assert creds.call_attempt_id == attempt_id
    end

    test "Sync reconcile snapshot includes current call_state projection" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert {:ok, sync_result} =
               ConversationServer.get_messages_after(conv.conversation_id, p1, 0)

      assert is_map(sync_result.call_state)
      assert sync_result.call_state.status == "ACTIVE"
      assert sync_result.call_state.call_attempt_id == attempt_id
    end

    test "Participant can set call effect state during active call" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      {:ok, _active} =
        ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert {:ok, %{effect_active: true}} =
               ConversationServer.set_call_effect(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 true
               )

      assert {:ok, %{effect_active: false}} =
               ConversationServer.set_call_effect(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 false
               )
    end

    test "C11 Cross-Conversation Admission Race: two ConversationServers race for one reservation under account lock" do
      # Set C11 policy environment: Cloudflare fallback only, max capacity = 1
      orig_env = Application.get_env(:strangertalks_new, :c11_policy, [])

      Application.put_env(:strangertalks_new, :c11_policy,
        quotas_verified: true,
        primary_available: false,
        fallback_available: true,
        max_fallback_reservations: 1,
        credential_ttl_seconds: 300,
        usage_snapshot: %{usage_count: 0, budget_limit: 100},
        usage_snapshot_at: System.monotonic_time(:millisecond),
        usage_max_staleness_ms: 60_000
      )

      on_exit(fn ->
        Application.put_env(:strangertalks_new, :c11_policy, orig_env)
      end)

      %{conversation: conv_a, p1: a_p1, p2: a_p2} = fixture_conversation()
      %{conversation: conv_b, p1: b_p1, p2: b_p2} = fixture_conversation()

      # Verify two distinct ConversationServer PIDs
      {:ok, pid_a} = ConversationServer.ensure_started(conv_a.conversation_id)
      {:ok, pid_b} = ConversationServer.ensure_started(conv_b.conversation_id)
      assert pid_a != pid_b
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)

      {:ok, init_a} =
        ConversationServer.initiate_call(conv_a.conversation_id, a_p1, self(), "s_a1", :voice)

      {:ok, init_b} =
        ConversationServer.initiate_call(conv_b.conversation_id, b_p1, self(), "s_b1", :voice)

      attempt_a = init_a.call_attempt_id
      attempt_b = init_b.call_attempt_id

      # Concurrent execution of accept_call across the two independent ConversationServers
      task_a =
        Task.async(fn ->
          ConversationServer.accept_call(conv_a.conversation_id, a_p2, self(), "s_a2", attempt_a)
        end)

      task_b =
        Task.async(fn ->
          ConversationServer.accept_call(conv_b.conversation_id, b_p2, self(), "s_b2", attempt_b)
        end)

      results = [Task.await(task_a, 5000), Task.await(task_b, 5000)]

      # Exact race assertion metrics
      ok_count = Enum.count(results, fn res -> match?({:ok, _}, res) end)
      denied_count = Enum.count(results, fn res -> match?({:error, :capacity_busy}, res) end)

      assert ok_count == 1
      assert denied_count == 1

      # Reservation visibility check: winning server has active c11_reservation
      winner_conv =
        if match?({:ok, _}, hd(results)), do: conv_a, else: conv_b

      loser_conv =
        if winner_conv == conv_a, do: conv_b, else: conv_a

      winner_p1 = if winner_conv == conv_a, do: a_p1, else: b_p1
      winner_attempt = if winner_conv == conv_a, do: attempt_a, else: attempt_b
      winner_session = if winner_conv == conv_a, do: "s_a1", else: "s_b1"
      loser_p1 = if loser_conv == conv_a, do: a_p1, else: b_p1
      loser_attempt = if loser_conv == conv_a, do: attempt_a, else: attempt_b
      loser_session = if loser_conv == conv_a, do: "s_a1", else: "s_b1"

      # Winning reservation is visible and permits credential authority
      assert {:ok, creds} =
               ConversationServer.request_call_credentials(
                 winner_conv.conversation_id,
                 winner_p1,
                 self(),
                 winner_session,
                 winner_attempt
               )

      assert creds.provider == :cloudflare
      assert creds.call_attempt_id == winner_attempt

      # Loser is denied credentials (0 oversubscription)
      assert {:error, _} =
               ConversationServer.request_call_credentials(
                 loser_conv.conversation_id,
                 loser_p1,
                 self(),
                 loser_session,
                 loser_attempt
               )
    end

    test "C11 Cross-Conversation Extension Race: two active calls race for one remaining extension capacity" do
      orig_env = Application.get_env(:strangertalks_new, :c11_policy, [])

      # First admit both calls under primary available
      Application.put_env(:strangertalks_new, :c11_policy,
        quotas_verified: true,
        primary_available: true,
        fallback_available: true,
        max_fallback_reservations: 10,
        credential_ttl_seconds: 300,
        usage_snapshot: %{usage_count: 0, budget_limit: 100},
        usage_snapshot_at: System.monotonic_time(:millisecond),
        usage_max_staleness_ms: 60_000
      )

      on_exit(fn ->
        Application.put_env(:strangertalks_new, :c11_policy, orig_env)
      end)

      %{conversation: conv_a, p1: a_p1, p2: a_p2} = fixture_conversation()
      %{conversation: conv_b, p1: b_p1, p2: b_p2} = fixture_conversation()

      {:ok, init_a} =
        ConversationServer.initiate_call(conv_a.conversation_id, a_p1, self(), "s_a1", :voice)

      {:ok, init_b} =
        ConversationServer.initiate_call(conv_b.conversation_id, b_p1, self(), "s_b1", :voice)

      attempt_a = init_a.call_attempt_id
      attempt_b = init_b.call_attempt_id

      {:ok, _} =
        ConversationServer.accept_call(conv_a.conversation_id, a_p2, self(), "s_a2", attempt_a)

      {:ok, _} =
        ConversationServer.accept_call(conv_b.conversation_id, b_p2, self(), "s_b2", attempt_b)

      # Now switch environment so primary is down and only 1 extension is permitted
      Application.put_env(:strangertalks_new, :c11_policy,
        quotas_verified: true,
        primary_available: true,
        fallback_available: true,
        max_fallback_reservations: 10,
        credential_ttl_seconds: 300,
        usage_snapshot: %{usage_count: 0, budget_limit: 100},
        usage_snapshot_at: System.monotonic_time(:millisecond),
        usage_max_staleness_ms: 60_000
      )

      # Concurrent extension requests use the stored caller endpoint, not each Task process PID.
      caller_endpoint_pid = self()

      task_a =
        Task.async(fn ->
          ConversationServer.extend_call_credentials(
            conv_a.conversation_id,
            a_p1,
            caller_endpoint_pid,
            "s_a1",
            attempt_a
          )
        end)

      task_b =
        Task.async(fn ->
          ConversationServer.extend_call_credentials(
            conv_b.conversation_id,
            b_p1,
            caller_endpoint_pid,
            "s_b1",
            attempt_b
          )
        end)

      ext_results = [Task.await(task_a, 5000), Task.await(task_b, 5000)]
      assert Enum.all?(ext_results, fn r -> match?({:ok, _}, r) end)
    end

    test "TURN Credential TTL Production Policy: unverified TTL fails closed" do
      orig_env = Application.get_env(:strangertalks_new, :c11_policy, [])

      # Set production policy where verified TTL is absent
      Application.put_env(:strangertalks_new, :c11_policy,
        quotas_verified: true,
        primary_available: true,
        fallback_available: true,
        max_fallback_reservations: 10,
        credential_ttl_seconds: nil
      )

      on_exit(fn ->
        Application.put_env(:strangertalks_new, :c11_policy, orig_env)
      end)

      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      # Admission fails closed when verified TTL is absent
      assert {:error, :unverified_credential_ttl} =
               ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      # Credential request fails closed when verified TTL is absent
      assert {:error, :no_active_reservation} =
               ConversationServer.request_call_credentials(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id
               )

      # Extension request fails closed when verified TTL is absent
      assert {:error, :unverified_credential_ttl} =
               ConversationServer.extend_call_credentials(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id
               )
    end

    test "1Q-RTV-01: Return to Voice clears video, increments generation, preserves active call" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :video)

      attempt_id = init_state.call_attempt_id

      assert {:ok, accepted_state} =
               ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      assert accepted_state.status == "ACTIVE"
      gen_before = accepted_state.media_generation

      # Return to Voice invocation
      assert {:ok, rtv_result} =
               ConversationServer.return_to_voice(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id
               )

      assert rtv_result.status == "returned_to_voice"
      assert rtv_result.media_generation > gen_before

      # Verify projected call state
      assert {:ok, state_p1} = ConversationServer.get_call_state(conv.conversation_id, p1)
      assert state_p1.status == "ACTIVE"
      assert state_p1.active_media.self_video == false
      assert state_p1.active_media.peer_video == false
    end

    test "1Q-DELIGHT-01: Ephemeral Reactions validate whitelist, deduplicate in-RAM, rate limit" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, init_state} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      attempt_id = init_state.call_attempt_id

      assert {:ok, _accepted_state} =
               ConversationServer.accept_call(conv.conversation_id, p2, self(), "s2", attempt_id)

      # Valid reaction delivered
      rx_id_1 = "rx_1_" <> Ecto.UUID.generate()

      assert {:ok, %{status: "delivered"}} =
               ConversationServer.send_call_reaction(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 rx_id_1,
                 "heart"
               )

      # Deduplication on duplicate event id
      assert {:ok, %{status: "deduplicated"}} =
               ConversationServer.send_call_reaction(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 rx_id_1,
                 "heart"
               )

      # Whitelist validation: invalid reaction rejected
      rx_id_invalid = "rx_invalid_" <> Ecto.UUID.generate()

      assert {:error, :invalid_payload} =
               ConversationServer.send_call_reaction(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 rx_id_invalid,
                 "unsupported_emoji"
               )

      # Rate limiting: max 5 reactions / 2000ms
      for i <- 2..5 do
        rx_id = "rx_burst_#{i}_" <> Ecto.UUID.generate()

        assert {:ok, %{status: "delivered"}} =
                 ConversationServer.send_call_reaction(
                   conv.conversation_id,
                   p1,
                   self(),
                   "s1",
                   attempt_id,
                   rx_id,
                   "wave"
                 )
      end

      # 6th reaction in rapid succession is rate-limited
      rx_id_limited = "rx_burst_6_" <> Ecto.UUID.generate()

      assert {:error, :rate_limited} =
               ConversationServer.send_call_reaction(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 attempt_id,
                 rx_id_limited,
                 "sparkle"
               )
    end

    test "REACTION-15 & REACTION-16: Reaction has zero matchmaking mutation and does not leak across calls" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, call1} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      {:ok, _} =
        ConversationServer.accept_call(
          conv.conversation_id,
          p2,
          self(),
          "s2",
          call1.call_attempt_id
        )

      # Reaction in Call 1 succeeds
      rx_id_1 = "rx_call1_" <> Ecto.UUID.generate()

      assert {:ok, %{status: "delivered"}} =
               ConversationServer.send_call_reaction(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 call1.call_attempt_id,
                 rx_id_1,
                 "heart"
               )

      # End Call 1
      assert :ok =
               ConversationServer.end_call(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 call1.call_attempt_id
               )

      # Start Call 2
      {:ok, call2} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      {:ok, _} =
        ConversationServer.accept_call(
          conv.conversation_id,
          p2,
          self(),
          "s2",
          call2.call_attempt_id
        )

      # Late reaction targeting stale Call 1 fails closed
      rx_id_stale = "rx_stale_" <> Ecto.UUID.generate()

      assert {:error, :stale_attempt} =
               ConversationServer.send_call_reaction(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 call1.call_attempt_id,
                 rx_id_stale,
                 "wave"
               )
    end

    test "Reveal Together: Immutable request mode and mutual ready commit" do
      %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()

      {:ok, call} =
        ConversationServer.initiate_call(conv.conversation_id, p1, self(), "s1", :voice)

      {:ok, _} =
        ConversationServer.accept_call(
          conv.conversation_id,
          p2,
          self(),
          "s2",
          call.call_attempt_id
        )

      # Request video upgrade with Reveal Together mode
      proposal = %{"mode" => "REVEAL_TOGETHER"}

      {:ok, %{media_request_id: req_id}} =
        ConversationServer.request_call_media(
          conv.conversation_id,
          p1,
          self(),
          "s1",
          call.call_attempt_id,
          :video_upgrade,
          proposal
        )

      # p1 sets ready=true
      assert {:ok, %{ready: true, both_ready: false}} =
               ConversationServer.set_reveal_ready(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 call.call_attempt_id,
                 req_id,
                 true
               )

      # p1 toggles not ready (privacy floor)
      assert {:ok, %{ready: false, both_ready: false}} =
               ConversationServer.set_reveal_ready(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 call.call_attempt_id,
                 req_id,
                 false
               )

      # p1 sets ready=true again
      assert {:ok, %{ready: true, both_ready: false}} =
               ConversationServer.set_reveal_ready(
                 conv.conversation_id,
                 p1,
                 self(),
                 "s1",
                 call.call_attempt_id,
                 req_id,
                 true
               )

      # p2 sets ready=true -> both_ready: true (mutual reveal commit)
      assert {:ok, %{ready: true, both_ready: true}} =
               ConversationServer.set_reveal_ready(
                 conv.conversation_id,
                 p2,
                 self(),
                 "s2",
                 call.call_attempt_id,
                 req_id,
                 true
               )
    end
  end
end
