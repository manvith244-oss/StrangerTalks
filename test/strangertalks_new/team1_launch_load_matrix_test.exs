defmodule StrangertalksNew.Team1LaunchLoadMatrixTest do
  @moduledoc """
  Disposable CI proof: participant authority under 2, 10, 50, 100 and 200
  simultaneously queued synthetic users. This is not a browser, WAN, soak,
  media or production-capacity benchmark.
  """

  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participants
  alias StrangertalksNew.QueueEngine.QueueState

  @moduletag :team1_launch_load_matrix

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  for participant_count <- [2, 10, 50, 100, 200] do
    test "#{participant_count} simultaneously queued participants retain exclusive pairing authority" do
      count = unquote(participant_count)

      participants =
        for _ <- 1..count do
          {:ok, participant} = Participants.create_participant(%{})
          participant
        end

      join_start = System.monotonic_time(:millisecond)

      join_results =
        participants
        |> Task.async_stream(
          fn participant ->
            MatchmakingEngine.join_queue(participant.participant_id, :EXPLORE, nil, nil, nil)
          end,
          max_concurrency: min(count, 25),
          timeout: 120_000
        )
        |> Enum.to_list()

      join_ms = System.monotonic_time(:millisecond) - join_start

      assert length(join_results) == count

      assert Enum.all?(join_results, fn
               {:ok, {:ok, %{status: :queued}}} -> true
               _ -> false
             end)

      assert Agent.get(QueueState, &map_size/1) == count

      evaluation_start = System.monotonic_time(:millisecond)

      evaluator_results =
        1..8
        |> Task.async_stream(
          fn _ -> MatchmakingEngine.evaluate_pending_matches() end,
          max_concurrency: 8,
          timeout: 120_000
        )
        |> Enum.to_list()

      evaluation_ms = System.monotonic_time(:millisecond) - evaluation_start

      assert Enum.all?(evaluator_results, fn
               {:ok, {:ok, _match_ids}} -> true
               _ -> false
             end)

      committed_matches = Repo.all(Matching)
      conversations = Repo.all(Conversation)

      matched_participants =
        Enum.flat_map(committed_matches, &[&1.participant_a_id, &1.participant_b_id])

      assert length(committed_matches) == div(count, 2)
      assert length(conversations) == div(count, 2)
      assert length(matched_participants) == count
      assert MapSet.size(MapSet.new(matched_participants)) == count
      assert Agent.get(QueueState, &map_size/1) == 0

      IO.puts(
        "TEAM1_LOAD tier=#{count} join_max_concurrency=#{min(count, 25)} evaluator_concurrency=8 " <>
          "join_ms=#{join_ms} matching_ms=#{evaluation_ms} matches=#{length(committed_matches)} " <>
          "queue_remaining=0 beam_memory_bytes=#{:erlang.memory(:total)}"
      )
    end
  end
end
