defmodule StrangertalksNew.RelationshipReconnectionsTest do
  use StrangertalksNew.DataCase, async: false
  import Phoenix.ChannelTest
  import Ecto.Query

  @endpoint StrangertalksNewWeb.Endpoint

  alias StrangertalksNew.{
    Conversation,
    Matching,
    Message,
    Memory,
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
        "door_type" => "JUST_TALK"
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

  test "blocks and active Conversations reject while queue intent remains noncanonical", %{
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

    Agent.update(
      QueueState,
      &Map.put(&1, f.a, %{
        door_selection: :JUST_TALK,
        queue_attempt_id: Ecto.UUID.generate()
      })
    )

    assert {:ok, %{status: "waiting_for_mutual_availability"}} =
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
    assert Repo.aggregate(Memory, :count, :memory_id) == 0
  end

  test "reverse block direction and a committed later block return only the safe error", %{
    fixture: f
  } do
    assert {:ok, _} = StrangertalksNew.MatchingRules.enforce_block(f.b, f.a, "CONVERSATION")

    assert {:error, :reconnection_unavailable} =
             RelationshipReconnections.start_or_replace(
               f.relationship.relationship_id,
               f.a,
               :JUST_TALK
             )

    Repo.delete_all(StrangertalksNew.MatchingRules.BoundaryBlock)
    assert {:ok, _} = reconnect(f, f.a, :JUST_TALK)
    assert {:ok, %{status: "matched"}} = reconnect(f, f.b, :JUST_TALK)
    assert {:ok, _} = StrangertalksNew.MatchingRules.enforce_block(f.a, f.b, "CONVERSATION")

    assert {:error, :reconnection_unavailable} = reconnect(f, f.a, :JUST_TALK)

    assert {:error, :reconnection_unavailable} =
             RelationshipReconnections.status(f.relationship.relationship_id, f.b)
  end

  test "queued counterparts do not outrank reconnect and converge after commit", %{fixture: f} do
    assert {:ok, _} = reconnect(f, f.a, :EXPLORE)

    Agent.update(
      QueueState,
      &Map.put(&1, f.b, %{
        door_selection: :EXPLORE,
        queue_attempt_id: Ecto.UUID.generate()
      })
    )

    assert {:ok, %{status: "matched"}} = reconnect(f, f.b, :EXPLORE)
    refute Agent.get(QueueState, &Map.has_key?(&1, f.b))
    assert Repo.aggregate(Matching, :count, :match_id) == 2
  end

  test "queue join racing reconnect leaves exactly one participant activity", %{fixture: f} do
    assert {:ok, _} = reconnect(f, f.a, :KEEP_IT_LIGHT)

    [reconnect_result, queue_result] =
      [
        fn -> reconnect(f, f.b, :KEEP_IT_LIGHT) end,
        fn ->
          StrangertalksNew.Matchmaking.MatchmakingEngine.join_queue(
            f.b,
            :KEEP_IT_LIGHT,
            "en",
            nil,
            nil
          )
        end
      ]
      |> Task.async_stream(& &1.(), ordered: true, timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    conversation_created? = Repo.aggregate(Conversation, :count, :conversation_id) == 2
    queued? = Agent.get(QueueState, &Map.has_key?(&1, f.b))
    assert conversation_created? != queued?

    if conversation_created? do
      assert match?({:ok, %{status: "matched"}}, reconnect_result)
      assert match?({:ok, _}, queue_result) or match?({:error, :participant_busy}, queue_result)
      refute Agent.get(QueueState, &Map.has_key?(&1, f.b))
    else
      assert match?({:error, :reconnection_unavailable}, reconnect_result)
      assert match?({:ok, _}, queue_result)
    end
  end

  test "anonymous A+C racing reconnect A+B creates at most one current Conversation", %{
    fixture: f
  } do
    {:ok, c} = StrangertalksNew.Participants.create_participant(%{})
    assert {:ok, _} = reconnect(f, f.a, :KEEP_IT_LIGHT)

    assert {:ok, _} =
             StrangertalksNew.Matchmaking.MatchmakingEngine.join_queue(
               f.a,
               :KEEP_IT_LIGHT,
               "en",
               nil,
               nil
             )

    assert {:ok, _} =
             StrangertalksNew.Matchmaking.MatchmakingEngine.join_queue(
               c.participant_id,
               :KEEP_IT_LIGHT,
               "en",
               nil,
               nil
             )

    baseline_matches = Repo.aggregate(Matching, :count, :match_id)
    baseline_conversations = Repo.aggregate(Conversation, :count, :conversation_id)

    [anonymous_result, reconnect_result] =
      [
        &StrangertalksNew.Matchmaking.MatchmakingEngine.evaluate_pending_matches/0,
        fn -> reconnect(f, f.b, :KEEP_IT_LIGHT) end
      ]
      |> Task.async_stream(& &1.(), ordered: true, timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    assert match?({:ok, _}, anonymous_result)

    assert match?({:ok, _}, reconnect_result) or
             match?({:error, :reconnection_unavailable}, reconnect_result)

    assert Repo.aggregate(Matching, :count, :match_id) == baseline_matches + 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == baseline_conversations + 1
    assert current_conversation_count(f.a) == 1
  end

  test "anonymous A+B racing reconnect A+B creates at most one current Conversation", %{
    fixture: f
  } do
    assert {:ok, _} = reconnect(f, f.a, :SOMETHING_REAL)

    for participant_id <- [f.a, f.b] do
      assert {:ok, _} =
               StrangertalksNew.Matchmaking.MatchmakingEngine.join_queue(
                 participant_id,
                 :SOMETHING_REAL,
                 "en",
                 nil,
                 nil
               )
    end

    baseline_matches = Repo.aggregate(Matching, :count, :match_id)
    baseline_conversations = Repo.aggregate(Conversation, :count, :conversation_id)

    _results =
      [
        &StrangertalksNew.Matchmaking.MatchmakingEngine.evaluate_pending_matches/0,
        fn -> reconnect(f, f.b, :SOMETHING_REAL) end
      ]
      |> Task.async_stream(& &1.(), timeout: :infinity)
      |> Enum.to_list()

    assert Repo.aggregate(Matching, :count, :match_id) == baseline_matches + 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == baseline_conversations + 1
    assert current_conversation_count(f.a) == 1
    assert current_conversation_count(f.b) == 1
  end

  test "another pending Conversation racing reconnect creates only one activity path", %{
    fixture: f
  } do
    assert {:ok, _} = reconnect(f, f.a, :SOMETHING_REAL)

    {:ok, alternate_match} =
      StrangertalksNew.Matches.create_match(match_attrs(f, :COMPATIBILITY, Decimal.new("1.0")))

    results =
      [
        fn -> reconnect(f, f.b, :SOMETHING_REAL) end,
        fn ->
          StrangertalksNew.Conversations.create_conversation(
            pending_conversation_attrs(f, alternate_match)
          )
        end
      ]
      |> Task.async_stream(& &1.(), timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 2
  end

  test "Door change and cancel leave the counterpart intent unchanged", %{fixture: f} do
    assert {:ok, _} = reconnect(f, f.a, :JUST_TALK)
    assert {:ok, _} = reconnect(f, f.b, :EXPLORE)
    counterpart = active_intent(f, f.b)

    assert {:ok, _} = reconnect(f, f.a, :SOMETHING_REAL)
    assert active_intent(f, f.b) == counterpart

    assert {:ok, %{status: "cancelled"}} =
             RelationshipReconnections.cancel(f.relationship.relationship_id, f.a)

    assert active_intent(f, f.b) == counterpart
  end

  test "consumed intents cannot be reused after the reconnect Conversation ends", %{fixture: f} do
    assert {:ok, _} = reconnect(f, f.a, :JUST_TALK)
    assert {:ok, %{conversation_id: conversation_id}} = reconnect(f, f.b, :JUST_TALK)

    Repo.get!(Conversation, conversation_id)
    |> Conversation.changeset(%{conversation_status: :ENDED})
    |> Repo.update!()

    assert {:ok, %{status: "waiting_for_mutual_availability"}} = reconnect(f, f.a, :JUST_TALK)

    assert Repo.aggregate(
             from(i in RelationshipReconnectionIntent, where: i.status == :CONSUMED),
             :count
           ) == 2

    assert Repo.aggregate(Matching, :count, :match_id) == 2
  end

  test "late PostgreSQL failure rolls back Match Conversation intent and Relationship changes", %{
    fixture: f
  } do
    assert {:ok, _} = reconnect(f, f.a, :EXPLORE)
    before = Repo.get!(Relationship, f.relationship.relationship_id)

    Repo.update_all(from(r in Relationship, where: r.relationship_id == ^before.relationship_id),
      set: [conversation_count: 2_147_483_647]
    )

    assert_raise DBConnection.EncodeError, fn -> reconnect(f, f.b, :EXPLORE) end
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1

    assert Repo.aggregate(
             from(i in RelationshipReconnectionIntent, where: i.status == :CONSUMED),
             :count
           ) == 0

    after_failure = Repo.get!(Relationship, before.relationship_id)
    assert after_failure.conversation_count == 2_147_483_647
    assert after_failure.last_conversation_at == before.last_conversation_at
  end

  test "forced reconnect Match insert failure creates neither new Match nor Conversation", %{
    fixture: f
  } do
    assert {:ok, _} = reconnect(f, f.a, :EXPLORE)
    force_insert_failure!("matches")

    assert {:error, :reconnection_unavailable} = reconnect(f, f.b, :EXPLORE)
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
  end

  test "forced reconnect Conversation insert failure rolls back new Match", %{fixture: f} do
    assert {:ok, _} = reconnect(f, f.a, :EXPLORE)
    force_insert_failure!("conversations")

    assert {:error, :reconnection_unavailable} = reconnect(f, f.b, :EXPLORE)
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
  end

  test "Relationship lifecycle advances once and every unbuilt Match metric stays nil", %{
    fixture: f
  } do
    before = Repo.get!(Relationship, f.relationship.relationship_id)
    assert {:ok, _} = reconnect(f, f.a, :EXPLORE)
    assert {:ok, %{conversation_id: conversation_id}} = reconnect(f, f.b, :EXPLORE)

    conversation = Repo.get!(Conversation, conversation_id)
    match = Repo.get!(Matching, conversation.match_id)
    relationship = Repo.get!(Relationship, before.relationship_id)
    assert relationship.conversation_count == before.conversation_count + 1
    assert relationship.reconnection_count == before.reconnection_count + 1
    assert DateTime.compare(relationship.last_conversation_at, before.last_conversation_at) == :gt
    assert Repo.aggregate(Relationship, :count, :relationship_id) == 1

    for field <- [
          :compatibility_version,
          :opportunity_score,
          :scarcity_adjustment,
          :conversation_temperature,
          :mutual_participation_score,
          :conversation_health_score,
          :match_quality_score,
          :learning_version
        ] do
      assert is_nil(Map.fetch!(match, field))
    end
  end

  test "database compatibility constraint distinguishes ordinary and reconnect strategies", %{
    fixture: f
  } do
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(struct(Matching, match_attrs(f, :COMPATIBILITY, nil)))
    end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(
        struct(Matching, match_attrs(f, :relationship_reconnect_v1, Decimal.new("1.0")))
      )
    end

    assert %Matching{compatibility_score: nil} =
             Repo.insert!(struct(Matching, match_attrs(f, :relationship_reconnect_v1, nil)))
  end

  test "missing Relationship returns a safe channel error and activity locks release after failure",
       %{fixture: f} do
    joined = joined_socket(f.a)
    ref = push(joined, "bond:reconnect_status", %{"relationship_id" => Ecto.UUID.generate()})
    assert_reply ref, :error, %{reason: "reconnection_unavailable"}

    assert_raise RuntimeError, fn ->
      StrangertalksNew.ParticipantActivityLock.with_participants([f.a], fn -> raise "failure" end)
    end

    assert :released =
             StrangertalksNew.ParticipantActivityLock.with_participants([f.a], fn -> :released end)
  end

  defp joined_socket(participant_id) do
    socket = socket(UserSocket, "participant", %{participant_id: participant_id})

    {:ok, _, joined} =
      subscribe_and_join(socket, ParticipantChannel, "participant:#{participant_id}")

    joined
  end

  defp reconnect(f, participant_id, door),
    do:
      RelationshipReconnections.start_or_replace(
        f.relationship.relationship_id,
        participant_id,
        door
      )

  defp active_intent(f, participant_id) do
    Repo.one!(
      from i in RelationshipReconnectionIntent,
        where:
          i.relationship_id == ^f.relationship.relationship_id and
            i.participant_id == ^participant_id and i.status == :ACTIVE
    )
  end

  defp current_conversation_count(participant_id) do
    Repo.aggregate(
      from(c in Conversation,
        where:
          c.conversation_status in [:PENDING, :ACTIVE, :PAUSED] and
            (c.participant_a_id == ^participant_id or c.participant_b_id == ^participant_id)
      ),
      :count
    )
  end

  defp force_insert_failure!(table) when table in ["matches", "conversations"] do
    function = "foundation_fail_reconnect_#{table}_insert"
    trigger = "foundation_fail_reconnect_#{table}_insert_trigger"

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'forced foundation reconnect transaction failure';
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE INSERT ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function}()
    """)
  end

  defp match_attrs(f, strategy, compatibility_score) do
    now = DateTime.utc_now()

    %{
      created_at: now,
      door_type: :SOMETHING_REAL,
      participant_a_door_type: :SOMETHING_REAL,
      participant_b_door_type: :SOMETHING_REAL,
      match_status: :CREATED,
      match_strategy: strategy,
      participant_a_id: f.a,
      participant_b_id: f.b,
      compatibility_score: compatibility_score,
      queue_entry_time: now,
      match_found_time: now,
      queue_duration_seconds: 0,
      conversation_duration_seconds: 0,
      conversation_started: false,
      conversation_completed: false,
      memory_created: false,
      relationship_created: false,
      reconnected_later: strategy == :relationship_reconnect_v1,
      report_generated: false,
      block_generated: false,
      safety_review_required: false,
      learning_processed: false
    }
  end

  defp pending_conversation_attrs(f, match) do
    %{
      created_at: DateTime.utc_now(),
      match_id: match.match_id,
      participant_a_id: f.a,
      participant_b_id: f.b,
      conversation_status: :PENDING,
      door_type: match.door_type,
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
    }
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
