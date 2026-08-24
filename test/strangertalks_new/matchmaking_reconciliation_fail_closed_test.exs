defmodule StrangertalksNew.MatchmakingReconciliationFailClosedTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNew.SessionReconciliation

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "ambiguous durable Conversation state cannot become queue availability" do
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()

    create_pending_conversation(a, b)
    create_pending_conversation(a, c)

    assert {:error, :participant_busy} =
             MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)

    refute Agent.get(QueueState, &Map.has_key?(&1, a.participant_id))

    assert {:error, :participant_busy} =
             MatchmakingEngine.cancel_queue(a.participant_id, Ecto.UUID.generate())
  end

  test "reconciliation ambiguity discovered at commit time fails closed and preserves queue" do
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()
    d = participant_fixture()

    assert {:ok, _} =
             MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)

    assert {:ok, _} =
             MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)

    create_pending_conversation(a, c)
    create_pending_conversation(a, d)

    match_count_before = Repo.aggregate(Matching, :count, :match_id)
    conversation_count_before = Repo.aggregate(Conversation, :count, :conversation_id)

    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert Repo.aggregate(Matching, :count, :match_id) == match_count_before
    assert Repo.aggregate(Conversation, :count, :conversation_id) == conversation_count_before

    queue_state = Agent.get(QueueState, & &1)
    assert Map.has_key?(queue_state, a.participant_id)
    assert Map.has_key?(queue_state, b.participant_id)
  end

  test "failed orphan terminalization keeps the durable Conversation authoritative" do
    a = participant_fixture()
    b = participant_fixture()
    conversation = create_pending_conversation(a, b)

    conversation
    |> Conversation.changeset(%{created_at: DateTime.add(DateTime.utc_now(), -300, :second)})
    |> Repo.update!()

    force_conversation_update_failure!()

    assert {:ok,
            %{
              canonical_state: :CONVERSATION,
              conversation: %{conversation_id: conversation_id}
            }} = SessionReconciliation.reconcile(a.participant_id)

    assert conversation_id == conversation.conversation_id
    assert Repo.get!(Conversation, conversation.conversation_id).conversation_status == :PENDING

    assert {:error, :participant_busy} =
             MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)

    refute Agent.get(QueueState, &Map.has_key?(&1, a.participant_id))
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp create_pending_conversation(a, b) do
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :EXPLORE,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
        participant_a_door_type: :EXPLORE,
        participant_b_door_type: :EXPLORE,
        conversation_language: "en",
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

    %Conversation{}
    |> Conversation.changeset(%{
      created_at: now,
      match_id: match.match_id,
      participant_a_id: a.participant_id,
      participant_b_id: b.participant_id,
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
    |> Repo.insert!()
  end

  defp force_conversation_update_failure! do
    Repo.query!("""
    CREATE FUNCTION team2_fail_conversation_update() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'forced Team 2 conversation update failure';
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER team2_fail_conversation_update_trigger
    BEFORE UPDATE ON conversations
    FOR EACH ROW EXECUTE FUNCTION team2_fail_conversation_update()
    """)
  end
end
