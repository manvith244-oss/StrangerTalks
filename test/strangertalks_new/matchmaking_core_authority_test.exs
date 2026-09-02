defmodule StrangertalksNew.MatchmakingCoreAuthorityTest do
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

  test "invalid Door never becomes queue authority" do
    participant = participant_fixture()

    assert {:error, :invalid_door} =
             MatchmakingEngine.join_queue(
               participant.participant_id,
               :NOT_A_STRANGERTALKS_DOOR,
               "en",
               nil,
               nil
             )

    refute Agent.get(QueueState, &Map.has_key?(&1, participant.participant_id))

    assert {:error, :invalid_door} =
             MatchmakingEngine.requeue_transition_survivor(
               participant.participant_id,
               :NOT_A_STRANGERTALKS_DOOR,
               "en",
               Ecto.UUID.generate()
             )

    refute Agent.get(QueueState, &Map.has_key?(&1, participant.participant_id))
  end

  test "A-B wins a forced overlap with A-C and C remains a valid survivor" do
    assert_forced_shared_participant_winner(:b)
  end

  test "A-C wins a forced overlap with A-B and B remains a valid survivor" do
    assert_forced_shared_participant_winner(:c)
  end

  defp assert_forced_shared_participant_winner(winner_label) do
    participants =
      1..3
      |> Enum.map(fn _ -> participant_fixture() end)
      |> Enum.sort_by(& &1.participant_id)

    [a, b, c] = participants
    winner = if winner_label == :b, do: b, else: c
    loser = if winner_label == :b, do: c, else: b

    Enum.each(participants, fn participant ->
      assert {:ok, %{status: :queued}} =
               MatchmakingEngine.join_queue(
                 participant.participant_id,
                 :EXPLORE,
                 "en",
                 nil,
                 nil
               )
    end)

    original_state = Agent.get(QueueState, & &1)
    losing_attempt = Map.fetch!(original_state, loser.participant_id).queue_attempt_id

    {winner_task, loser_task} =
      ParticipantActivityLock.with_participants([winner.participant_id], fn ->
        Agent.update(QueueState, fn state ->
          Map.take(state, [a.participant_id, winner.participant_id])
        end)

        winner_task = Task.async(&MatchmakingEngine.evaluate_pending_matches/0)
        wait_until_waiting_on_participant_lock!(winner_task.pid)

        Agent.update(QueueState, fn _state ->
          Map.take(original_state, [a.participant_id, loser.participant_id])
        end)

        loser_task = Task.async(&MatchmakingEngine.evaluate_pending_matches/0)
        wait_until_waiting_on_participant_lock!(loser_task.pid)

        Agent.update(QueueState, fn _state -> original_state end)
        {winner_task, loser_task}
      end)

    assert {:ok, [_match_id]} = Task.await(winner_task, 5_000)
    assert {:ok, []} = Task.await(loser_task, 5_000)

    [match] = Repo.all(Matching)
    [conversation] = Repo.all(Conversation)

    assert MapSet.new([match.participant_a_id, match.participant_b_id]) ==
             MapSet.new([a.participant_id, winner.participant_id])

    assert conversation.match_id == match.match_id

    assert {:ok,
            %{
              canonical_state: :CONVERSATION,
              conversation: %{conversation_id: conversation_id}
            }} = SessionReconciliation.reconcile(a.participant_id)

    assert conversation_id == conversation.conversation_id

    queue_after = Agent.get(QueueState, & &1)
    refute Map.has_key?(queue_after, a.participant_id)
    refute Map.has_key?(queue_after, winner.participant_id)
    assert Map.keys(queue_after) == [loser.participant_id]
    assert Map.fetch!(queue_after, loser.participant_id).queue_attempt_id == losing_attempt

    assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    assert Repo.aggregate(Matching, :count, :match_id) == 1
    assert Repo.aggregate(Conversation, :count, :conversation_id) == 1
    assert Map.keys(Agent.get(QueueState, & &1)) == [loser.participant_id]
  end

  defp participant_fixture do
    {:ok, participant} = Participants.create_participant(%{})
    participant
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
        :erlang.yield()
        do_wait_until_waiting_on_participant_lock!(pid, deadline)
    end
  end
end
