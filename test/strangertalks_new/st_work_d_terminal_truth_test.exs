defmodule StrangertalksNew.STWorkDTerminalTruthTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.Transitions
  alias StrangertalksNew.{Conversations, Matching, Participants, Repo}

  test "durable terminal truth rejects a stale non-terminal transition" do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    matching = match_fixture(participant_a.participant_id, participant_b.participant_id)

    {:ok, active_conversation} =
      Conversations.create_conversation(%{
        match_id: matching.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
        door_type: :EXPLORE,
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
        duration_seconds: 0,
        created_at: DateTime.utc_now()
      })

    stale_active = active_conversation

    assert {:ok, ended} =
             Transitions.transition(active_conversation, :participant_completed, %{
               ending_initiator: participant_a.participant_id
             })

    assert ended.conversation_status == :ENDED
    assert ended.ending_type == :NATURAL_END

    assert {:error, {:invalid_transition, :ENDED, :participant_disconnected}} =
             Transitions.transition(stale_active, :participant_disconnected)

    canonical = Repo.get!(Conversation, active_conversation.conversation_id)
    assert canonical.conversation_status == :ENDED
    assert canonical.ending_type == :NATURAL_END
    assert canonical.ending_initiator == participant_a.participant_id
    assert canonical.conversation_completed == true
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp match_fixture(participant_a_id, participant_b_id) do
    now = DateTime.utc_now()
    score = Decimal.new("1.0")

    %Matching{}
    |> Matching.changeset(%{
      created_at: now,
      participant_a_id: participant_a_id,
      participant_b_id: participant_b_id,
      door_type: :EXPLORE,
      conversation_language: "en",
      match_status: :ACTIVE,
      match_strategy: :COMPATIBILITY,
      compatibility_score: score,
      queue_entry_time: now,
      match_found_time: now,
      queue_duration_seconds: 0,
      conversation_duration_seconds: 0,
      conversation_started: true,
      conversation_completed: false,
      memory_created: false,
      relationship_created: false,
      reconnected_later: false,
      report_generated: false,
      block_generated: false,
      safety_review_required: false,
      learning_processed: false
    })
    |> Repo.insert!()
  end
end
