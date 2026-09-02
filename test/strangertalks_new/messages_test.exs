defmodule StrangertalksNew.MessagesTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.Messages
  alias StrangertalksNew.Message

  @valid_attrs %{
    content: "Hello, this is a secure anonymous transmission.",
    expected_sequence_id: 1,
    is_edited: false,
    edit_count: 0
  }

  setup do
    {:ok, p_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, p_b} = StrangertalksNew.Participants.create_participant(%{})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: DateTime.utc_now(),
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        compatibility_score: Decimal.new("0.9500"),
        opportunity_score: Decimal.new("0.8500"),
        scarcity_adjustment: Decimal.new("0.0000"),
        conversation_temperature: Decimal.new("0.5000"),
        mutual_participation_score: Decimal.new("0.7000"),
        conversation_health_score: Decimal.new("1.0000"),
        match_quality_score: Decimal.new("0.9200"),
        queue_entry_time: DateTime.utc_now(),
        match_found_time: DateTime.utc_now(),
        queue_duration_seconds: 45,
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
        created_at: DateTime.utc_now(),
        match_id: match.match_id,
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        conversation_status: :ACTIVE,
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
        conversation_depth_score: Decimal.new("0.0000"),
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
        reconnected_later: false,
        # decimal
        conversation_success_score: Decimal.new("0.0000"),
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        # decimal
        safety_score: Decimal.new("1.0000"),
        learning_processed: false,
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    {:ok, conversation_id: conversation.conversation_id, sender_id: p_a.participant_id}
  end

  test "valid changeset pass: inserts row with correct metrics and relationships", context do
    attrs =
      Map.merge(@valid_attrs, %{
        conversation_id: context.conversation_id,
        sender_id: context.sender_id
      })

    assert {:ok, %Message{} = message} = Messages.create_message(attrs)
    assert message.content == "Hello, this is a secure anonymous transmission."
    assert message.expected_sequence_id == 1
    assert message.is_edited == false
  end

  test "missing required field fault: validation catches empty values", context do
    attrs = %{conversation_id: context.conversation_id}
    assert {:error, changeset} = Messages.create_message(attrs)
    assert errors_on(changeset).content == ["can't be blank"]
  end

  test "foreign key isolation pass: schema handles invalid mapping values cleanly", context do
    bad_uuid = Ecto.UUID.generate()

    attrs =
      Map.merge(@valid_attrs, %{
        conversation_id: bad_uuid,
        sender_id: context.sender_id
      })

    assert {:error, changeset} = Messages.create_message(attrs)
    assert {:error, _} = Repo.insert(changeset)
  end
end
