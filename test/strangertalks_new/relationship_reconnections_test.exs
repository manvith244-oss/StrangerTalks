defmodule StrangertalksNew.RelationshipReconnectionsTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest
  import Ecto.Query

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{
    Conversation,
    Matching,
    Message,
    Relationship,
    RelationshipReconnectionIntent,
    RelationshipReconnections,
    Repo
  }

  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNewWeb.{ParticipantChannel, UserSocket}

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    fixture = relationship_fixture()
    %{fixture: fixture}
  end

  test "only members can start and payload identity cannot spoof", %{fixture: f} do
    {:ok, outsider} = StrangertalksNew.Participants.create_participant(%{})

    assert {:error, :reconnection_unavailable} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               outsider.participant_id,
               :JUST_TALK
             )

    socket = socket(UserSocket, "participant", %{participant_id: f.a})
    {:ok, _, joined} = subscribe_and_join(socket, ParticipantChannel, "participant:#{f.a}")

    ref =
      push(joined, "bond:reconnect_start", %{
        "relationship_id" => f.relationship.relationship_id,
        "door_type" => "JUST_TALK",
        "participant_id" => f.b
      })

    assert_reply ref, :ok, %{status: "waiting_for_mutual_availability"}

    assert Repo.one!(
             from i in RelationshipReconnectionIntent,
               where: i.relationship_id == ^f.relationship.relationship_id
           ).participant_id == f.a
  end

  test "first intent is private, same Door is idempotent, and changing Door replaces only own state",
       %{fixture: f} do
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")

    assert {:ok, first} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    assert first.status == "waiting_for_mutual_availability"
    refute_receive {:bond_reconnect_matched, _, _, _}, 50

    assert {:ok, same} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    assert same.expires_at == first.expires_at

    assert {:ok, changed} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :EXPLORE
             )

    assert changed.door_type == "EXPLORE"
    assert Repo.aggregate(RelationshipReconnectionIntent, :count, :reconnect_intent_id) == 1
  end

  test "different Doors remain private and create no Match", %{fixture: f} do
    baseline = Repo.aggregate(Matching, :count, :match_id)

    assert {:ok, _} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    assert {:ok, result} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.b,
               :EXPLORE
             )

    assert result == %{
             status: "waiting_for_mutual_availability",
             door_type: "EXPLORE",
             expires_at: result.expires_at
           }

    assert Repo.aggregate(Matching, :count, :match_id) == baseline
    assert {:ok, own_a} = RelationshipReconnections.status(f.relationship.relationship_id, f.a)
    assert own_a.door_type == "JUST_TALK"
    refute Map.has_key?(own_a, :other_door_type)
  end

  test "same Door atomically creates one reconnect Match and Conversation and consumes both intents",
       %{fixture: f} do
    relationship_before = Repo.get!(Relationship, f.relationship.relationship_id)

    assert {:ok, _} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :SOMETHING_REAL
             )

    assert {:ok, %{status: "matched", conversation_id: conversation_id}} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.b,
               :SOMETHING_REAL
             )

    conversation = Repo.get!(Conversation, conversation_id)
    match = Repo.get!(Matching, conversation.match_id)
    assert match.match_strategy == :relationship_reconnect_v1
    assert is_nil(match.compatibility_score)
    assert conversation.relationship_id == f.relationship.relationship_id

    assert Repo.aggregate(
             from(i in RelationshipReconnectionIntent, where: i.status == :CONSUMED),
             :count
           ) == 2

    assert Repo.aggregate(Relationship, :count, :relationship_id) == 1

    assert Repo.get!(Relationship, f.relationship.relationship_id).origin_conversation_id ==
             relationship_before.origin_conversation_id

    assert {:ok, %{conversation_id: ^conversation_id}} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :SOMETHING_REAL
             )
  end

  test "concurrent second-intent attempts still create one Match and one Conversation", %{
    fixture: f
  } do
    assert {:ok, _} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :KEEP_IT_LIGHT
             )

    baseline_matches = Repo.aggregate(Matching, :count, :match_id)
    baseline_conversations = Repo.aggregate(Conversation, :count, :conversation_id)

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          RelationshipReconnections.start_or_replace(
            f.relationship.relationship_id,
            f.b,
            :KEEP_IT_LIGHT
          )
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{status: "matched"}}, &1))
    assert Repo.aggregate(Matching, :count, :match_id) == baseline_matches + 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == baseline_conversations + 1
  end

  test "expired and cancelled intents cannot match and cancel is private and idempotent", %{
    fixture: f
  } do
    assert {:ok, _} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    Repo.update_all(RelationshipReconnectionIntent,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, waiting} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.b,
               :JUST_TALK
             )

    assert waiting.status == "waiting_for_mutual_availability"

    assert {:ok, %{status: "cancelled"}} =
             RelationshipReconnections.cancel(f.relationship.relationship_id, f.b)

    assert {:ok, %{status: "cancelled"}} =
             RelationshipReconnections.cancel(f.relationship.relationship_id, f.b)

    assert {:ok, %{status: "idle"}} =
             RelationshipReconnections.status(f.relationship.relationship_id, f.b)
  end

  test "blocks, queue membership, and active Conversations reject with one safe reason", %{
    fixture: f
  } do
    assert {:ok, _} = StrangertalksNew.MatchingRules.enforce_block(f.a, f.b, "CONVERSATION")

    assert {:error, :reconnection_unavailable} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    Repo.delete_all(StrangertalksNew.MatchingRules.BoundaryBlock)
    Agent.update(QueueState, &Map.put(&1, f.a, %{door_selection: :JUST_TALK}))

    assert {:error, :reconnection_unavailable} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    Agent.update(QueueState, &Map.delete(&1, f.a))

    f.origin_conversation
    |> Conversation.changeset(%{conversation_status: :ACTIVE})
    |> Repo.update!()

    assert {:error, :reconnection_unavailable} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )
  end

  test "all participant tabs receive one safe match event and no unrelated persistence occurs", %{
    fixture: f
  } do
    a1 = joined_socket(f.a)
    _a2 = joined_socket(f.a)
    b1 = joined_socket(f.b)

    first =
      push(a1, "bond:reconnect_start", %{
        "relationship_id" => f.relationship.relationship_id,
        "door_type" => "EXPLORE"
      })

    assert_reply first, :ok, %{status: "waiting_for_mutual_availability"}
    refute_push "match_found", _, 50

    second =
      push(b1, "bond:reconnect_start", %{
        "relationship_id" => f.relationship.relationship_id,
        "door_type" => "EXPLORE"
      })

    assert_reply second, :ok, %{status: "matched"}

    payloads =
      for _ <- 1..3 do
        assert_push "match_found", payload
        payload
      end

    assert Enum.all?(
             payloads,
             &(&1.origin == "bond_reconnect" and &1.status == "matched" and map_size(&1) == 3)
           )

    assert Repo.aggregate(Message, :count, :message_id) == 0
    assert Repo.aggregate(StrangertalksNew.Report, :count, :report_id) == 0
    assert Repo.aggregate(StrangertalksNew.SafetyEvent, :count, :safety_event_id) == 0
    assert Repo.aggregate(StrangertalksNew.SafetyReview, :count, :safety_review_id) == 0
  end

  defp joined_socket(participant_id) do
    socket = socket(UserSocket, "participant", %{participant_id: participant_id})

    {:ok, _, joined} =
      subscribe_and_join(socket, ParticipantChannel, "participant:#{participant_id}")

    joined
  end

  defp relationship_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    attrs = fn strategy ->
      %{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: strategy,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        compatibility_score: Decimal.new("1.0"),
        queue_entry_time: now,
        match_found_time: now,
        queue_duration_seconds: 0,
        conversation_duration_seconds: 0,
        conversation_started: true,
        conversation_completed: true,
        memory_created: false,
        relationship_created: true,
        reconnected_later: false,
        report_generated: false,
        block_generated: false,
        safety_review_required: false,
        learning_processed: false
      }
    end

    {:ok, match} = StrangertalksNew.Matches.create_match(attrs.(:COMPATIBILITY))

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        ended_at: now,
        match_id: match.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        conversation_status: :ENDED,
        door_type: :JUST_TALK,
        ending_type: :NATURAL_END,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: true,
        memory_created: false,
        relationship_created: true,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: true,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 60
      })

    {:ok, relationship} =
      StrangertalksNew.Relationships.create_relationship(%{
        created_at: now,
        updated_at: now,
        accepted_at: now,
        first_conversation_at: now,
        last_conversation_at: now,
        last_activity_at: now,
        relationship_status: :ACTIVE,
        origin_door_type: :JUST_TALK,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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
      })

    %{
      a: a.participant_id,
      b: b.participant_id,
      origin_conversation: conversation,
      relationship: relationship
    }
  end
end
