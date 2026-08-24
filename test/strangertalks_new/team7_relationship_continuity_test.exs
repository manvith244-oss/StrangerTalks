defmodule StrangertalksNew.Team7RelationshipContinuityTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{
    Conversation,
    MatchingRules,
    Relationship,
    RelationshipConsent,
    RelationshipReconnections,
    Relationships,
    Repo
  }

  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "durable bilateral safety veto prevents Bond consent from becoming durable" do
    {conversation, participant_a, participant_b} = completed_conversation_fixture()

    assert {:ok, _block} =
             MatchingRules.enforce_block(
               participant_a.participant_id,
               participant_b.participant_id,
               "TEAM7_TEST"
             )

    assert {:error, :relationship_unavailable} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_a.participant_id
             )

    assert Repo.aggregate(RelationshipConsent, :count) == 0
    assert Repo.aggregate(Relationship, :count) == 0
  end

  test "a closed relationship is a bilateral veto for later Bond consent" do
    {conversation, participant_a, participant_b} = completed_conversation_fixture()

    assert {:ok, %{status: "waiting_for_mutual_consent"}} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_a.participant_id
             )

    assert {:ok, %{status: "created", relationship_id: relationship_id}} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_b.participant_id
             )

    assert {:ok, %{status: "closed"}} =
             Relationships.close_relationship(
               relationship_id,
               participant_a.participant_id,
               :PARTICIPANT_CLOSED
             )

    assert {:error, :relationship_unavailable} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_a.participant_id
             )

    relationship = Repo.get!(Relationship, relationship_id)
    assert relationship.relationship_status == :CLOSED
    assert relationship.allow_reconnection == false
    assert relationship.reconnection_eligible == false
    assert Repo.aggregate(Relationship, :count) == 1
  end

  test "Block racing final mutual consent has one serialized safety-safe outcome" do
    {conversation, participant_a, participant_b} = completed_conversation_fixture()

    assert {:ok, %{status: "waiting_for_mutual_consent"}} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_a.participant_id
             )

    parent = self()

    consent_task =
      Task.async(fn ->
        send(parent, {:ready, :consent})

        receive do
          :go ->
            Relationships.consent_to_relationship(
              conversation.conversation_id,
              participant_b.participant_id
            )
        end
      end)

    block_task =
      Task.async(fn ->
        send(parent, {:ready, :block})

        receive do
          :go ->
            MatchingRules.enforce_block(
              participant_a.participant_id,
              participant_b.participant_id,
              "TEAM7_RACE"
            )
        end
      end)

    assert_receive {:ready, :consent}
    assert_receive {:ready, :block}
    send(consent_task.pid, :go)
    send(block_task.pid, :go)

    consent_result = Task.await(consent_task, 5_000)
    assert {:ok, _block} = Task.await(block_task, 5_000)

    assert consent_result in [
             {:error, :relationship_unavailable},
             {:ok, %{status: "created", relationship_id: relationship_id(consent_result)}}
           ]

    assert MatchingRules.check_safety_veto?(
             participant_a.participant_id,
             participant_b.participant_id
           )

    # A stale request arriving after the durable Block can never create/re-open a Bond.
    assert {:error, :relationship_unavailable} =
             Relationships.consent_to_relationship(
               conversation.conversation_id,
               participant_b.participant_id
             )

    assert Repo.aggregate(Relationship, :count) <= 1

    case Repo.one(Relationship) do
      nil ->
        :ok

      relationship ->
        assert {:error, :reconnection_unavailable} =
                 RelationshipReconnections.start_or_replace(
                   relationship.relationship_id,
                   participant_a.participant_id,
                   :EXPLORE
                 )
    end
  end

  defp relationship_id({:ok, %{relationship_id: relationship_id}}), do: relationship_id
  defp relationship_id(_), do: nil

  defp completed_conversation_fixture do
    participant_a = participant_fixture()
    participant_b = participant_fixture()

    {:ok, _} =
      MatchmakingEngine.join_queue(participant_a.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, _} =
      MatchmakingEngine.join_queue(participant_b.participant_id, :EXPLORE, "en", 7, 120.0)

    {:ok, [_]} = MatchmakingEngine.evaluate_pending_matches()
    conversation = Repo.one!(from c in Conversation, order_by: [desc: c.created_at], limit: 1)

    conversation =
      conversation
      |> Conversation.changeset(%{
        conversation_status: :ENDED,
        conversation_completed: true,
        ending_type: :NATURAL_END,
        ended_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {conversation, participant_a, participant_b}
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end
end
