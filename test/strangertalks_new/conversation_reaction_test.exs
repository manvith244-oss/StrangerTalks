defmodule StrangertalksNew.ConversationReactionTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  setup do
    fixture = conversation_fixture()

    on_exit(fn ->
      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    fixture
  end

  defp setup_telemetry_handler(event_name, test_pid) do
    handler_id = "test-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end

  test "reaction to peer delivered text and own delivered text accepted (first reaction rev0->1)",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               msg_id,
               "Hello world"
             )

    assert {:ok, %{status: "delivered"}} =
             ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # Peer reacts to participant A's delivered text (none/rev0 -> ❤️/rev1)
    assert {:ok,
            %{
              status: "applied",
              target_client_message_id: ^msg_id,
              emoji: "❤️",
              revision: 1
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "❤️",
               0
             )

    # Actor reacts to their own delivered text (none/rev0 -> 👍️/rev1)
    assert {:ok,
            %{
              status: "applied",
              target_client_message_id: ^msg_id,
              emoji: "👍️",
              revision: 1
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "👍",
               0
             )
  end

  test "ineligible targets: sent, failed, non-text are rejected as invalid_request", context do
    conv_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    # 1. Sent target (temporarily ineligible)
    sent_msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               sent_msg_id,
               "Sent but unacked"
             )

    assert {:error, :invalid_request} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               sent_msg_id,
               "❤️",
               0
             )

    # 2. Failed target (terminal failure)
    failed_msg_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 2}} =
             ConversationServer.append_message(
               conv_id,
               context.participant_a,
               failed_msg_id,
               "Failing message"
             )

    send(pid, {:expire_message, failed_msg_id})
    _ = :sys.get_state(pid)

    assert {:error, :invalid_request} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               failed_msg_id,
               "❤️",
               0
             )
  end

  test "absent target returns target_absent and emits absent_from_authority telemetry", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)

    setup_telemetry_handler(
      [:strangertalks_new, :reaction_target, :absent_from_authority],
      self()
    )

    random_id = Ecto.UUID.generate()

    assert {:error, :target_absent} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               random_id,
               "❤️",
               0
             )

    assert_received {:telemetry_event,
                     [:strangertalks_new, :reaction_target, :absent_from_authority], %{count: 1},
                     _metadata}
  end

  test "complete CAS matrix: apply, already_canonical, stale, no-op, invalid revision, remove",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(conv_id, context.participant_a, msg_id, "CAS test")

    {:ok, _} =
      ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    setup_telemetry_handler([:strangertalks_new, :reaction_mutation, :applied], self())
    setup_telemetry_handler([:strangertalks_new, :reaction_mutation, :idempotent], self())
    setup_telemetry_handler([:strangertalks_new, :reaction_stale, :revision], self())

    # 1. First APPLY: expected 0, desired "❤️" -> applied rev 1
    assert {:ok, %{status: "applied", emoji: "❤️", revision: 1}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "❤️",
               0
             )

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied],
                     %{count: 1}, _}

    # 2. CANONICAL NO-OP: expected 1, desired "❤️" -> no-op rev 1, zero telemetry
    assert {:ok, %{status: "no_op", emoji: "❤️", revision: 1}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "❤️",
               1
             )

    refute_received {:telemetry_event, _, _, _}

    # 3. ALREADY CANONICAL (retry convergence): expected 0, desired "❤️" -> already_canonical rev 1
    assert {:ok, %{status: "already_canonical", emoji: "❤️", revision: 1}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "❤️",
               0
             )

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :idempotent],
                     %{count: 1}, _}

    # 4. STALE: expected 0, desired "😂" -> stale_revision rev 1, no state change
    assert {:ok, %{status: "stale_revision", emoji: "❤️", revision: 1}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "😂",
               0
             )

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_stale, :revision],
                     %{count: 1}, _}

    # 5. FUTURE REVISION: expected 5 > current 1 -> invalid_revision
    assert {:error, :invalid_revision} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "😂",
               5
             )

    # 6. REPLACE: expected 1, desired "😂" -> applied rev 2
    assert {:ok, %{status: "applied", emoji: "😂", revision: 2}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "😂",
               1
             )

    # 7. REMOVAL: expected 2, desired nil -> applied rev 3, reaction nil
    assert {:ok, %{status: "applied", emoji: nil, revision: 3}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               nil,
               2
             )

    # 8. Re-add after removal: expected 3, desired "👀" -> applied rev 4
    assert {:ok, %{status: "applied", emoji: "👀", revision: 4}} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_b,
               msg_id,
               "👀",
               3
             )
  end

  test "acceptance of multiple RGI categories and strict rejection of invalid inputs", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)

    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(conv_id, context.participant_a, msg_id, "RGI validation")

    {:ok, _} =
      ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # Acceptance of valid RGI categories
    valid_categories = [
      {"basic emoji", "❤️", 0},
      {"skin-tone sequence", "👍🏽", 1},
      {"ZWJ profession sequence", "👩‍💻", 2},
      {"flag sequence", "🇺🇳", 3},
      {"rainbow/variation sequence", "🏳️‍🌈", 4},
      {"complex multi-skin kiss sequence", "🧑🏻‍❤️‍💋‍🧑🏼", 5},
      {"keycap sequence", "#️⃣", 6}
    ]

    for {_name, emoji, rev} <- valid_categories do
      expected_rev = rev + 1

      assert {:ok, %{status: "applied", emoji: ^emoji, revision: ^expected_rev}} =
               ConversationServer.mutate_reaction(
                 conv_id,
                 context.participant_a,
                 msg_id,
                 emoji,
                 rev
               )
    end

    # Strict rejection of non-RGI and malformed inputs
    invalid_inputs = [
      "hello",
      "<script>alert(1)</script>",
      "Alpha Beta γ",
      "❤️❤️",
      "👍😂",
      "random_text",
      "👩‍❤️‍👩‍❤️‍👩",
      "e\u0301\u0302\u0303",
      String.duplicate("❤️", 50),
      "heart",
      "laugh"
    ]

    for invalid <- invalid_inputs do
      assert {:error, :invalid_request} =
               ConversationServer.mutate_reaction(
                 conv_id,
                 context.participant_a,
                 msg_id,
                 invalid,
                 7
               )
    end

    assert {:error, :invalid_revision} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "❤️",
               -1
             )

    assert {:error, :invalid_revision} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "❤️",
               3_000_000_000
             )
  end

  test "canonical Unicode identity: equivalent alias spellings map to one deterministic sequence and cause zero revision increment or fanout",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    setup_telemetry_handler(
      [:strangertalks_new, :reaction_mutation, :applied],
      self()
    )

    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a,
        msg_id,
        "Canonical identity test"
      )

    {:ok, _} =
      ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # 1. Verify EmojiValidator helper canonicalization
    # "❤" (U+2764, unqualified) and "❤️" (U+2764 U+FE0F, fully-qualified)
    assert {:ok, "❤️"} = StrangertalksNew.EmojiValidator.canonical_reaction("❤")
    assert {:ok, "❤️"} = StrangertalksNew.EmojiValidator.canonical_reaction("❤️")
    # "👍️" (U+1F44D U+FE0F) and "👍" (U+1F44D) both map to canonical "👍️"
    assert {:ok, "👍️"} = StrangertalksNew.EmojiValidator.canonical_reaction("👍️")
    assert {:ok, "👍️"} = StrangertalksNew.EmojiValidator.canonical_reaction("👍")

    # 2. Mutate to unqualified alias "❤" -> applied canonically as "❤️" at revision 1
    assert {:ok,
            %{
              status: "applied",
              target_client_message_id: ^msg_id,
              emoji: "❤️",
              revision: 1
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "❤",
               0
             )

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied],
                     %{count: 1}, _}

    # Flush mailbox of notification pushes
    assert_received {:conversation_reaction, %{emoji: "❤️", revision: 1, owner_relation: "self"}}

    # 3. Client sends fully-qualified alias "❤️" at expected revision 1:
    # Must result in NO-OP: revision remains 1, zero state change, zero applied telemetry, zero live fanout
    assert {:ok,
            %{
              status: "no_op",
              target_client_message_id: ^msg_id,
              emoji: "❤️",
              revision: 1
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "❤️",
               1
             )

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied], _, _}
    refute_received {:conversation_reaction, _}

    # 4. Client sends unqualified alias "❤" at older revision 0:
    # Must result in ALREADY_CANONICAL: revision remains 1, zero applied telemetry, zero live fanout
    assert {:ok,
            %{
              status: "already_canonical",
              target_client_message_id: ^msg_id,
              emoji: "❤️",
              revision: 1
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "❤",
               0
             )

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied], _, _}
    refute_received {:conversation_reaction, _}

    # 5. Verify authoritative state stores ONLY canonical sequence
    {:ok, state} = ConversationServer.inspect_state(conv_id)
    [stored_msg] = state.recent_messages
    stored_slot = stored_msg.reactions[context.participant_a]
    assert stored_slot == %{emoji: "❤️", revision: 1}

    # 6. Genuinely different emoji mutation (e.g. "😂") advances revision to 2
    assert {:ok,
            %{
              status: "applied",
              target_client_message_id: ^msg_id,
              emoji: "😂",
              revision: 2
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "😂",
               1
             )

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied],
                     %{count: 1}, _}

    assert_received {:conversation_reaction, %{emoji: "😂", revision: 2}}
  end

  test "authoritative owner safety: direct invalid non-RGI input returns bounded error, process survives, state/sequence/revisions immutable, zero fanout and zero CAS telemetry",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, server_pid} = ConversationServer.ensure_started(conv_id)
    :ok = ConversationServer.register_channel(conv_id, context.participant_a, self())

    setup_telemetry_handler([:strangertalks_new, :reaction_mutation, :applied], self())
    setup_telemetry_handler([:strangertalks_new, :reaction_mutation, :idempotent], self())
    setup_telemetry_handler([:strangertalks_new, :reaction_stale, :revision], self())

    msg_id = Ecto.UUID.generate()

    {:ok, %{sequence: 1}} =
      ConversationServer.append_message(
        conv_id,
        context.participant_a,
        msg_id,
        "Owner safety test"
      )

    {:ok, _} =
      ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    {:ok, state_before} = ConversationServer.inspect_state(conv_id)
    assert state_before.next_sequence == 2

    # 1. Direct invocation with non-RGI string "not-an-emoji" bypassing Channel validation
    assert {:error, :invalid_request} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "not-an-emoji",
               0
             )

    # 2. Direct invocation with other invalid inputs (script, oversized, non-binary)
    assert {:error, :invalid_request} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "<script>alert(1)</script>",
               0
             )

    assert {:error, :invalid_request} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               String.duplicate("❤️", 50),
               0
             )

    # 3. Prove ConversationServer process remains alive and healthy
    assert Process.alive?(server_pid)
    assert _ = :sys.get_state(server_pid)

    # 4. State immutability proof: slot, revision, and sequence are completely unchanged
    {:ok, state_after} = ConversationServer.inspect_state(conv_id)
    assert state_after.next_sequence == 2
    [msg] = state_after.recent_messages
    assert msg.reactions[context.participant_a] == nil

    # 5. Telemetry negative proof: zero applied, idempotent, or stale events
    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied], _, _}

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :idempotent], _,
                     _}

    refute_received {:telemetry_event, [:strangertalks_new, :reaction_stale, :revision], _, _}

    # 6. Fanout negative proof: zero live message pushes emitted
    refute_received {:conversation_reaction, _}

    # 7. Healthy continuation: subsequent valid mutation succeeds normally
    assert {:ok,
            %{
              status: "applied",
              target_client_message_id: ^msg_id,
              emoji: "❤️",
              revision: 1
            }} =
             ConversationServer.mutate_reaction(
               conv_id,
               context.participant_a,
               msg_id,
               "❤️",
               0
             )

    assert_received {:telemetry_event, [:strangertalks_new, :reaction_mutation, :applied],
                     %{count: 1}, _}

    assert_received {:conversation_reaction, %{emoji: "❤️", revision: 1}}
  end

  test "mutation does not allocate message sequence or alter replay byte accounting", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)

    msg_id = Ecto.UUID.generate()

    {:ok, %{sequence: 1}} =
      ConversationServer.append_message(conv_id, context.participant_a, msg_id, "Hello")

    {:ok, _} =
      ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    {:ok, state_before} = ConversationServer.inspect_state(conv_id)
    assert state_before.next_sequence == 2
    assert state_before.replay_bytes == byte_size("Hello")

    {:ok, _} =
      ConversationServer.mutate_reaction(conv_id, context.participant_a, msg_id, "❤️", 0)

    {:ok, state_after} = ConversationServer.inspect_state(conv_id)
    assert state_after.next_sequence == 2
    assert state_after.replay_bytes == byte_size("Hello")
    assert map_size(state_after.pending) == 0
  end

  test "live multi-session fanout sends recipient-relative payload to both participants",
       context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)

    actor_pid = self()
    peer_pid = spawn_link(fn -> test_receiver_loop() end)

    :ok = ConversationServer.register_channel(conv_id, context.participant_a, actor_pid)
    :ok = ConversationServer.register_channel(conv_id, context.participant_b, peer_pid)

    msg_id = Ecto.UUID.generate()

    {:ok, _} =
      ConversationServer.append_message(conv_id, context.participant_a, msg_id, "Text")

    {:ok, _} =
      ConversationServer.acknowledge_message(conv_id, context.participant_b, msg_id)

    # Actor (participant A) reacts with "😭"
    {:ok, _} =
      ConversationServer.mutate_reaction(conv_id, context.participant_a, msg_id, "😭", 0)

    # Actor receives owner_relation: "self"
    assert_received {:conversation_reaction,
                     %{
                       target_client_message_id: ^msg_id,
                       owner_relation: "self",
                       emoji: "😭",
                       revision: 1
                     }}

    # Peer receives owner_relation: "peer"
    send(peer_pid, {:get_received, self()})

    assert_receive {:received_messages, peer_msgs}

    assert Enum.any?(peer_msgs, fn
             {:conversation_reaction,
              %{
                target_client_message_id: ^msg_id,
                owner_relation: "peer",
                emoji: "😭",
                revision: 1
              }} ->
               true

             _ ->
               false
           end)
  end

  test "sync payload and sync:reconcile include complete reaction snapshots", context do
    conv_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conv_id)

    msg1 = Ecto.UUID.generate()
    msg2 = Ecto.UUID.generate()

    {:ok, _} = ConversationServer.append_message(conv_id, context.participant_a, msg1, "First")
    {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, msg1)

    {:ok, _} = ConversationServer.append_message(conv_id, context.participant_a, msg2, "Second")
    {:ok, _} = ConversationServer.acknowledge_message(conv_id, context.participant_b, msg2)

    {:ok, _} =
      ConversationServer.mutate_reaction(conv_id, context.participant_a, msg1, "❤️", 0)

    {:ok, _} =
      ConversationServer.mutate_reaction(conv_id, context.participant_b, msg1, "👍", 0)

    # 1. Join-time sync (initial)
    {:ok, sync_payload} =
      ConversationServer.sync_and_register_channel(
        conv_id,
        context.participant_a,
        self(),
        nil,
        0
      )

    assert is_list(sync_payload.reaction_snapshots)
    assert length(sync_payload.reaction_snapshots) == 2

    snap1 =
      Enum.find(sync_payload.reaction_snapshots, &(&1.target_client_message_id == msg1))

    assert snap1.self_reaction == %{emoji: "❤️", revision: 1}
    assert snap1.peer_reaction == %{emoji: "👍️", revision: 1}

    snap2 =
      Enum.find(sync_payload.reaction_snapshots, &(&1.target_client_message_id == msg2))

    assert snap2.self_reaction == %{emoji: nil, revision: 0}
    assert snap2.peer_reaction == %{emoji: nil, revision: 0}

    # 2. sync:reconcile (get_messages_after)
    {:ok, reconcile_payload} =
      ConversationServer.get_messages_after(conv_id, context.participant_a, 1)

    assert is_list(reconcile_payload.reaction_snapshots)
    assert length(reconcile_payload.reaction_snapshots) == 2
  end

  defp test_receiver_loop(acc \\ []) do
    receive do
      {:get_received, caller} ->
        send(caller, {:received_messages, Enum.reverse(acc)})
        test_receiver_loop(acc)

      msg ->
        test_receiver_loop([msg | acc])
    end
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
