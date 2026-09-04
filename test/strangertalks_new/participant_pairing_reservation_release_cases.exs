defmodule StrangertalksNew.ParticipantPairingReservationReleaseTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.Repo

  @barrier_key 7_313_777

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
    StrangertalksNew.PairingTestIsolation.install!()
    Agent.update(QueueState, fn _state -> %{} end)
    :ok
  end

  test "release-terminal classifier recognizes exactly ENDED ABANDONED FAILED COMPLETED" do
    for status <- [:ENDED, :ABANDONED, :FAILED, :COMPLETED] do
      assert ConversationServer.release_terminal_status?(status)
    end

    for status <- [:PENDING, :ACTIVE, :PAUSED] do
      refute ConversationServer.release_terminal_status?(status)
    end

    IO.puts(
      "REL-05 PASS classifier release=ENDED,ABANDONED,FAILED,COMPLETED keep=PENDING,ACTIVE,PAUSED"
    )
  end

  test "ENDED canonical participant completion releases both active reservations" do
    fixture = fixture_with_reservations(:ACTIVE)
    state = init_state!(fixture.conversation_id)

    assert {:stop, :normal, {:ok, %{status: "ended"}}, _state} =
             unboxed(fn ->
               ConversationServer.handle_call(
                 {:complete_conversation, fixture.participant_a_id},
                 {self(), make_ref()},
                 state
               )
             end)

    evidence = terminal_evidence(fixture.match_id, fixture.conversation_id)
    assert evidence.status == :ENDED
    assert evidence.active_reservations == 0
    assert evidence.released_reservations == 2

    IO.puts(
      "REL-01 PASS status=ENDED path=handle_call/3->persist_terminal_intent/1->persist_conversation_status/4->Transitions.transition/3->persist_if_canonical/4 released=#{evidence.released_reservations} active=#{evidence.active_reservations}"
    )
  end

  test "ABANDONED canonical recovery timeout releases both active reservations" do
    fixture = fixture_with_reservations(:PAUSED)
    state = init_state!(fixture.conversation_id)
    token = make_ref()

    state =
      put_in(
        state.recovery_timers[fixture.participant_a_id],
        %{token: token, timer_ref: nil}
      )

    assert {:stop, :normal, _state} =
             unboxed(fn ->
               ConversationServer.handle_info(
                 {:recovery_grace_expired, fixture.participant_a_id, token},
                 state
               )
             end)

    evidence = terminal_evidence(fixture.match_id, fixture.conversation_id)
    assert evidence.status == :ABANDONED
    assert evidence.active_reservations == 0
    assert evidence.released_reservations == 2

    IO.puts(
      "REL-02 PASS status=ABANDONED path=handle_info(recovery_grace_expired)->begin_terminal_transition/4->persist_terminal_intent/1->persist_conversation_status/4->Transitions.transition/3->persist_if_canonical/4 released=#{evidence.released_reservations} active=#{evidence.active_reservations}"
    )
  end

  test "FAILED canonical participant leave before connect releases both active reservations" do
    fixture = fixture_with_reservations(:PENDING)
    state = init_state!(fixture.conversation_id)

    assert {:stop, :normal, {:ok, %{status: "ended"}}, _state} =
             unboxed(fn ->
               ConversationServer.handle_call(
                 {:complete_conversation, fixture.participant_a_id},
                 {self(), make_ref()},
                 state
               )
             end)

    evidence = terminal_evidence(fixture.match_id, fixture.conversation_id)
    assert evidence.status == :FAILED
    assert evidence.active_reservations == 0
    assert evidence.released_reservations == 2

    IO.puts(
      "REL-03 PASS status=FAILED path=handle_call/3->persist_terminal_intent/1->persist_conversation_status/4->Transitions.transition/3->persist_if_canonical/4 released=#{evidence.released_reservations} active=#{evidence.active_reservations}"
    )
  end

  test "terminal status and reservation release become visible atomically across independent connections" do
    fixture = fixture_with_reservations(:ACTIVE)
    install_release_barrier!()
    on_exit(fn -> drop_release_barrier!() end)

    parent = self()

    blocker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          Repo.query!("SELECT pg_advisory_lock($1)", [@barrier_key])
          send(parent, {:release_barrier_locked, self(), backend_pid})

          receive do
            :release_barrier -> :ok
          after
            5_000 -> flunk("release barrier was not released")
          end

          Repo.query!("SELECT pg_advisory_unlock($1)", [@barrier_key])
          backend_pid
        end)
      end)

    blocker_pid = blocker.pid
    assert_receive {:release_barrier_locked, ^blocker_pid, blocker_backend_pid}, 2_000

    terminal =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          {:ok, state} = ConversationServer.init(%{conversation_id: fixture.conversation_id})
          send(parent, {:terminal_connection_ready, self(), backend_pid})

          result =
            ConversationServer.handle_call(
              {:complete_conversation, fixture.participant_a_id},
              {self(), make_ref()},
              state
            )

          %{backend_pid: backend_pid, result: result}
        end)
      end)

    terminal_pid = terminal.pid
    assert_receive {:terminal_connection_ready, ^terminal_pid, terminal_backend_pid}, 2_000
    assert terminal_backend_pid != blocker_backend_pid

    wait_until_backend_waits_on_advisory_lock!(terminal_backend_pid)

    inflight = independent_snapshot(fixture.match_id, fixture.conversation_id)
    assert inflight.backend_pid != terminal_backend_pid
    assert inflight.status == :ACTIVE
    assert inflight.active_reservations == 2
    assert inflight.released_reservations == 0

    send(blocker_pid, :release_barrier)
    _ = Task.await(blocker, 5_000)

    terminal_result = Task.await(terminal, 5_000)
    assert {:stop, :normal, {:ok, %{status: "ended"}}, _state} = terminal_result.result

    committed = independent_snapshot(fixture.match_id, fixture.conversation_id)
    assert committed.backend_pid != terminal_backend_pid
    assert committed.status == :ENDED
    assert committed.active_reservations == 0
    assert committed.released_reservations == 2

    IO.puts(
      "REL-04 PASS terminal_backend_pid=#{terminal_backend_pid} blocker_backend_pid=#{blocker_backend_pid} observer_backend_pid=#{inflight.backend_pid} inflight=ACTIVE+2_active+0_released committed=ENDED+0_active+2_released synchronization=postgres_advisory_trigger_barrier"
    )
  end

  defp fixture_with_reservations(status) do
    a = participant_fixture()
    b = participant_fixture()

    assert {:ok, _} =
             unboxed(fn ->
               MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
             end)

    assert {:ok, _} =
             unboxed(fn ->
               MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
             end)

    assert {:ok, [match_id]} = unboxed(fn -> MatchmakingEngine.evaluate_pending_matches() end)

    conversation =
      unboxed(fn ->
        conversation = Repo.get_by!(Conversation, match_id: match_id)

        if conversation.conversation_status == status do
          conversation
        else
          conversation
          |> Conversation.changeset(%{conversation_status: status})
          |> Repo.update!()
        end
      end)

    evidence = terminal_evidence(match_id, conversation.conversation_id)
    assert evidence.status == status
    assert evidence.active_reservations == 2
    assert evidence.released_reservations == 0

    %{
      participant_a_id: a.participant_id,
      participant_b_id: b.participant_id,
      match_id: match_id,
      conversation_id: conversation.conversation_id
    }
  end

  defp participant_fixture do
    unboxed(fn ->
      {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
      participant
    end)
  end

  defp init_state!(conversation_id) do
    unboxed(fn ->
      {:ok, state} = ConversationServer.init(%{conversation_id: conversation_id})
      state
    end)
  end

  defp terminal_evidence(match_id, conversation_id) do
    unboxed(fn ->
      conversation = Repo.get!(Conversation, conversation_id)

      reservations =
        Repo.all(from reservation in Reservation, where: reservation.match_id == ^match_id)

      %{
        status: conversation.conversation_status,
        active_reservations: Enum.count(reservations, &is_nil(&1.released_at)),
        released_reservations: Enum.count(reservations, &(not is_nil(&1.released_at)))
      }
    end)
  end

  defp independent_snapshot(match_id, conversation_id) do
    unboxed(fn ->
      %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
      conversation = Repo.get!(Conversation, conversation_id)

      reservations =
        Repo.all(from reservation in Reservation, where: reservation.match_id == ^match_id)

      %{
        backend_pid: backend_pid,
        status: conversation.conversation_status,
        active_reservations: Enum.count(reservations, &is_nil(&1.released_at)),
        released_reservations: Enum.count(reservations, &(not is_nil(&1.released_at)))
      }
    end)
  end

  defp install_release_barrier! do
    unboxed(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS item3_release_barrier_trigger ON participant_pairing_reservations"
      )

      Repo.query!("DROP FUNCTION IF EXISTS item3_release_barrier()")

      Repo.query!("""
      CREATE FUNCTION item3_release_barrier()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        PERFORM pg_advisory_lock(#{@barrier_key});
        PERFORM pg_advisory_unlock(#{@barrier_key});
        RETURN NEW;
      END;
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER item3_release_barrier_trigger
      AFTER UPDATE OF released_at ON participant_pairing_reservations
      FOR EACH ROW
      WHEN (OLD.released_at IS NULL AND NEW.released_at IS NOT NULL)
      EXECUTE FUNCTION item3_release_barrier()
      """)
    end)
  end

  defp drop_release_barrier! do
    unboxed(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS item3_release_barrier_trigger ON participant_pairing_reservations"
      )

      Repo.query!("DROP FUNCTION IF EXISTS item3_release_barrier()")
    end)
  end

  defp wait_until_backend_waits_on_advisory_lock!(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_until_backend_waits_on_advisory_lock!(backend_pid, deadline)
  end

  defp do_wait_until_backend_waits_on_advisory_lock!(backend_pid, deadline) do
    waiting? =
      unboxed(fn ->
        case Repo.query!(
               "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [["Lock", "advisory"]] -> true
          _ -> false
        end
      end)

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("terminal backend did not reach deterministic advisory-lock barrier")

      true ->
        Process.sleep(1)
        do_wait_until_backend_waits_on_advisory_lock!(backend_pid, deadline)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
