# Team 1E: two independent BEAM invocations against the same disposable PostgreSQL.
# This is not a browser/WebSocket restart test and does not assert message restoration.
defmodule Team1EBeamRestartProbe do
  alias StrangertalksNew.{Conversation, Matching, Message, Participants, Repo, SessionReconciliation}
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.ConversationLifecycle.{ConversationServer, Transitions}
  alias StrangertalksNew.QueueEngine.QueueState

  @record System.fetch_env!("TEAM1E_RESTART_RECORD")

  def run do
    case System.fetch_env!("TEAM1E_RESTART_PHASE") do
      "seed" -> seed()
      "recover" -> recover()
    end
  end

  defp seed do
    [a, b, c, d, waiting] =
      for _ <- 1..5 do
        {:ok, participant} = Participants.create_participant(%{})
        participant.participant_id
      end

    queue_pair!(a, b)
    {:ok, [_match_id]} = MatchmakingEngine.evaluate_pending_matches()
    pending = Repo.one!(Conversation)
    assert!(pending.conversation_status == :PENDING, "pending state before BEAM stop")
    {:ok, _runtime_pid} = ConversationServer.ensure_started(pending.conversation_id)

    queue_pair!(c, d)
    {:ok, [_terminal_match_id]} = MatchmakingEngine.evaluate_pending_matches()
    terminal = Enum.find(Repo.all(Conversation), &(&1.conversation_id != pending.conversation_id))
    {:ok, ended} = Transitions.transition(terminal, :recovery_timeout)
    assert!(ended.conversation_status == :ABANDONED, "terminal transition")

    {:ok, %{queue_attempt_id: _attempt}} =
      MatchmakingEngine.join_queue(waiting, :EXPLORE, nil, nil, nil)

    assert!(map_size(Agent.get(QueueState, & &1)) == 1, "seed volatile queue state")
    assert!(reservation_count() == 2, "only pending reservation survives terminalization")
    File.write!(@record, Jason.encode!(%{
      "a" => a, "b" => b, "waiting" => waiting,
      "pending" => pending.conversation_id, "terminal" => terminal.conversation_id
    }))
    IO.puts("TEAM1E_BEAM_SEED=PASS")
  end

  defp recover do
    record = @record |> File.read!() |> Jason.decode!()
    pending_id = record["pending"]
    terminal_id = record["terminal"]

    assert!({:error, :not_started} == ConversationServer.lookup(pending_id), "old runtime absent after BEAM restart")
    assert!(Repo.get!(Conversation, pending_id).conversation_status == :PENDING, "pending persisted")
    assert!(Repo.get!(Conversation, terminal_id).conversation_status == :ABANDONED, "terminal persisted")
    assert!(map_size(Agent.get(QueueState, & &1)) == 0, "volatile queue cleared by full BEAM restart")

    for participant_id <- [record["a"], record["b"]] do
      {:ok, snapshot} = SessionReconciliation.reconcile(participant_id)
      assert!(snapshot.canonical_state == :CONVERSATION, "matched participant canonical state")
      assert!(snapshot.conversation.conversation_id == pending_id, "same durable Conversation")
      assert!(
        {:error, :participant_busy} ==
          MatchmakingEngine.join_queue(participant_id, :EXPLORE, nil, nil, nil),
        "no contradictory queue admission"
      )
    end

    {:ok, waiting_state} = SessionReconciliation.reconcile(record["waiting"])
    assert!(waiting_state.canonical_state == :AVAILABLE, "volatile queue not restored falsely")

    {:ok, new_runtime_pid} = ConversationServer.ensure_started(pending_id)
    assert!({:ok, new_runtime_pid} == ConversationServer.ensure_started(pending_id), "idempotent runtime")
    assert!({:error, :terminal_conversation} == ConversationServer.ensure_started(terminal_id),
      "terminal conversation must not resurrect")

    assert!(Repo.aggregate(Matching, :count, :match_id) == 2, "no duplicate Matches")
    assert!(Repo.aggregate(Conversation, :count, :conversation_id) == 2, "no duplicate Conversations")
    assert!(reservation_count() == 2, "no duplicate or stale reservations")
    assert!(Repo.aggregate(Message, :count, :message_id) == 0, "no persistent live transcripts")
    IO.puts("TEAM1E_FULL_BEAM_RESTART_PENDING_AND_TERMINAL=PASS")
  end

  defp queue_pair!(a, b) do
    {:ok, _} = MatchmakingEngine.join_queue(a, :EXPLORE, nil, nil, nil)
    {:ok, _} = MatchmakingEngine.join_queue(b, :EXPLORE, nil, nil, nil)
  end

  defp reservation_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*)::int FROM participant_pairing_reservations")
    count
  end

  defp assert!(true, _label), do: :ok
  defp assert!(false, label), do: raise("Team 1E BEAM restart assertion failed: #{label}")
end

Team1EBeamRestartProbe.run()
