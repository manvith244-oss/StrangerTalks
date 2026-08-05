defmodule StrangertalksNew.MessageReactionTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.MessageReactions
  alias StrangertalksNew.MessageReaction

  @valid_time DateTime.from_naive!(~N[2026-07-03 01:45:00.000000], "Etc/UTC")

  setup do
    {:ok, participant} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, participant_b} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :JUST_TALK,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: @valid_time,
        queue_entry_time: @valid_time,
        match_found_time: @valid_time,
        compatibility_score: Decimal.new("0.8500"),
        opportunity_score: Decimal.new("0.7500"),
        scarcity_adjustment: Decimal.new("0.0000"),
        conversation_temperature: Decimal.new("0.5000"),
        mutual_participation_score: Decimal.new("0.8000"),
        conversation_health_score: Decimal.new("0.8500"),
        match_quality_score: Decimal.new("0.8200"),
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false,
        reconnected_later: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        match_id: match.match_id,
        participant_a_id: participant.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
        created_at: @valid_time,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        # float
        average_response_time: 0.0,
        # decimal
        participation_balance_score: Decimal.new("0.5000"),
        # float
        message_exchange_rate: 0.0,
        # decimal
        conversation_depth_score: Decimal.new("0.5000"),
        # decimal
        conversation_temperature: Decimal.new("0.5000"),
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        # decimal
        bridge_effectiveness_score: Decimal.new("0.0000"),
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        # ✅ already present
        reconnected_later: false,
        # decimal
        conversation_success_score: Decimal.new("0.0000"),
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        # decimal
        safety_score: Decimal.new("0.0000"),
        learning_processed: false,
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    {:ok, message} =
      StrangertalksNew.Messages.create_message(%{
        conversation_id: conversation.conversation_id,
        sender_id: participant.participant_id,
        content: "Organic Presence",
        expected_sequence_id: 1,
        created_at: @valid_time
      })

    valid_attrs = %{
      message_id: message.message_id,
      participant_id: participant.participant_id,
      emoji_unicode: "❤️",
      lifecycle_action: :ATTACH,
      created_at: @valid_time,
      updated_at: @valid_time
    }

    {:ok, valid_attrs: valid_attrs}
  end

  test "create_message_reaction/1 with valid parameters persists successfully", %{
    valid_attrs: attrs
  } do
    assert {:ok, %MessageReaction{} = reaction} =
             MessageReactions.create_message_reaction(attrs)

    assert reaction.emoji_unicode == "❤️"
  end

  test "change_message_reaction/2 computes changeset mutations tracking details", %{
    valid_attrs: attrs
  } do
    {:ok, reaction} = MessageReactions.create_message_reaction(attrs)
    changeset = MessageReactions.change_message_reaction(reaction, %{lifecycle_action: :DETACH})
    assert changeset.changes == %{lifecycle_action: :DETACH}
  end
end
