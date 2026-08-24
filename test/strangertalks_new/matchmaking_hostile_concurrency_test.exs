defmodule StrangertalksNew.MatchmakingHostileConcurrencyTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo
  alias StrangertalksNew.SessionReconciliation

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "shared participant can be admitted by at most one concurrent contender" do
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()

    assert {:ok, _} = join_queue(a)
    assert {:ok, _} = join_queue(b)
    assert {:ok, _} = join_queue(c)

    # Freeze deterministic candidate order while preserving each participant's
    # original valid queue attempt. A is oldest, then B, then C.
    now = DateTime.utc_now()

    Agent.update(QueueState, fn state ->
      state
      |> Map.update!(
        a.participant_id,
        &Map.put(&1, :queue_entry_time, DateTime.add(now, -3, :second))
      )
      |> Map.update!(
        b.participant_id,
        &Map.put(&1, :queue_entry_time, DateTime.add(now, -2, :second))
      )
      |> Map.update!(
        c.participant_id,
        &Map.put(&1, :queue_entry_time, DateTime.add(now, -1, :second))
      )
    end)

    queue_state = Agent.get(QueueState, & &1)
    original_b_entry = Map.fetch!(queue_state, b.participant_id)
    original_c_entry = Map.fetch!(queue_state, c.participant_id)

    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")

    {contender_ac, contender_ab} =
      ParticipantActivityLock.with_participants([a.participant_id], fn ->
        # Contender 1 snapshots only A/C, so its selected admission is A-C.
        Agent.update(QueueState, &Map.delete(&1, b.participant_id))

        contender_ac = Task.async(fn -> MatchmakingEngine.evaluate_pending_matches() end)
        wait_until_waiting_on_participant_lock!(contender_ac.pid)

        # Restore B's exact valid attempt. With A/B/C ordered above, contender 2
        # snapshots A/B/C and therefore selects A-B while contender 1 is still
        # blocked on A's serialization boundary.
        Agent.update(QueueState, &Map.put(&1, b.participant_id, original_b_entry))

        contender_ab = Task.async(fn -> MatchmakingEngine.evaluate_pending_matches() end)
        wait_until_waiting_on_participant_lock!(contender_ab.pid)

        assert Task.yield(contender_ac, 0) == nil
        assert Task.yield(contender_ab, 0) == nil

        {contender_ac, contender_ab}
      end)

    results = [Task.await(contender_ac, 5_000), Task.await(contender_ab, 5_000)]

    assert Enum.sort(Enum.map(results, fn {:ok, match_ids} -> length(match_ids) end)) == [0, 1]

    matches = Repo.all(Matching)
    conversations = Repo.all(Conversation)

    matches_involving_a =
      Enum.filter(matches, fn match ->
        match.participant_a_id == a.participant_id or match.participant_b_id == a.participant_id
      end)

    authoritative_conversations_involving_a =
      Enum.filter(conversations, fn conversation ->
        (conversation.participant_a_id == a.participant_id or
           conversation.participant_b_id == a.participant_id) and
          conversation.conversation_status in [:PENDING, :ACTIVE, :PAUSED]
      end)

    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert length(matches_involving_a) == 1
    assert length(authoritative_conversations_involving_a) == 1

    committed_match = hd(matches_involving_a)

    winning_peer_id =
      if committed_match.participant_a_id == a.participant_id,
        do: committed_match.participant_b_id,
        else: committed_match.participant_a_id

    losing_peer_id =
      if winning_peer_id == b.participant_id, do: c.participant_id, else: b.participant_id

    queue_after = Agent.get(QueueState, & &1)

    refute Map.has_key?(queue_after, a.participant_id)
    refute Map.has_key?(queue_after, winning_peer_id)
    assert Map.keys(queue_after) == [losing_peer_id]

    expected_losing_attempt =
      if losing_peer_id == b.participant_id,
        do: original_b_entry.queue_attempt_id,
        else: original_c_entry.queue_attempt_id

    assert Map.fetch!(queue_after, losing_peer_id).queue_attempt_id == expected_losing_attempt

    assert {:ok,
            %{
              canonical_state: :CONVERSATION,
              conversation: %{conversation_id: authoritative_conversation_id}
            }} = SessionReconciliation.reconcile(a.participant_id)

    assert authoritative_conversation_id ==
             hd(authoritative_conversations_involving_a).conversation_id

    assert_receive {:match_event, :match_created, _match_id, ^authoritative_conversation_id,
                    participant_a_id, participant_b_id, _score}

    a_id = a.participant_id
    assert a_id in [participant_a_id, participant_b_id]

    refute_receive {:match_event, :match_created, _match_id, _conversation_id, ^a_id, _peer_id,
                    _score},
                   50

    refute_receive {:match_event, :match_created, _match_id, _conversation_id, _peer_id, ^a_id,
                    _score},
                   50
  end

  test "burst joins plus concurrent evaluators produce exactly one Conversation per participant pair" do
    participants =
      for _ <- 1..20 do
        {:ok, participant} = Participants.create_participant(%{})
        participant
      end

    join_results =
      race(
        Enum.map(participants, fn participant ->
          fn ->
            MatchmakingEngine.join_queue(
              participant.participant_id,
              :EXPLORE,
              "en",
              nil,
              nil
            )
          end
        end)
      )

    assert Enum.all?(join_results, &match?({:ok, %{status: :queued}}, &1))
    assert Agent.get(QueueState, &map_size/1) == 20

    evaluator_results =
      race(List.duplicate(fn -> MatchmakingEngine.evaluate_pending_matches() end, 12))

    assert Enum.all?(evaluator_results, &match?({:ok, _match_ids}, &1))
    assert Repo.aggregate(Matching, :count, :match_id) == 10
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 10
    assert Agent.get(QueueState, &map_size/1) == 0

    participant_ids =
      Matching
      |> Repo.all()
      |> Enum.flat_map(&[&1.participant_a_id, &1.participant_b_id])

    assert length(participant_ids) == 20
    assert MapSet.size(MapSet.new(participant_ids)) == 20
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
  end

  defp join_queue(participant) do
    MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, "en", nil, nil)
  end

  defp wait_until_waiting_on_participant_lock!(pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_until_waiting_on_participant_lock!(pid, deadline)
  end

  defp do_wait_until_waiting_on_participant_lock!(pid, deadline) do
    stacktrace =
      case Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, stacktrace} -> stacktrace
        nil -> flunk("contender exited before reaching participant serialization")
      end

    waiting_in_global_lock? =
      Enum.any?(stacktrace, fn
        {:global, function, _arity, _location}
        when function in [:random_sleep, :set_lock, :trans] ->
          true

        _frame ->
          false
      end)

    inside_matchmaking_admission? =
      Enum.any?(stacktrace, fn
        {MatchmakingEngine, :persist_match_and_conversation, 3, _location} -> true
        _frame -> false
      end)

    cond do
      waiting_in_global_lock? and inside_matchmaking_admission? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("contender did not reach participant serialization; stack=#{inspect(stacktrace)}")

      true ->
        Process.sleep(1)
        do_wait_until_waiting_on_participant_lock!(pid, deadline)
    end
  end

  defp race(operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> operation.()
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      task_pid = task.pid
      assert_receive {:ready, ^task_pid}
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, :infinity))
  end
end
