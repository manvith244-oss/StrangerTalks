defmodule StrangertalksNew.Matchmaking.MatchmakingEngineTest do
  use ExUnit.Case, async: false
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  setup do
    # Wipe the volatile Agent memory clean before spinning up individual test blocks
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  describe "Queue Entry Boundary Validations" do
    test "successfully injects structured parameters into the volatile Agent map" do
      p_id = Ecto.UUID.generate()

      assert {:ok, %{status: :queued}} =
               MatchmakingEngine.join_queue(p_id, :EXPLORE, "en", 7, 120.0)

      {:ok, status} = MatchmakingEngine.get_queue_status()
      assert status.active_participants == 1
    end

    test "rejects unformatted inputs matching the type constraints layout" do
      assert {:error, :unsupported_schema} =
               MatchmakingEngine.join_queue(12345, "EXPLORE", "en", 7, 120)
    end
  end

  describe "Dynamic Matrix Pipeline Verification" do
    test "Test Case 1: Asserts that mismatched languages drop score to 0 and block pairing" do
      p1 = Ecto.UUID.generate()
      p2 = Ecto.UUID.generate()

      MatchmakingEngine.join_queue(p1, :EXPLORE, "en", 7, 120.0)
      MatchmakingEngine.join_queue(p2, :EXPLORE, "es", 7, 120.0)

      assert {:ok, []} = MatchmakingEngine.evaluate_pending_matches()
    end

    test "Test Case 2: Asserts that matching instances trigger accurately after threshold decay steps execute" do
      p1 = Ecto.UUID.generate()
      p2 = Ecto.UUID.generate()

      MatchmakingEngine.join_queue(p1, :EXPLORE, "en", 7, 120.0)
      MatchmakingEngine.join_queue(p2, :EXPLORE, "en", 7, 120.0)

      # Artificially alter timestamps to force an active wait time past 40 seconds
      past_time = DateTime.add(DateTime.utc_now(), -45, :second)

      Agent.update(QueueState, fn state ->
        state
        |> put_in([p1, :queue_entry_time], past_time)
        |> put_in([p2, :queue_entry_time], past_time)
      end)

      # Decayed limits evaluate below the baseline score output, creating a valid pair matching strategy
      assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()
      assert is_binary(match_id)
    end
  end
end
