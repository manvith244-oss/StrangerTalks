defmodule StrangertalksNew.ParticipantPairingReservationAcquisitionTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.Matches
  alias StrangertalksNew.Matching
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.Participant
  alias StrangertalksNew.ParticipantActivityLock
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  defmodule Reservation do
    use Ecto.Schema

    @primary_key false
    schema "participant_pairing_reservations" do
      field :match_id, :binary_id, primary_key: true
      field :participant_id, :binary_id, primary_key: true
      field :acquired_at, :utc_datetime_usec
      field :released_at, :utc_datetime_usec
    end
  end

  setup do
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "same participant raced across two pairings commits exactly one whole creation" do
    capture = start_reservation_query_capture!()
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()
    now = DateTime.utc_now()

    a_entry = queue_entry(a.participant_id, DateTime.add(now, -3, :second))
    b_entry = queue_entry(b.participant_id, DateTime.add(now, -2, :second))
    c_entry = queue_entry(c.participant_id, DateTime.add(now, -1, :second))

    Agent.update(QueueState, fn _ -> %{a.participant_id => a_entry, c.participant_id => c_entry} end)

    {contender_ac, contender_ab} =
      ParticipantActivityLock.with_participants([a.participant_id], fn ->
        contender_ac = async_unboxed(:same_ac, fn -> MatchmakingEngine.evaluate_pending_matches() end)
        release_task_after_connection_ready!(contender_ac, :same_ac)
        wait_until_waiting_on_participant_lock!(contender_ac.pid)

        Agent.update(QueueState, &Map.put(&1, b.participant_id, b_entry))

        contender_ab = async_unboxed(:same_ab, fn -> MatchmakingEngine.evaluate_pending_matches() end)
        release_task_after_connection_ready!(contender_ab, :same_ab)
        wait_until_waiting_on_participant_lock!(contender_ab.pid)

        {contender_ac, contender_ab}
      end)

    results = [Task.await(contender_ac, 5_000), Task.await(contender_ab, 5_000)]
    assert_distinct_connections!(results)
    assert Enum.sort(Enum.map(results, &created_match_count/1)) == [0, 1]

    evidence =
      unboxed(fn ->
        matches = matches_involving(a.participant_id)
        conversations = authoritative_conversations_involving(a.participant_id)
        reservations = active_reservations_for([a.participant_id, b.participant_id, c.participant_id])

        assert length(matches) == 1
        assert length(conversations) == 1
        assert length(reservations) == 2
        assert duplicate_active_rows() == 0

        %{matches: length(matches), conversations: length(conversations), reservations: length(reservations)}
      end)

    events = stop_reservation_query_capture!(capture)
    sqlstates = sqlstates(events)

    IO.puts(
      "ACQ-01 PASS same-participant backend_pids=#{inspect(Enum.map(results, & &1.backend_pid))} elapsed_ms=#{inspect(Enum.map(results, & &1.elapsed_ms))} sqlstates=#{format_sqlstates(sqlstates)} matches=#{evidence.matches} conversations=#{evidence.conversations} reservations=#{evidence.reservations} duplicate_active_rows=0"
    )
  end

  test "A/B versus B/A contender inversion commits one creation without deadlock" do
    capture = start_reservation_query_capture!()
    a = participant_fixture()
    b = participant_fixture()
    now = DateTime.utc_now()

    a_old = queue_entry(a.participant_id, DateTime.add(now, -2, :second))
    b_new = queue_entry(b.participant_id, DateTime.add(now, -1, :second))
    a_new = %{a_old | queue_entry_time: DateTime.add(now, -1, :second)}
    b_old = %{b_new | queue_entry_time: DateTime.add(now, -2, :second)}

    Agent.update(QueueState, fn _ -> %{a.participant_id => a_old, b.participant_id => b_new} end)

    {contender_ab, contender_ba} =
      ParticipantActivityLock.with_participants([a.participant_id, b.participant_id], fn ->
        contender_ab = async_unboxed(:inversion_ab, fn -> MatchmakingEngine.evaluate_pending_matches() end)
        release_task_after_connection_ready!(contender_ab, :inversion_ab)
        wait_until_waiting_on_participant_lock!(contender_ab.pid)

        Agent.update(QueueState, fn state ->
          state
          |> Map.put(a.participant_id, a_new)
          |> Map.put(b.participant_id, b_old)
        end)

        contender_ba = async_unboxed(:inversion_ba, fn -> MatchmakingEngine.evaluate_pending_matches() end)
        release_task_after_connection_ready!(contender_ba, :inversion_ba)
        wait_until_waiting_on_participant_lock!(contender_ba.pid)

        {contender_ab, contender_ba}
      end)

    results = [Task.await(contender_ab, 5_000), Task.await(contender_ba, 5_000)]
    assert_distinct_connections!(results)
    assert Enum.sort(Enum.map(results, &created_match_count/1)) == [0, 1]

    evidence =
      unboxed(fn ->
        matches = matches_for_pair(a.participant_id, b.participant_id)
        conversations = conversations_for_pair(a.participant_id, b.participant_id)
        reservations = active_reservations_for([a.participant_id, b.participant_id])

        assert length(matches) == 1
        assert length(conversations) == 1
        assert length(reservations) == 2
        assert duplicate_active_rows() == 0

        %{matches: length(matches), conversations: length(conversations), reservations: length(reservations)}
      end)

    events = stop_reservation_query_capture!(capture)

    IO.puts(
      "ACQ-02 PASS inversion contenders=A/B,B/A backend_pids=#{inspect(Enum.map(results, & &1.backend_pid))} elapsed_ms=#{inspect(Enum.map(results, & &1.elapsed_ms))} sqlstates=#{format_sqlstates(sqlstates(events))} matches=#{evidence.matches} conversations=#{evidence.conversations} reservations=#{evidence.reservations} duplicate_active_rows=0"
    )
  end

  test "conflict on canonical second participant rolls back first reservation and whole creation" do
    capture = start_reservation_query_capture!()
    target_1 = participant_fixture()
    target_2 = participant_fixture()
    seed_peer = participant_fixture()
    [first_id, second_id] = Enum.sort([target_1.participant_id, target_2.participant_id])

    seed_match = match_fixture(participant_by_id!(second_id), seed_peer)
    acquired_at = DateTime.utc_now()

    unboxed(fn ->
      Repo.insert!(%Reservation{
        match_id: seed_match.match_id,
        participant_id: second_id,
        acquired_at: acquired_at
      })
    end)

    now = DateTime.utc_now()
    first_entry = queue_entry(first_id, DateTime.add(now, -2, :second))
    second_entry = queue_entry(second_id, DateTime.add(now, -1, :second))
    Agent.update(QueueState, fn _ -> %{first_id => first_entry, second_id => second_entry} end)

    contender = async_unboxed(:second_conflict, fn -> MatchmakingEngine.evaluate_pending_matches() end)
    release_task_after_connection_ready!(contender, :second_conflict)
    result = Task.await(contender, 5_000)
    assert created_match_count(result) == 0

    evidence =
      unboxed(fn ->
        first_active = active_reservations_for([first_id])
        second_active = active_reservations_for([second_id])
        target_matches = matches_for_pair(first_id, second_id)
        target_conversations = conversations_for_pair(first_id, second_id)

        assert first_active == []
        assert length(second_active) == 1
        assert target_matches == []
        assert target_conversations == []
        assert duplicate_active_rows() == 0

        %{
          first_active: length(first_active),
          second_active: length(second_active),
          matches: length(target_matches),
          conversations: length(target_conversations)
        }
      end)

    events = stop_reservation_query_capture!(capture)
    assert "23505" in sqlstates(events)

    failed_query_ms =
      events
      |> Enum.filter(&(&1.sqlstate == "23505"))
      |> Enum.map(& &1.elapsed_ms)

    IO.puts(
      "ACQ-03 PASS second-participant-conflict backend_pid=#{result.backend_pid} elapsed_ms=#{result.elapsed_ms} sqlstates=#{inspect(sqlstates(events))} failed_query_ms=#{inspect(failed_query_ms)} first_active=#{evidence.first_active} second_active=#{evidence.second_active} matches=#{evidence.matches} conversations=#{evidence.conversations} duplicate_active_rows=0"
    )
  end

  test "two independent pairings commit concurrently on distinct database connections" do
    capture = start_reservation_query_capture!()
    a = participant_fixture()
    b = participant_fixture()
    c = participant_fixture()
    d = participant_fixture()
    now = DateTime.utc_now()

    entries = %{
      a.participant_id => queue_entry(a.participant_id, DateTime.add(now, -4, :second)),
      b.participant_id => queue_entry(b.participant_id, DateTime.add(now, -3, :second)),
      c.participant_id => queue_entry(c.participant_id, DateTime.add(now, -2, :second)),
      d.participant_id => queue_entry(d.participant_id, DateTime.add(now, -1, :second))
    }

    Agent.update(QueueState, fn _ -> Map.take(entries, [a.participant_id, b.participant_id]) end)

    {pair_ab, pair_cd} =
      ParticipantActivityLock.with_participants(
        [a.participant_id, b.participant_id, c.participant_id, d.participant_id],
        fn ->
          pair_ab = async_unboxed(:independent_ab, fn -> MatchmakingEngine.evaluate_pending_matches() end)
          release_task_after_connection_ready!(pair_ab, :independent_ab)
          wait_until_waiting_on_participant_lock!(pair_ab.pid)

          Agent.update(QueueState, fn _ -> Map.take(entries, [c.participant_id, d.participant_id]) end)

          pair_cd = async_unboxed(:independent_cd, fn -> MatchmakingEngine.evaluate_pending_matches() end)
          release_task_after_connection_ready!(pair_cd, :independent_cd)
          wait_until_waiting_on_participant_lock!(pair_cd.pid)

          Agent.update(QueueState, fn _ -> entries end)
          {pair_ab, pair_cd}
        end
      )

    results = [Task.await(pair_ab, 5_000), Task.await(pair_cd, 5_000)]
    assert_distinct_connections!(results)
    assert Enum.map(results, &created_match_count/1) == [1, 1]

    evidence =
      unboxed(fn ->
        ab_matches = matches_for_pair(a.participant_id, b.participant_id)
        cd_matches = matches_for_pair(c.participant_id, d.participant_id)
        reservations =
          active_reservations_for([
            a.participant_id,
            b.participant_id,
            c.participant_id,
            d.participant_id
          ])

        assert length(ab_matches) == 1
        assert length(cd_matches) == 1
        assert length(reservations) == 4
        assert duplicate_active_rows() == 0

        %{matches: length(ab_matches) + length(cd_matches), reservations: length(reservations)}
      end)

    events = stop_reservation_query_capture!(capture)

    IO.puts(
      "ACQ-04 PASS independent backend_pids=#{inspect(Enum.map(results, & &1.backend_pid))} elapsed_ms=#{inspect(Enum.map(results, & &1.elapsed_ms))} sqlstates=#{format_sqlstates(sqlstates(events))} matches=#{evidence.matches} reservations=#{evidence.reservations} duplicate_active_rows=0"
    )
  end

  test "real acquisition path inserts reservations in ascending UUID order independent of A/B role" do
    capture = start_reservation_query_capture!()
    [low_id, high_id] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()])
    low = participant_fixture(low_id)
    high = participant_fixture(high_id)
    now = DateTime.utc_now()

    high_entry = queue_entry(high.participant_id, DateTime.add(now, -2, :second))
    low_entry = queue_entry(low.participant_id, DateTime.add(now, -1, :second))
    Agent.update(QueueState, fn _ -> %{high.participant_id => high_entry, low.participant_id => low_entry} end)

    contender = async_unboxed(:canonical_order, fn -> MatchmakingEngine.evaluate_pending_matches() end)
    release_task_after_connection_ready!(contender, :canonical_order)
    result = Task.await(contender, 5_000)
    assert created_match_count(result) == 1

    committed_match =
      unboxed(fn ->
        [match] = matches_for_pair(low_id, high_id)
        assert match.participant_a_id == high_id
        assert match.participant_b_id == low_id
        assert length(active_reservations_for([low_id, high_id])) == 2
        assert duplicate_active_rows() == 0
        match
      end)

    events = stop_reservation_query_capture!(capture)

    ordered_ids =
      events
      |> Enum.filter(&(&1.kind == :insert and &1.match_id == committed_match.match_id))
      |> Enum.map(& &1.participant_id)

    assert ordered_ids == [low_id, high_id]

    IO.puts(
      "ACQ-05 PASS canonical-order backend_pid=#{result.backend_pid} elapsed_ms=#{result.elapsed_ms} match_roles=#{committed_match.participant_a_id}/#{committed_match.participant_b_id} reservation_order=#{inspect(ordered_ids)} expected=#{inspect([low_id, high_id])} sqlstates=#{format_sqlstates(sqlstates(events))} duplicate_active_rows=0"
    )
  end

  defp start_reservation_query_capture! do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :repo, :query],
        fn _event, measurements, metadata, target ->
          query = metadata[:query] |> to_string()

          if String.contains?(query, "participant_pairing_reservations") do
            send(target, {:reservation_query, query, metadata[:params], metadata[:result], measurements})
          end
        end,
        parent
      )

    handler_id
  end

  defp stop_reservation_query_capture!(handler_id) do
    :ok = :telemetry.detach(handler_id)
    collect_reservation_events([])
  end

  defp collect_reservation_events(acc) do
    receive do
      {:reservation_query, query, params, result, measurements} ->
        collect_reservation_events([reservation_event(query, params, result, measurements) | acc])
    after
      25 -> Enum.reverse(acc)
    end
  end

  defp reservation_event(query, params, result, measurements) do
    insert? = String.starts_with?(String.trim_leading(query), "INSERT INTO participant_pairing_reservations")

    {match_id, participant_id} =
      if insert? and is_list(params) and length(params) >= 2 do
        [raw_match_id, raw_participant_id | _] = params
        {load_uuid(raw_match_id), load_uuid(raw_participant_id)}
      else
        {nil, nil}
      end

    sqlstate =
      case result do
        {:error, %Postgrex.Error{postgres: postgres}} -> postgres.pg_code
        _ -> nil
      end

    elapsed_native = measurements[:total_time] || measurements[:query_time] || 0

    %{
      kind: if(insert?, do: :insert, else: :other),
      match_id: match_id,
      participant_id: participant_id,
      sqlstate: sqlstate,
      elapsed_ms: System.convert_time_unit(elapsed_native, :native, :microsecond) / 1000
    }
  end

  defp sqlstates(events), do: events |> Enum.map(& &1.sqlstate) |> Enum.reject(&is_nil/1)
  defp format_sqlstates([]), do: "none"
  defp format_sqlstates(states), do: inspect(states)

  defp load_uuid(binary) when is_binary(binary) do
    case Ecto.UUID.load(binary) do
      {:ok, uuid} -> uuid
      :error -> binary
    end
  end

  defp participant_fixture(participant_id \\ Ecto.UUID.generate()) do
    unboxed(fn ->
      now = DateTime.utc_now()

      Repo.insert!(%Participant{
        participant_id: participant_id,
        last_active_at: now,
        created_at: now
      })
    end)
  end

  defp participant_by_id!(participant_id) do
    unboxed(fn -> Repo.get!(Participant, participant_id) end)
  end

  defp match_fixture(participant_a, participant_b) do
    unboxed(fn ->
      now = DateTime.utc_now()

      attrs = %{
        created_at: now,
        door_type: :EXPLORE,
        conversation_language: "en",
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0000"),
        opportunity_score: Decimal.new("0.0000"),
        scarcity_adjustment: Decimal.new("0.0000"),
        conversation_temperature: Decimal.new("0.0000"),
        mutual_participation_score: Decimal.new("0.0000"),
        conversation_health_score: Decimal.new("0.0000"),
        match_quality_score: Decimal.new("0.0000"),
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
        learning_processed: false,
        learning_version: "acquisition-proof-v1"
      }

      {:ok, match} = Matches.create_match(attrs)
      match
    end)
  end

  defp queue_entry(participant_id, queue_entry_time) do
    %{
      participant_id: participant_id,
      door_selection: :EXPLORE,
      conversation_language: "en",
      media_bitmask: nil,
      keystroke_cadence: nil,
      queue_entry_time: queue_entry_time,
      queue_entry_monotonic: System.monotonic_time(),
      queue_attempt_id: Ecto.UUID.generate(),
      attempt_count: 1
    }
  end

  defp async_unboxed(label, operation) do
    parent = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:db_connection_ready, label, self(), backend_pid})

        receive do
          {:run, ^label} -> :ok
        after
          2_000 -> flunk("#{label} was not released from the connection barrier")
        end

        started_at = System.monotonic_time(:microsecond)
        operation_result = operation.()
        elapsed_ms = (System.monotonic_time(:microsecond) - started_at) / 1000

        %{
          label: label,
          backend_pid: backend_pid,
          elapsed_ms: Float.round(elapsed_ms, 3),
          operation_result: operation_result
        }
      end)
    end)
  end

  defp release_task_after_connection_ready!(task, label) do
    task_pid = task.pid
    assert_receive {:db_connection_ready, ^label, ^task_pid, backend_pid}, 2_000
    assert is_integer(backend_pid)
    send(task_pid, {:run, label})
  end

  defp assert_distinct_connections!(results) do
    backend_pids = Enum.map(results, & &1.backend_pid)
    assert length(Enum.uniq(backend_pids)) == length(backend_pids)
  end

  defp created_match_count(%{operation_result: {:ok, match_ids}}), do: length(match_ids)

  defp matches_involving(participant_id) do
    Repo.all(
      from match in Matching,
        where:
          match.participant_a_id == ^participant_id or match.participant_b_id == ^participant_id
    )
  end

  defp matches_for_pair(participant_a_id, participant_b_id) do
    Repo.all(
      from match in Matching,
        where:
          (match.participant_a_id == ^participant_a_id and match.participant_b_id == ^participant_b_id) or
            (match.participant_a_id == ^participant_b_id and match.participant_b_id == ^participant_a_id)
    )
  end

  defp authoritative_conversations_involving(participant_id) do
    Repo.all(
      from conversation in Conversation,
        where:
          (conversation.participant_a_id == ^participant_id or
             conversation.participant_b_id == ^participant_id) and
            conversation.conversation_status in [:PENDING, :ACTIVE, :PAUSED]
    )
  end

  defp conversations_for_pair(participant_a_id, participant_b_id) do
    Repo.all(
      from conversation in Conversation,
        where:
          (conversation.participant_a_id == ^participant_a_id and
             conversation.participant_b_id == ^participant_b_id) or
            (conversation.participant_a_id == ^participant_b_id and
               conversation.participant_b_id == ^participant_a_id)
    )
  end

  defp active_reservations_for(participant_ids) do
    Repo.all(
      from reservation in Reservation,
        where: reservation.participant_id in ^participant_ids and is_nil(reservation.released_at)
    )
  end

  defp duplicate_active_rows do
    %{rows: [[count]]} =
      Repo.query!("""
      SELECT count(*)::integer
      FROM (
        SELECT participant_id
        FROM participant_pairing_reservations
        WHERE released_at IS NULL
        GROUP BY participant_id
        HAVING count(*) > 1
      ) duplicate_participants
      """)

    count
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

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
        when function in [:random_sleep, :set_lock, :trans] -> true

        _frame -> false
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
end
