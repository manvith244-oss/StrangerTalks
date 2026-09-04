defmodule StrangertalksNew.Team4MainlineBlockRetryTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{Conversation, Conversations, Matches, Participants, Repo}
  alias StrangertalksNew.MatchingRules
  alias StrangertalksNew.MatchingRules.BoundaryBlock

  test "repeated Block does not rebroadcast terminal authority after the first applied action" do
    {conversation, participant_a} = conversation_fixture()
    topic = "conversation:#{conversation.conversation_id}"
    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, topic)

    assert {:ok, _block} =
             MatchingRules.block_conversation_participant(
               conversation.conversation_id,
               participant_a.participant_id
             )

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "conversation:ended"}

    assert {:ok, _same_block} =
             MatchingRules.block_conversation_participant(
               conversation.conversation_id,
               participant_a.participant_id
             )

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "conversation:ended"}, 100
    assert Repo.aggregate(BoundaryBlock, :count) == 1
  end

  defp conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()
    now = DateTime.utc_now()

    {:ok, matching} =
      Matches.create_match(%{
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
      Conversations.create_conversation(%{
        created_at: now,
        match_id: matching.match_id,
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

    {conversation, participant_a}
  end

  defp participant_fixture do
    {:ok, participant} =
      Participants.create_participant(%{
        presence_state: :ONLINE,
        created_at: DateTime.utc_now(),
        last_active_at: DateTime.utc_now()
      })

    participant
  end
end
