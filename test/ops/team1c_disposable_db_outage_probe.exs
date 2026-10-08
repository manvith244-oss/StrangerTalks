# Team 1C: a disposable, same-BEAM PostgreSQL interruption probe.
# Run only against an isolated PostgreSQL container; never a deployed database.
# The orchestration uses filesystem phase barriers, not timing-dependent sleeps.
defmodule Team1CDBProbe do
  alias StrangertalksNew.{Conversation, Matching, Participants, Repo, SessionReconciliation}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  @proof_dir System.fetch_env!("TEAM1C_PROOF_DIR")

  def run do
    File.mkdir_p!(@proof_dir)
    assert_query!(:healthy_before)
    {:ok, a} = Participants.create_participant(%{})
    {:ok, b} = Participants.create_participant(%{})
    {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, nil, nil, nil)

    entry = Agent.get(QueueState, &Map.fetch!(&1, a.participant_id))
    match_before = Repo.aggregate(Matching, :count, :match_id)
    conv_before = Repo.aggregate(Conversation, :count, :conversation_id)
    File.write!(path("ready"), "queued_before_outage=true\n")
    wait_for!("stop_complete", 90_000)

    began = System.monotonic_time(:millisecond)
    db_result = outcome(fn -> Repo.query("SELECT 1", [], timeout: 2_000) end)
    reconcile_result = outcome(fn -> SessionReconciliation.reconcile(b.participant_id) end)
    join_result = outcome(fn -> MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, nil, nil, nil) end)
    cancel_result = outcome(fn -> MatchmakingEngine.cancel_queue(a.participant_id, entry.queue_attempt_id) end)
    elapsed = System.monotonic_time(:millisecond) - began

    offline_report = %{
      db_query: class(db_result),
      reconciliation: class(reconcile_result),
      joining: class(join_result),
      cancellation: class(cancel_result),
      elapsed_ms: elapsed,
      new_participant_queued: Agent.get(QueueState, &Map.has_key?(&1, b.participant_id)),
      original_participant_queued: Agent.get(QueueState, &Map.has_key?(&1, a.participant_id))
    }

    # No identifiers, message bodies or credentials go into this evidence.
    File.write!(path("offline.txt"), inspect(offline_report, pretty: true) <> "\n")
    File.write!(path("offline_complete"), "true\n")
    wait_for!("start_complete", 90_000)
    await_query_recovery!(60_000)

    match_after = Repo.aggregate(Matching, :count, :match_id)
    conv_after = Repo.aggregate(Conversation, :count, :conversation_id)
    a_reconcile = outcome(fn -> SessionReconciliation.reconcile(a.participant_id) end)
    b_reconcile = outcome(fn -> SessionReconciliation.reconcile(b.participant_id) end)

    restored_report = %{
      match_count_before: match_before, match_count_after: match_after,
      conversation_count_before: conv_before, conversation_count_after: conv_after,
      participant_a_state: canonical(a_reconcile),
      participant_b_state: canonical(b_reconcile),
      process_survived_db_outage: true
    }
    File.write!(path("recovered.txt"), inspect(restored_report, pretty: true) <> "\n")

    if match_before != match_after or conv_before != conv_after do
      raise "DB-02: outage caused unexpected durable match/conversation"
    end

    if successful?(join_result) or offline_report.new_participant_queued do
      raise "DB-01: queue admission succeeded without a database-backed authority decision"
    end

    if match?({:ok, _}, reconcile_result) do
      raise "DB-03: reconciliation succeeded despite unavailable database"
    end

    if elapsed > 75_000 do
      raise "DB-08: operations were not bounded during the outage"
    end

    if canonical(a_reconcile) == :error or canonical(b_reconcile) == :error do
      raise "DB-07: reconciliation did not recover after database restart"
    end

    File.write!(path("passed"), "DB-01/02/07 partial API-level smoke proof PASS\n")
    IO.puts("TEAM1C_DISPOSABLE_DB_PROBE=PASS")
  end

  defp path(file), do: Path.join(@proof_dir, file)

  defp wait_for!(filename, max_ms) do
    started = System.monotonic_time(:millisecond)
    wait_loop(filename, started, max_ms)
  end

  defp wait_loop(filename, started, max_ms) do
    cond do
      File.exists?(path(filename)) -> :ok
      System.monotonic_time(:millisecond) - started > max_ms ->
        raise "Timed out waiting for isolated DB phase barrier: #{filename}"
      true ->
        Process.sleep(100)
        wait_loop(filename, started, max_ms)
    end
  end

  defp await_query_recovery!(max_ms) do
    started = System.monotonic_time(:millisecond)
    await_query_loop(started, max_ms)
  end

  defp await_query_loop(started, max_ms) do
    case outcome(fn -> Repo.query("SELECT 1", [], timeout: 2_000) end) do
      {:returned, {:ok, _}} ->
        :ok
      _ ->
        if System.monotonic_time(:millisecond) - started > max_ms do
          raise "DB-07: database did not reconnect within 60 seconds"
        end
        Process.sleep(200)
        await_query_loop(started, max_ms)
    end
  end

  defp assert_query!(phase) do
    unless match?({:returned, {:ok, _}}, outcome(fn -> Repo.query("SELECT 1") end)) do
      raise "Database precondition failed: #{phase}"
    end
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    rescue
      _ -> {:raised, :error}
    catch
      _kind, _reason -> {:caught, :exit_or_throw}
    end
  end

  defp class({:returned, {:ok, _}}), do: :ok
  defp class({:returned, {:error, _}}), do: :error
  defp class({:returned, :ok}), do: :ok
  defp class({:returned, other}) when is_atom(other), do: other
  defp class({:returned, _}), do: :other_return
  defp class({:raised, _}), do: :raised
  defp class({:caught, _}), do: :caught

  defp successful?({:returned, {:ok, _}}), do: true
  defp successful?({:returned, :ok}), do: true
  defp successful?(_), do: false

  defp canonical({:returned, {:ok, %{canonical_state: state}}}), do: state
  defp canonical(_), do: :error
end

Team1CDBProbe.run()
