defmodule StrangertalksNew.ConversationTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.Conversations
  alias StrangertalksNew.Conversation

  @valid_time DateTime.from_naive!(~N[2026-07-03 02:00:00.000000], "Etc/UTC")

  setup do
    {:ok, participant_a} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, participant_b} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant_a.participant_id,
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
        learning_version: "v1",
        # ✅ added to fix "can't be blank"
        reconnected_later: false
      })

    valid_attrs = %{
      match_id: match.match_id,
      participant_a_id: participant_a.participant_id,
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
      learning_version: "1.0.0",
      duration_seconds: 0,
      time_to_first_message_seconds: 0,
      time_to_first_reply_seconds: 0,
      longest_silence_seconds: 0
    }

    {:ok, valid_attrs: valid_attrs}
  end

  test "create_conversation/1 with valid attributes persists successfully", %{valid_attrs: attrs} do
    assert {:ok, %Conversation{} = conv} = Conversations.create_conversation(attrs)
    assert conv.conversation_status == :ACTIVE
  end

  test "change_conversation/2 tracks changes correctly", %{valid_attrs: attrs} do
    {:ok, conv} = Conversations.create_conversation(attrs)
    changeset = Conversations.change_conversation(conv, %{conversation_status: :COMPLETED})
    assert changeset.changes == %{conversation_status: :COMPLETED}
  end
end
