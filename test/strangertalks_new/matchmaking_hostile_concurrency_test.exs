defmodule StrangertalksNew.MatchmakingHostileConcurrencyTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
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
