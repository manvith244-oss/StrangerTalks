# Team 1D DB-04/05: real transaction interruption and lost-listener recovery.
# This is an isolated PostgreSQL 16 probe; NEVER run against staging/production.
defmodule Team1DTransactionProbe do
  alias StrangertalksNew.{Conversation, Matching, Participants, Repo, SessionReconciliation}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState

  @proof_dir System.fetch_env!("TEAM1D_TRANSACTION_PROOF_DIR")
  @advisory_key 918_377

  def run do
    File.mkdir_p!(@proof_dir)
    {:ok, a} = Participants.create_participant(%{})
    {:ok, b} = Participants.create_participant(%{})

    {:ok, %{queue_attempt_id: a_attempt}} =
      MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, nil, nil, nil)

    {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, nil, nil, nil)

    install_conversation_insert_barrier!()
    :ok = Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")

    before = counts()
    parent = self()

    lock_holder =
      spawn(fn ->
        result =
          capture(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1)", [@advisory_key])
              send(parent, :advisory_lock_held)

              receive do
                :release -> :ok
              after
                90_000 -> raise "DB-04 transaction lock expired"
              end
            end)
          end)

        send(parent, {:lock_holder_result, classify(result)})
      end)

    receive do
      :advisory_lock_held -> :ok
    after
      30_000 -> raise "DB-04 advisory lock not established"
    end

    spawn(fn ->
      result = capture(fn -> MatchmakingEngine.evaluate_pending_matches() end)
      send(parent, {:transaction_attempt_result, result})
    end)

    await_insert_wait!(30_000)
    File.write!(path("ready"), "transaction_waiting_inside_conversation_insert=true\n")
    wait_for!("stop_complete", 90_000)

    transaction_result =
      receive do
        {:transaction_attempt_result, result} -> result
      after
        30_000 -> raise "DB-04 transaction did not finish after PostgreSQL shutdown"
      end

    send(lock_holder, :release)
    File.write!(path("observed"), inspect(classify(transaction_result)) <> "\n")
    wait_for!("start_complete", 90_000)
    await_database!(60_000)

    after_outage = counts()

    queue_retained =
      Agent.get(QueueState, fn state ->
        Map.has_key?(state, a.participant_id) and Map.has_key?(state, b.participant_id)
      end)

    no_failed_commit_event? =
      receive do
        {:match_event, :match_created, _, _, _, _, _} -> false
      after
        100 -> true
      end

    if committed_match_result?(transaction_result) or before != after_outage or
         not queue_retained or not no_failed_commit_event? do
      raise "DB-04: interrupted transaction committed, notified, or lost queue authority"
    end

    remove_conversation_insert_barrier!()

    # A participant tab was not listening at the moment the successful Match
    # committed. Canonical database state must win after that lost notification.
    :ok = Phoenix.PubSub.unsubscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")
    {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    {:ok, a_state} = SessionReconciliation.reconcile(a.participant_id)
    {:ok, b_state} = SessionReconciliation.reconcile(b.participant_id)

    after_success = counts()
    {:ok, []} = MatchmakingEngine.evaluate_pending_matches()

    replay_cannot_queue? =
      MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, nil, nil, nil) ==
        {:error, :participant_busy}

    cancel_cannot_win? =
      MatchmakingEngine.cancel_queue(a.participant_id, a_attempt) ==
        {:error, :participant_busy}

    canonical_recovered? =
      a_state.canonical_state == :CONVERSATION and
        b_state.canonical_state == :CONVERSATION and
        a_state.conversation.conversation_id == b_state.conversation.conversation_id

    report = %{
      interrupted_transaction: classify(transaction_result),
      no_uncommitted_rows: before == after_outage,
      queue_attempts_preserved: queue_retained,
      false_match_notification: not no_failed_commit_event?,
      committed_match_after_recovery: is_binary(match_id),
      durable_counts_after_recovery: after_success,
      lost_listener_canonical_recovery: canonical_recovered?,
      replay_rejected: replay_cannot_queue?,
      stale_cancel_rejected: cancel_cannot_win?
    }

    File.write!(path("result.txt"), inspect(report, pretty: true) <> "\n")

    unless after_success.matches == before.matches + 1 and
             after_success.conversations == before.conversations + 1 and
             after_success.reservations == before.reservations + 2 and
             canonical_recovered? and replay_cannot_queue? and cancel_cannot_win? do
      raise "DB-04/05: transaction retry and notification-loss recovery invariants failed"
    end

    File.write!(
      path("passed"),
      "DB-04 transaction rollback + DB-05 lost-listener API recovery PASS\n"
    )

    IO.puts("TEAM1D_DB04_05_TRANSACTION_AND_RECONCILIATION=PASS")
  end

  defp install_conversation_insert_barrier! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION team1d_hold_conversation_insert()
    RETURNS trigger AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(918377);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER team1d_hold_conversation_insert
    BEFORE INSERT ON conversations
    FOR EACH ROW EXECUTE FUNCTION team1d_hold_conversation_insert()
    """)
  end

  defp remove_conversation_insert_barrier! do
    Repo.query!("DROP TRIGGER team1d_hold_conversation_insert ON conversations")
    Repo.query!("DROP FUNCTION team1d_hold_conversation_insert()")
  end

  defp counts do
    %{
      matches: Repo.aggregate(Matching, :count, :match_id),
      conversations: Repo.aggregate(Conversation, :count, :conversation_id),
      reservations: reservation_count()
    }
  end

  defp reservation_count do
    {:ok, %{rows: [[count]]}} =
      Repo.query("SELECT count(*)::int FROM participant_pairing_reservations")

    count
  end

  defp committed_match_result?({:returned, {:ok, match_ids}}) when is_list(match_ids),
    do: match_ids != []

  defp committed_match_result?(_result), do: false

  defp await_insert_wait!(max_ms) do
    started = System.monotonic_time(:millisecond)
    await_insert_wait_loop!(started, max_ms)
  end

  defp await_insert_wait_loop!(started, max_ms) do
    query = """
    SELECT count(*)::int FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid <> pg_backend_pid()
      AND wait_event_type = 'Lock'
      AND query ILIKE '%conversations%'
    """

    case capture(fn -> Repo.query(query) end) do
      {:returned, {:ok, %{rows: [[count]]}}} when count > 0 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) - started > max_ms do
          raise "DB-04 Conversation INSERT never reached PostgreSQL lock barrier"
        end

        Process.sleep(100)
        await_insert_wait_loop!(started, max_ms)
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
          raise "DB-04 isolated PostgreSQL did not recover"
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
        raise "DB-04 missing CI phase barrier: #{marker}"

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

Team1DTransactionProbe.run()
