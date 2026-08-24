defmodule StrangertalksNew.Team6MediaAuthorityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer

  defp endpoint do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

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

    {:ok, server} = ConversationServer.ensure_started(conversation.conversation_id)
    on_exit(fn ->
      if Process.alive?(server) do
        DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, server)
      end
    end)

    %{
      conversation: conversation,
      p1: participant_a.participant_id,
      p2: participant_b.participant_id
    }
  end

  defp active_call do
    %{conversation: conv, p1: p1, p2: p2} = fixture_conversation()
    p1_owner = endpoint()
    p2_owner = endpoint()

    {:ok, pending} =
      ConversationServer.initiate_call(conv.conversation_id, p1, p1_owner, "p1-owner", :voice)

    {:ok, _active} =
      ConversationServer.accept_call(
        conv.conversation_id,
        p2,
        p2_owner,
        "p2-owner",
        pending.call_attempt_id
      )

    %{conv: conv, p1: p1, p2: p2, p1_owner: p1_owner, p2_owner: p2_owner, attempt: pending.call_attempt_id}
  end

  test "sibling tab cannot mute or inject signaling for the authoritative media participant" do
    %{conv: conv, p1: p1, p1_owner: owner, attempt: attempt} = active_call()
    sibling = endpoint()

    assert {:error, :not_media_endpoint} =
             ConversationServer.set_call_mute(
               conv.conversation_id,
               p1,
               sibling,
               "p1-sibling",
               attempt,
               true
             )

    assert {:error, :not_media_endpoint} =
             ConversationServer.signal_call(
               conv.conversation_id,
               p1,
               sibling,
               "p1-sibling",
               attempt,
               1,
               %{"type" => "offer", "sdp" => "sibling-must-not-route"}
             )

    assert {:ok, state} = ConversationServer.get_call_state(conv.conversation_id, p1)
    assert state.status == "ACTIVE"
    assert state.self_muted == false

    assert {:ok, %{is_muted: true}} =
             ConversationServer.set_call_mute(
               conv.conversation_id,
               p1,
               owner,
               "p1-owner",
               attempt,
               true
             )
  end

  test "sibling tab cannot obtain relay credentials or control active media" do
    %{conv: conv, p1: p1, attempt: attempt} = active_call()
    sibling = endpoint()

    assert {:error, :not_media_endpoint} =
             ConversationServer.request_call_credentials(
               conv.conversation_id,
               p1,
               sibling,
               "p1-sibling",
               attempt
             )

    assert {:error, :not_media_endpoint} =
             ConversationServer.request_call_media(
               conv.conversation_id,
               p1,
               sibling,
               "p1-sibling",
               attempt,
               :video_upgrade,
               %{}
             )

    assert {:error, :not_media_endpoint} =
             ConversationServer.return_to_voice(
               conv.conversation_id,
               p1,
               sibling,
               "p1-sibling",
               attempt
             )
  end

  test "sibling tab cannot terminate the owner's active call" do
    %{conv: conv, p1: p1, p1_owner: owner, attempt: attempt} = active_call()
    sibling = endpoint()

    assert {:error, :not_media_endpoint} =
             ConversationServer.end_call(
               conv.conversation_id,
               p1,
               sibling,
               "p1-sibling",
               attempt
             )

    assert {:ok, state} = ConversationServer.get_call_state(conv.conversation_id, p1)
    assert state.status == "ACTIVE"

    assert :ok =
             ConversationServer.end_call(
               conv.conversation_id,
               p1,
               owner,
               "p1-owner",
               attempt
             )
  end
end
