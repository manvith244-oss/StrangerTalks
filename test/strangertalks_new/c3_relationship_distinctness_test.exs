defmodule StrangertalksNew.C3RelationshipDistinctnessTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Relationships
  alias StrangertalksNew.Repo

  test "Relationship application authority rejects one participant in both roles" do
    attrs = relationship_attrs_fixture()
    invalid = Map.put(attrs, :participant_b_id, attrs.participant_a_id)

    assert {:error, changeset} = Relationships.create_relationship(invalid)
    assert "must identify two different participants" in errors_on(changeset).participant_b_id
  end

  test "PostgreSQL rejects a direct self-Relationship bypass" do
    attrs = relationship_attrs_fixture()
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

  defp relationship_attrs_fixture do
    now = DateTime.utc_now()
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{created_at: now})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{created_at: now})

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        door_type: :SOMETHING_REAL,
        match_status: :ACTIVE,
        match_strategy: :COMPATIBILITY,
        created_at: now,
        queue_entry_time: now,
        match_found_time: now,
        compatibility_score: "0.9500",
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
        created_at: now,
        door_type: :SOMETHING_REAL,
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
      created_at: now,
      updated_at: now,
      first_conversation_at: now,
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
      private_note_count: 0
    }
  end
end
