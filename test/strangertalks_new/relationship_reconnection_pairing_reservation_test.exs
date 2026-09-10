defmodule StrangertalksNew.RelationshipReconnectionPairingReservationTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.{RelationshipReconnections, Repo}

  setup do
    StrangertalksNew.PairingTestIsolation.install!()
    Agent.update(StrangertalksNew.QueueEngine.QueueState, fn _state -> %{} end)
    :ok
  end

  test "successful relationship reconnect claims durable participant pairing reservations" do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, relationship} =
      %StrangertalksNew.Relationship{}
      |> StrangertalksNew.Relationship.changeset(%{
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        relationship_status: :ACTIVE,
        relationship_type: :KEEP_IN_TOUCH,
        created_at: now,
        updated_at: now,
        last_activity_at: now,
        allow_reconnection: true,
        reconnection_eligible: true,
        participant_a_blocked: false,
        participant_b_blocked: false
      })
      |> Repo.insert()

    assert {:ok, %{status: "waiting_for_mutual_availability"}} =
             RelationshipReconnections.start_or_replace(
               relationship.relationship_id,
               a.participant_id,
               :KEEP_IT_LIGHT
             )

    assert {:ok, %{status: "matched", conversation_id: conversation_id}} =
             RelationshipReconnections.start_or_replace(
               relationship.relationship_id,
               b.participant_id,
               :KEEP_IT_LIGHT
             )

    conversation = Repo.get!(StrangertalksNew.Conversation, conversation_id)

    result =
      Repo.query!(
        "SELECT participant_id::text FROM participant_pairing_reservations WHERE match_id = $1 AND released_at IS NULL ORDER BY participant_id::text",
        [Ecto.UUID.dump!(conversation.match_id)]
      )

    assert Enum.map(result.rows, &hd/1) == Enum.sort([a.participant_id, b.participant_id])
  end
end
