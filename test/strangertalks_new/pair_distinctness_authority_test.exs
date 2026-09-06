defmodule StrangertalksNew.PairDistinctnessAuthorityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Conversations
  alias StrangertalksNew.Matches
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Repo

  test "valid A/B Match and matching A/B Conversation persist" do
    a = participant_fixture()
    b = participant_fixture()

    assert {:ok, %Matching{} = match} = create_match(a.participant_id, b.participant_id)

    assert {:ok, %Conversation{} = conversation} =
             create_conversation(match.match_id, a.participant_id, b.participant_id)

    assert conversation.match_id == match.match_id
    assert conversation.participant_a_id == match.participant_a_id
    assert conversation.participant_b_id == match.participant_b_id
  end

  test "Match application authority rejects one participant in both roles" do
    participant = participant_fixture()

    assert {:error, changeset} =
             create_match(participant.participant_id, participant.participant_id)

    assert "must identify two different participants" in errors_on(changeset).participant_b_id
  end

  test "Conversation application authority rejects one participant in both roles" do
    a = participant_fixture()
    b = participant_fixture()
    {:ok, match} = create_match(a.participant_id, b.participant_id)

    assert {:error, changeset} =
             create_conversation(match.match_id, a.participant_id, a.participant_id)

    assert "must identify two different participants" in errors_on(changeset).participant_b_id
  end

  test "Conversation application authority rejects participants that disagree with its Match" do
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()
    {:ok, match} = create_match(a.participant_id, b.participant_id)

    assert {:error, changeset} =
             create_conversation(match.match_id, a.participant_id, c.participant_id)

    assert "does not match durable Match participants" in errors_on(changeset).match_id
  end

  test "PostgreSQL rejects a direct self-Match bypass" do
    a = participant_fixture()
    b = participant_fixture()
    {:ok, match} = create_match(a.participant_id, b.participant_id)

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "matches_distinct_participants_check"}
            }} =
             Repo.query(
               "UPDATE matches SET participant_b_id = participant_a_id WHERE match_id = $1",
               [Ecto.UUID.dump!(match.match_id)]
             )
  end

  test "PostgreSQL rejects a direct self-Conversation bypass" do
    a = participant_fixture()
    b = participant_fixture()
    {:ok, match} = create_match(a.participant_id, b.participant_id)
    {:ok, conversation} = create_conversation(match.match_id, a.participant_id, b.participant_id)

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :check_violation,
                constraint: "conversations_distinct_participants_check"
              }
            }} =
             Repo.query(
               "UPDATE conversations SET participant_b_id = participant_a_id WHERE conversation_id = $1",
               [Ecto.UUID.dump!(conversation.conversation_id)]
             )
  end

  test "PostgreSQL rejects a Conversation participant tuple that disagrees with its Match" do
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()
    {:ok, match} = create_match(a.participant_id, b.participant_id)
    {:ok, conversation} = create_conversation(match.match_id, a.participant_id, b.participant_id)

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :foreign_key_violation,
                constraint: "conversations_match_participants_fkey"
              }
            }} =
             Repo.query(
               "UPDATE conversations SET participant_b_id = $1 WHERE conversation_id = $2",
               [Ecto.UUID.dump!(c.participant_id), Ecto.UUID.dump!(conversation.conversation_id)]
             )
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp create_match(participant_a_id, participant_b_id) do
    now = DateTime.utc_now()

    Matches.create_match(%{
      created_at: now,
      door_type: :EXPLORE,
      participant_a_door_type: :EXPLORE,
      participant_b_door_type: :EXPLORE,
      match_status: :CREATED,
      match_strategy: :COMPATIBILITY,
      participant_a_id: participant_a_id,
      participant_b_id: participant_b_id,
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
  end

  defp create_conversation(match_id, participant_a_id, participant_b_id) do
    Conversations.create_conversation(%{
      created_at: DateTime.utc_now(),
      match_id: match_id,
      participant_a_id: participant_a_id,
      participant_b_id: participant_b_id,
      conversation_status: :PENDING,
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
      duration_seconds: 0
    })
  end
end
