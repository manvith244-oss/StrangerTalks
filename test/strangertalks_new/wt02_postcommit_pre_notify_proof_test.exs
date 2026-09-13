defmodule StrangertalksNew.WT02PostCommitPreNotifyProofTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{Repo, SessionReconciliation}

  setup do
    StrangertalksNew.PairingTestIsolation.install!()
    Agent.update(QueueState, fn _ -> %{} end)
    :ok
  end

  test "E: process death after durable terminal commit but before notification cannot resurrect nonterminal truth" do
    # Test-only runtime instrumentation. The repository source remains unchanged: this
    # test recompiles ConversationServer in this isolated BEAM with a single kill hook
    # immediately after persist_conversation_status/4 returns {:ok, conversation} and
    # before reflection finalization, client notification, event fanout, or runtime stop.
    install_postcommit_probe_instrumentation!()

    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    assert conversation.conversation_status == :PENDING

    assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
    a_client = start_probe(:wt02_postcommit_a)
    b_client = start_probe(:wt02_postcommit_b)

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               a_client,
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               b.participant_id,
               b_client,
               nil,
               0
             )

    assert_eventually(fn ->
      Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
    end)

    drain_mailbox()

    :ok =
      Phoenix.PubSub.subscribe(
        StrangertalksNew.PubSub,
        "strangertalks:matchmaking"
      )

    parent = self()

    Application.put_env(
      :strangertalks_new,
      :wt02_postcommit_probe,
      fn server_pid, persisted_conversation ->
        send(
          parent,
          {:wt02_postcommit_cut, server_pid, persisted_conversation.conversation_id,
           persisted_conversation.conversation_status}
        )

        Process.exit(server_pid, :kill)
      end
    )

    on_exit(fn -> Application.delete_env(:strangertalks_new, :wt02_postcommit_probe) end)

    monitor = Process.monitor(pid)

    # The GenServer dies before it can reply, so complete_conversation/2 falls back to
    # durable terminal truth and still returns ended to the initiating caller.
    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    assert_receive {:wt02_postcommit_cut, ^pid, ^conversation_id, :ENDED}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.conversation_completed == true
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator == a.participant_id
    assert active_reservations(conversation.match_id) == 0

    # The killed process never reached notify_terminal_clients/2 or bus fanout.
    refute_receive {:wt02_postcommit_a, {:conversation_completed, _}}, 100
    refute_receive {:wt02_postcommit_b, {:conversation_completed, _}}, 100
    refute_receive {:conversation_event, :"conversation.ended", _}, 100

    # Durable terminal truth prevents the transient child from resurrecting. A missed
    # client notification is recoverable by canonical reconciliation / join refusal.
    assert_eventually(fn ->
      ConversationServer.lookup(conversation_id) == {:error, :not_started}
    end)

    assert {:error, :terminal_conversation} = ConversationServer.ensure_started(conversation_id)

    assert {:ok, %{canonical_state: :AVAILABLE, conversation: nil}} =
             SessionReconciliation.reconcile(a.participant_id)

    assert {:ok, %{canonical_state: :AVAILABLE, conversation: nil}} =
             SessionReconciliation.reconcile(b.participant_id)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, b.participant_id)
  end

  defp install_postcommit_probe_instrumentation! do
    source_path =
      Path.expand(
        "../../lib/strangertalks_new/conversation_lifecycle/conversation_server.ex",
        __DIR__
      )

    source = File.read!(source_path)

    needle = """
      {:ok, conversation} ->
        source_resolver = fn client_msg_id ->
    """

    replacement = """
      {:ok, conversation} ->
        if hook = Application.get_env(:strangertalks_new, :wt02_postcommit_probe) do
          hook.(self(), conversation)
        end

        source_resolver = fn client_msg_id ->
    """

    assert String.contains?(source, needle)
    patched = String.replace(source, needle, replacement, global: false)
    refute patched == source

    Code.compile_string(patched, source_path)
    :ok
  end

  defp queue_match do
    a = participant_fixture()
    b = participant_fixture()

    assert {:ok, _} = MatchmakingEngine.join_queue(a.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, _} = MatchmakingEngine.join_queue(b.participant_id, :EXPLORE, "en", nil, nil)
    assert {:ok, [match_id]} = MatchmakingEngine.evaluate_pending_matches()

    %{
      conversation: Repo.get_by!(Conversation, match_id: match_id),
      a: a,
      b: b
    }
  end

  defp participant_fixture do
    {:ok, participant} = StrangertalksNew.Participants.create_participant(%{})
    participant
  end

  defp active_reservations(match_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM participant_pairing_reservations WHERE match_id = $1 AND released_at IS NULL",
        [Ecto.UUID.dump!(match_id)]
      )

    count
  end

  defp start_probe(tag) do
    parent = self()

    spawn_link(fn ->
      probe_loop(parent, tag)
    end)
  end

  defp probe_loop(parent, tag) do
    receive do
      message ->
        send(parent, {tag, message})
        probe_loop(parent, tag)
    end
  end

  defp drain_mailbox do
    receive do
      _message -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
