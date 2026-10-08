# Team 1D DB-03: deterministic SQL-lock barrier plus disposable PostgreSQL shutdown.
# Synthetic participants only. Run only against isolated CI PostgreSQL.
defmodule Team1DSafetyVetoProbe do
  alias StrangertalksNew.{Conversation, Matching, MatchingRules, Participants, Repo}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  @proof_dir System.fetch_env!("TEAM1D_PROOF_DIR")

  def run do
    File.mkdir_p!(@proof_dir)
    {:ok, a} = Participants.create_participant(%{})
    {:ok, b} = Participants.create_participant(%{})
    {:ok, c} = Participants.create_participant(%{})
    {:ok, d} = Participants.create_participant(%{})

    {:ok, _block} = MatchingRules.enforce_block(a.participant_id, b.participant_id, "QUEUE")
    true = MatchingRules.check_safety_veto?(a.participant_id, b.participant_id)
    false = MatchingRules.check_safety_veto?(c.participant_id, d.participant_id)

    {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, nil, nil, nil)
    {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, nil, nil, nil)

    match_before = Repo.aggregate(Matching, :count, :match_id)
    conversation_before = Repo.aggregate(Conversation, :count, :conversation_id)
    File.write!(path("setup"), "synthetic_block_and_two_queue_attempts=true\n")

    block_outcome =
      run_locked_outage(:block_lookup, "boundary_blocks", a.participant_id, b.participant_id)

    relationship_outcome =
      run_locked_outage(
        :relationship_lookup,
        "relationships",
        c.participant_id,
        d.participant_id
      )

    after_match = Repo.aggregate(Matching, :count, :match_id)
    after_conversation = Repo.aggregate(Conversation, :count, :conversation_id)

    queue_unchanged =
      Agent.get(QueueState, fn state ->
        Map.has_key?(state, a.participant_id) and Map.has_key?(state, b.participant_id)
      end)

    true = MatchingRules.check_safety_veto?(a.participant_id, b.participant_id)
    false = MatchingRules.check_safety_veto?(c.participant_id, d.participant_id)
    {:ok, []} = MatchmakingEngine.evaluate_pending_matches()

    report = %{
      block_query_during_shutdown: classify(block_outcome),
      relationship_query_during_shutdown: classify(relationship_outcome),
      durable_matches_unchanged: match_before == after_match,
      durable_conversations_unchanged: conversation_before == after_conversation,
      blocked_queue_attempts_preserved: queue_unchanged,
      postrecovery_safety_veto_rechecked: true
    }

    File.write!(path("result.txt"), inspect(report, pretty: true) <> "\n")

    unless block_outcome == {:returned, true} and
             relationship_outcome == {:returned, true} and
             queue_unchanged and match_before == after_match and
             conversation_before == after_conversation do
      raise "DB-03: unavailable safety veto did not fail closed without phantom matches"
    end

    File.write!(path("passed"), "DB-03 deterministic BoundaryBlock and Relationship outage PASS\n")
    IO.puts("TEAM1D_DB03_SAFETY_VETO=PASS")
  end

  defp run_locked_outage(label, table, participant_a_id, participant_b_id) do
    parent = self()

    locker =
      spawn(fn ->
        result =
          capture(fn ->
            Repo.transaction(fn ->
              Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
              send(parent, {:table_locked, label})

              receive do
                :release -> :ok
              after
                90_000 -> raise "DB-03 locker timed out"
              end
            end)
          end)

        send(parent, {:lock_transaction_completed, label, classify(result)})
      end)

    receive do
      {:table_locked, ^label} -> :ok
    after
      30_000 -> raise "DB-03 did not acquire controlled SQL lock"
    end

    spawn(fn ->
      outcome = capture(fn -> MatchingRules.check_safety_veto?(participant_a_id, participant_b_id) end)
      send(parent, {:safety_outcome, label, outcome})
    end)

    await_sql_wait!(table, 30_000)
    File.write!(path("#{label}_ready"), "query_waiting_on_pg_lock=true\n")
    wait_for!("#{label}_stop_complete", 90_000)

    result =
      receive do
        {:safety_outcome, ^label, outcome} -> outcome
      after
        30_000 -> raise "DB-03 SQL waiter did not exit after PostgreSQL shutdown"
      end

    send(locker, :release)
    File.write!(path("#{label}_observed"), inspect(classify(result)) <> "\n")
    wait_for!("#{label}_start_complete", 90_000)
    await_database!(60_000)
    result
  end

  defp await_sql_wait!(table, max_ms) do
    started = System.monotonic_time(:millisecond)
    await_sql_wait_loop!(table, started, max_ms)
  end

  defp await_sql_wait_loop!(table, started, max_ms) do
    query = """
    SELECT count(*)::int FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid <> pg_backend_pid()
      AND wait_event_type = 'Lock'
      AND query ILIKE $1
    """

    case capture(fn -> Repo.query(query, ["%#{table}%"]) end) do
      {:returned, {:ok, %{rows: [[count]]}}} when count > 0 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) - started > max_ms do
          raise "DB-03 veto query never reached deterministic lock boundary: #{table}"
        end

        Process.sleep(100)
        await_sql_wait_loop!(table, started, max_ms)
    end
  end

  defp await_database!(max_ms) do
    started = System.monotonic_time(:millisecond)
    await_database_loop!(started, max_ms)
  end

  defp await_database_loop!(started, max_ms) do
    case capture(fn -> Repo.query("SELECT 1", [], timeout: 2_000) end) do
      {:returned, {:ok, _}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) - started > max_ms do
          raise "DB-03 database did not reconnect after isolated restart"
        end

        Process.sleep(200)
        await_database_loop!(started, max_ms)
    end
  end

  defp wait_for!(marker, max_ms) do
    started = System.monotonic_time(:millisecond)
    wait_loop!(marker, started, max_ms)
  end

  defp wait_loop!(marker, started, max_ms) do
    cond do
      File.exists?(path(marker)) ->
        :ok

      System.monotonic_time(:millisecond) - started > max_ms ->
        raise "DB-03 missing isolated CI barrier: #{marker}"

      true ->
        Process.sleep(100)
        wait_loop!(marker, started, max_ms)
    end
  end

  defp capture(fun) do
    try do
      {:returned, fun.()}
    rescue
      error -> {:raised, error.__struct__}
    catch
      _kind, _reason -> {:caught, :exit_or_throw}
    end
  end

  defp classify({:returned, value}), do: {:returned, value}
  defp classify({:raised, module}), do: {:raised, module}
  defp classify({:caught, _}), do: :caught

  defp path(filename), do: Path.join(@proof_dir, filename)
end

Team1DSafetyVetoProbe.run()
