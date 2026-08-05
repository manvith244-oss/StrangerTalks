# filepath: test/strangertalks_new/memories_test.exs
defmodule StrangertalksNew.ConversationLifecycle.MemoriesTest do
  use StrangertalksNew.DataCase, async: true
  alias StrangertalksNew.ConversationLifecycle.Memories
  alias StrangertalksNew.Memory

  @valid_attrs %{
    memory_status: :ACTIVE,
    memory_type: :REFLECTION,
    title: "A Profound Architectural Horizon Discovery",
    memory_content:
      "Reflecting on how step-by-step structural isolation saves hours of debugging.",
    door_type: :SOMETHING_REAL,
    atmosphere_id: "a0a0a0a0-a0a0-a0a0-a0a0-a0a0a0a0a0a0",
    atmosphere_name: "Grounded Focus room",
    view_count: 1,
    revisited_count: 0,
    memory_significance_score: Decimal.new("0.9500"),
    memory_category: :DISCOVERY,
    learning_processed: false,
    eligible_for_revisit: true
  }

  setup do
    # 1. Generate real parent entries for participants to satisfy FK constraints
    p_a =
      struct(StrangertalksNew.Participant, %{
        participant_id: Ecto.UUID.generate(),
        presence_state: :ONLINE
      })
      |> StrangertalksNew.Repo.insert!()

    p_b =
      struct(StrangertalksNew.Participant, %{
        participant_id: Ecto.UUID.generate(),
        presence_state: :ONLINE
      })
      |> StrangertalksNew.Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    score = Decimal.new("1.0000")

    # 2. Build match through the canonical schema changeset to satisfy required validation loops
    match_attrs = %{
      match_id: Ecto.UUID.generate(),
      participant_a_id: p_a.participant_id,
      participant_b_id: p_b.participant_id,
      door_type: :JUST_TALK,
      match_status: :CREATED,
      match_strategy: :COMPATIBILITY,
      compatibility_score: score,
      opportunity_score: Decimal.new("0.0000"),
      scarcity_adjustment: Decimal.new("0.0000"),
      conversation_temperature: Decimal.new("0.5000"),
      mutual_participation_score: Decimal.new("0.0000"),
      conversation_health_score: Decimal.new("0.0000"),
      match_quality_score: Decimal.new("0.0000"),
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
      learning_processed: false,
      created_at: now
    }

    match =
      %StrangertalksNew.Matching{}
      |> StrangertalksNew.Matching.changeset(match_attrs)
      |> StrangertalksNew.Repo.insert!()

    # 3. Build conversation records cleanly using context wrappers
    {:ok, conversation} =
      StrangertalksNew.ConversationLifecycle.Conversations.create_conversation(%{
        conversation_id: Ecto.UUID.generate(),
        match_id: match.match_id,
        participant_a_id: p_a.participant_id,
        participant_b_id: p_b.participant_id,
        match_strategy_used: :COMPATIBILITY,
        conversation_status: "ACTIVE",
        door_type: "JUST_TALK",
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        message_exchange_rate: 0.0,
        participation_balance_score: Decimal.new("0.5000"),
        conversation_depth_score: Decimal.new("0.0000"),
        conversation_temperature: Decimal.new("0.5000"),
        bridge_effectiveness_score: Decimal.new("1.0000"),
        conversation_success_score: Decimal.new("0.0000"),
        safety_score: Decimal.new("1.0000"),
        safety_flagged: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        relationship_created_at_end: false,
        memory_count: 0,
        report_count: 0,
        block_count: 0,
        learning_processed: false,
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0,
        created_at: now
      })

    {:ok,
     match_id: match.match_id,
     conversation_id: conversation.conversation_id,
     participant_id: p_a.participant_id}
  end

  test "valid changeset pass: inserts row with correct metrics and constraints", context do
    attrs =
      Map.merge(@valid_attrs, %{
        match_id: context.match_id,
        conversation_id: context.conversation_id,
        owner_participant_id: context.participant_id
      })

    assert {:ok, %Memory{} = memory} = Memories.create_memory(attrs)
    assert memory.memory_status == :ACTIVE
    assert memory.memory_type == :REFLECTION
    assert %Decimal{} = memory.memory_significance_score
  end

  test "missing required field fault: constraints protect baseline fields", context do
    attrs = %{conversation_id: context.conversation_id}
    assert {:error, changeset} = Memories.create_memory(attrs)
    assert errors_on(changeset).title == ["can't be blank"]
  end

  test "invalid enum rejection: rejects unmapped state mutations cleanly", context do
    attrs =
      Map.merge(@valid_attrs, %{
        match_id: context.match_id,
        conversation_id: context.conversation_id,
        owner_participant_id: context.participant_id,
        memory_status: "INVALID_STATUS_VALUE"
      })

    assert {:error, changeset} = Memories.create_memory(attrs)
    assert errors_on(changeset).memory_status == ["is invalid"]
  end

  test "soft delete logic filter: excluded from retrieval query structures", context do
    attrs =
      Map.merge(@valid_attrs, %{
        match_id: context.match_id,
        conversation_id: context.conversation_id,
        owner_participant_id: context.participant_id,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    assert {:ok, %Memory{} = memory} = Memories.create_memory(attrs)
    assert is_nil(Memories.get_memory(memory.memory_id))
  end
end
