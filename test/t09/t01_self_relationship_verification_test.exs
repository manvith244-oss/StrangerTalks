defmodule StrangertalksNew.T09SelfRelationshipVerificationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{Relationship, Relationships, Repo}

  @valid_time DateTime.from_naive!(~N[2026-07-03 00:00:00.000000], "Etc/UTC")

  setup do
    {:ok, participant_a} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, participant_b} =
      StrangertalksNew.Participants.create_participant(%{created_at: @valid_time})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :SOMETHING_REAL,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: @valid_time,
        queue_entry_time: @valid_time,
        match_found_time: @valid_time,
        compatibility_score: "0.9500",
        opportunity_score: "0.8500",
        scarcity_adjustment: "0.0000",
        conversation_temperature: "0.5000",
        mutual_participation_score: "0.9000",
        conversation_health_score: "0.9200",
        match_quality_score: "0.9400",
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
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :ACTIVE,
        created_at: @valid_time,
        door_type: :SOMETHING_REAL,
        message_count: 0,
        voice_note_count: 0,
        average_response_time: 0.0,
        participation_balance_score: "0.5000",
        message_exchange_rate: 0.0,
        conversation_depth_score: "0.5000",
        conversation_temperature: "0.5000",
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        bridge_effectiveness_score: "0.0000",
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        conversation_success_score: "0.0000",
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        safety_score: "0.0000",
        learning_processed: false,
        duration_seconds: 0,
        time_to_first_message_seconds: 0,
        time_to_first_reply_seconds: 0,
        longest_silence_seconds: 0
      })

    attrs = %{
      created_at: @valid_time,
      updated_at: @valid_time,
      first_conversation_at: @valid_time,
      relationship_status: :ACTIVE,
      origin_door_type: :SOMETHING_REAL,
      participant_a_id: participant_a.participant_id,
      participant_b_id: participant_b.participant_id,
      origin_conversation_id: conversation.conversation_id,
      origin_match_id: match.match_id,
      participant_a_accepted: true,
      participant_b_accepted: true,
      allow_reconnection: true,
      reconnection_eligible: true,
      participant_a_closed: false,
      participant_b_closed: false,
      participant_a_blocked: false,
      participant_b_blocked: false,
      learning_processed: false,
      conversation_count: 1,
      memory_count: 0,
      reconnection_count: 0,
      shared_memory_count: 0,
      private_note_count: 0,
      reconnection_priority: "0.7500",
      relationship_strength_score: "0.8500",
      continuation_probability: "0.9000",
      relationship_temperature: "0.6500",
      atmosphere_history: %{"history" => []},
      relationship_summary: %{"summary" => "t09"}
    }

    {:ok, attrs: attrs}
  end

  test "V1/V2 rejects self relationship before durable insert with participant-boundary error", %{attrs: attrs} do
    before_count = Repo.aggregate(Relationship, :count, :relationship_id)
    invalid = Map.put(attrs, :participant_b_id, attrs.participant_a_id)

    assert {:error, changeset} = Relationships.create_relationship(invalid)
    assert "must identify two different participants" in errors_on(changeset).participant_b_id
    assert Repo.aggregate(Relationship, :count, :relationship_id) == before_count
  end

  test "V4 valid distinct relationship still persists", %{attrs: attrs} do
    assert {:ok, %Relationship{} = relationship} = Relationships.create_relationship(attrs)
    assert relationship.participant_a_id != relationship.participant_b_id
  end

  test "V5 reversed ordering preserves existing canonical-pair uniqueness", %{attrs: attrs} do
    assert {:ok, %Relationship{}} = Relationships.create_relationship(attrs)

    reversed =
      attrs
      |> Map.put(:participant_a_id, attrs.participant_b_id)
      |> Map.put(:participant_b_id, attrs.participant_a_id)

    assert {:error, %Ecto.Changeset{}} = Relationships.create_relationship(reversed)
  end

  test "V7 public changeset update path rejects mutation to self relationship", %{attrs: attrs} do
    assert {:ok, relationship} = Relationships.create_relationship(attrs)

    changeset =
      Relationships.change_relationship(relationship, %{participant_b_id: relationship.participant_a_id})

    refute changeset.valid?
    assert "must identify two different participants" in errors_on(changeset).participant_b_id
    assert {:error, %Ecto.Changeset{}} = Repo.update(changeset)
  end

  test "V3/V7 PostgreSQL rejects direct bypass update on named check constraint", %{attrs: attrs} do
    assert {:ok, relationship} = Relationships.create_relationship(attrs)

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :check_violation,
                constraint: "relationships_distinct_participants_check"
              }
            }} =
             Repo.query(
               "UPDATE relationships SET participant_b_id = participant_a_id WHERE relationship_id = $1",
               [Ecto.UUID.dump!(relationship.relationship_id)]
             )
  end
end
