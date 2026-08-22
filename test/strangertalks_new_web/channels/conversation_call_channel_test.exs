defmodule StrangertalksNewWeb.ConversationCallChannelTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.Participants
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNewWeb.{ConversationChannel, ParticipantToken, UserSocket}

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  setup do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
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

    socket_a = connect_and_join(participant_a, conversation)
    socket_b = connect_and_join(participant_b, conversation)

    %{
      conversation: conversation,
      participant_a: participant_a,
      participant_b: participant_b,
      socket_a: socket_a,
      socket_b: socket_b,
      topic: "conversation:#{conversation.conversation_id}"
    }
  end

  defp connect_and_join(participant, conversation) do
    token = ParticipantToken.sign(participant.participant_id)

    {:ok, socket} =
      connect(UserSocket, %{}, connect_info: %{auth_token: token})

    topic = "conversation:#{conversation.conversation_id}"

    {:ok, _reply, socket} =
      subscribe_and_join(socket, ConversationChannel, topic, %{})

    socket
  end

  describe "Live Communication Suite Channel Event Interface" do
    test "P1 initiates call, P2 receives call:incoming push", %{
      socket_a: socket_a,
      socket_b: _socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{status: "PENDING", call_attempt_id: attempt_id, role: "caller"}

      assert_push "call:incoming", %{
        call_attempt_id: ^attempt_id,
        caller_id: _,
        call_type: "voice"
      }
    end

    test "P2 accepts call, both sockets receive call:accepted push", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}

      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE", call_attempt_id: ^attempt_id}

      assert_push "call:accepted", %{call_attempt_id: ^attempt_id, status: "ACTIVE"}
    end

    test "Participant can mute and push is broadcasted", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      ref_mute = push(socket_a, "call:mute", %{"call_attempt_id" => attempt_id, "muted" => true})
      assert_reply ref_mute, :ok, %{is_muted: true}

      assert_push "call:mute_changed", %{call_attempt_id: ^attempt_id, is_muted: true}
    end

    test "Signaling payload is routed to peer", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      signal = %{"type" => "candidate", "candidate" => "candidate:..."}

      ref_sig =
        push(socket_a, "call:signal", %{
          "call_attempt_id" => attempt_id,
          "media_generation" => 1,
          "signal" => signal
        })

      assert_reply ref_sig, :ok, %{status: "delivered"}

      assert_push "call:signal", %{
        call_attempt_id: ^attempt_id,
        media_generation: 1,
        signal: ^signal
      }
    end

    test "P1 ends call, both receive call:ended push", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      ref_end = push(socket_a, "call:end", %{"call_attempt_id" => attempt_id})
      assert_reply ref_end, :ok, %{status: "ended"}

      assert_push "call:ended", %{call_attempt_id: ^attempt_id, reason: "ended_by_user"}
    end

    test "Credentials request returns relay configuration", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      ref_creds = push(socket_a, "call:request_credentials", %{"call_attempt_id" => attempt_id})

      assert_reply ref_creds, :ok, %{
        ice_transport_policy: "relay",
        ice_servers: servers
      }

      assert is_list(servers)
    end

    test "Participant changes voice effect and peer receives call:effect_changed", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      ref_effect =
        push(socket_a, "call:effect", %{"call_attempt_id" => attempt_id, "effect_active" => true})

      assert_reply ref_effect, :ok, %{effect_active: true}

      assert_push "call:effect_changed", %{
        call_attempt_id: ^attempt_id,
        effect_active: true
      }
    end

    test "Participant invokes return_to_voice and receives confirmation", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "video"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      ref_rtv = push(socket_a, "call:return_to_voice", %{"call_attempt_id" => attempt_id})
      assert_reply ref_rtv, :ok, %{status: "returned_to_voice", media_generation: new_gen}
      assert new_gen > 1

      assert_push "call:media_updated", %{
        call_attempt_id: ^attempt_id,
        return_to_voice: true,
        actor_id: _
      }
    end

    test "Participant sends reaction and peer receives call:reaction", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      rx_id = "rx_test_" <> Ecto.UUID.generate()

      ref_rx =
        push(socket_a, "call:reaction", %{
          "call_attempt_id" => attempt_id,
          "reaction_event_id" => rx_id,
          "reaction" => "heart"
        })

      assert_reply ref_rx, :ok, %{status: "delivered", reaction_event_id: ^rx_id}

      assert_push "call:reaction", %{
        call_attempt_id: ^attempt_id,
        reaction_event_id: ^rx_id,
        reaction: "heart"
      }
    end

    test "Participant sets reveal_ready and receives confirmation and broadcast", %{
      socket_a: socket_a,
      socket_b: socket_b
    } do
      ref = push(socket_a, "call:initiate", %{"call_type" => "voice"})
      assert_reply ref, :ok, %{call_attempt_id: attempt_id}
      ref2 = push(socket_b, "call:accept", %{"call_attempt_id" => attempt_id})
      assert_reply ref2, :ok, %{status: "ACTIVE"}

      # Request video upgrade with Reveal Together mode
      ref_req =
        push(socket_a, "call:media_request", %{
          "call_attempt_id" => attempt_id,
          "request_type" => "video_upgrade",
          "proposal" => %{"mode" => "REVEAL_TOGETHER"}
        })

      assert_reply ref_req, :ok, %{media_request_id: req_id}

      # Socket A sets reveal_ready=true
      ref_ready =
        push(socket_a, "call:reveal_ready", %{
          "call_attempt_id" => attempt_id,
          "media_request_id" => req_id,
          "ready" => true
        })

      assert_reply ref_ready, :ok, %{ready: true, both_ready: false}
      assert_push "call:reveal_ready", %{media_request_id: ^req_id, ready: true}
    end
  end
end
