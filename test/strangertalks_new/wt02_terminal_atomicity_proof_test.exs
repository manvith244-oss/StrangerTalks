defmodule StrangertalksNew.WT02TerminalAtomicityProofTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Matchmaking.MatchmakingEngine
  alias StrangertalksNew.QueueEngine.QueueState
  alias StrangertalksNew.{Repo, SessionReconciliation}

  @terminal_constraint "wt02_reject_terminal_ended_at"

  setup do
    Agent.update(QueueState, fn _ -> %{} end)
    drop_terminal_constraint()
    :ok
  end

  test "A: normal explicit terminalization commits durable truth before terminal authority" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id

    %{pid: pid, a_client: a_client, b_client: b_client} =
      activate_runtime(conversation_id, a.participant_id, b.participant_id)

    :ok =
      Phoenix.PubSub.subscribe(
        StrangertalksNew.PubSub,
        "strangertalks:matchmaking"
      )

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent", message_id: ^message_id}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "wt02 baseline pending message"
             )

    assert_receive {:wt02_client_a,
                    {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}},
                   500

    assert_receive {:wt02_client_b,
                    {:conversation_message,
                     %{message_id: ^message_id, content: "wt02 baseline pending message"}}},
                   500

    assert {:ok, before_end} = ConversationServer.inspect_state(conversation_id)
    assert before_end.pending_count == 1
    assert active_reservations(conversation.match_id) == 2

    monitor = Process.monitor(pid)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    assert_receive {:wt02_client_a,
                    {:conversation_message_status,
                     %{message_id: ^message_id, status: "failed", reason: "participant_completed"}}},
                   500

    assert_receive {:wt02_client_a,
                    {:conversation_completed, %{status: "ended", reason: "participant_completed"}}},
                   500

    assert_receive {:wt02_client_b,
                    {:conversation_completed, %{status: "ended", reason: "participant_completed"}}},
                   500

    assert_receive {:conversation_event, :"conversation.ended",
                    %{
                      "payload" => %{
                        "conversation_id" => ^conversation_id,
                        "reason" => "PARTICIPANT_COMPLETED"
                      }
                    }},
                   500

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.conversation_completed == true
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator == a.participant_id
    assert active_reservations(conversation.match_id) == 0
    assert ConversationServer.lookup(conversation_id) == {:error, :not_started}
    assert ConversationServer.ensure_started(conversation_id) == {:error, :terminal_conversation}

    # Duplicate explicit End after durable commit converges through durable truth and
    # does not produce a second terminal notification/event.
    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    refute_receive {:wt02_client_a, {:conversation_completed, _}}, 100
    refute_receive {:wt02_client_b, {:conversation_completed, _}}, 100
    refute_receive {:conversation_event, :"conversation.ended", _}, 100

    assert Process.alive?(a_client)
    assert Process.alive?(b_client)
  end

  test "B/C: pending teardown precedes failed DB commit, gates actions, retries, then converges once" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id

    %{pid: pid, a_client: _a_client, b_client: _b_client} =
      activate_runtime(conversation_id, a.participant_id, b.participant_id)

    :ok =
      Phoenix.PubSub.subscribe(
        StrangertalksNew.PubSub,
        "strangertalks:matchmaking"
      )

    message_id = Ecto.UUID.generate()
    duplicate_content = "wt02 cut-a accepted-before-terminal"

    assert {:ok, %{status: "sent", message_id: ^message_id}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               duplicate_content
             )

    assert_receive {:wt02_client_a,
                    {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}},
                   500

    assert_receive {:wt02_client_b, {:conversation_message, %{message_id: ^message_id}}},
                   500

    assert {:ok, before_cut} = ConversationServer.inspect_state(conversation_id)
    assert before_cut.pending_count == 1
    epoch_id = before_cut.epoch_id
    assert active_reservations(conversation.match_id) == 2

    add_terminal_constraint()

    try do
      assert {:ok, %{status: "ending"}} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      # Volatile message truth is already terminalized even though the durable row did
      # not move. This is the exact WT-02 pre-commit contradiction.
      assert_receive {:wt02_client_a,
                      {:conversation_message_status,
                       %{
                         message_id: ^message_id,
                         status: "failed",
                         reason: "participant_completed"
                       }}},
                     500

      durable_after_cut = Repo.get!(Conversation, conversation_id)
      assert durable_after_cut.conversation_status == :ACTIVE
      assert durable_after_cut.ended_at == nil
      assert active_reservations(conversation.match_id) == 2

      assert Process.alive?(pid)
      assert {:ok, terminating} = ConversationServer.inspect_state(conversation_id)
      assert terminating.lifecycle_status == :TERMINATING
      assert terminating.pending_count == 0
      assert terminating.pending == %{}
      assert terminating.completed[message_id].final_state == :failed

      assert Enum.find(terminating.recent_messages, &(&1.message_id == message_id)).delivery_status ==
               :failed

      assert %{retry_token: retry_token_1, retry_ref: retry_ref_1} = terminating.terminal_intent
      assert is_reference(retry_token_1)
      assert is_reference(retry_ref_1)

      # No terminal authority is emitted while Postgres remains nonterminal.
      refute_receive {:wt02_client_a, {:conversation_completed, _}}, 100
      refute_receive {:wt02_client_b, {:conversation_completed, _}}, 100
      refute_receive {:conversation_event, :"conversation.ended", _}, 100

      # Actions while the runtime is TERMINATING.
      assert {:error, :conversation_terminating} =
               ConversationServer.append_message(
                 conversation_id,
                 a.participant_id,
                 Ecto.UUID.generate(),
                 "new message during terminating"
               )

      assert {:error, :conversation_terminating} =
               ConversationServer.append_message(
                 conversation_id,
                 a.participant_id,
                 message_id,
                 duplicate_content
               )

      assert {:error, :conversation_terminating} =
               ConversationServer.acknowledge_message(
                 conversation_id,
                 b.participant_id,
                 message_id
               )

      assert {:error, :conversation_inactive} =
               ConversationServer.start_typing(conversation_id, a.participant_id)

      assert {:ok, %{status: "ending"}} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      reconnect_probe = start_probe(:wt02_reconnect_probe)

      assert {:error, :conversation_inactive} =
               ConversationServer.sync_and_register_channel(
                 conversation_id,
                 a.participant_id,
                 reconnect_probe,
                 epoch_id,
                 1
               )

      # Durable reconciliation still projects ACTIVE while the live runtime refuses
      # ordinary conversation work.
      assert {:ok,
              %{
                canonical_state: :CONVERSATION,
                conversation: %{conversation_id: ^conversation_id, status: "ACTIVE"}
              }} = SessionReconciliation.reconcile(a.participant_id)

      # Force a second persistence attempt while the same narrow DB failure remains.
      # The retry re-schedules; it does not re-fail the already-cleared message.
      send(pid, {:retry_terminal_persistence, retry_token_1})

      assert_eventually(fn ->
        case ConversationServer.inspect_state(conversation_id) do
          {:ok,
           %{
             lifecycle_status: :TERMINATING,
             terminal_intent: %{retry_token: retry_token_2}
           }}
          when is_reference(retry_token_2) and retry_token_2 != retry_token_1 ->
            true

          _ ->
            false
        end
      end)

      assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
      assert active_reservations(conversation.match_id) == 2

      refute_receive {:wt02_client_a,
                      {:conversation_message_status, %{message_id: ^message_id, status: "failed"}}},
                     100

      refute_receive {:wt02_client_a, {:conversation_completed, _}}, 100
      refute_receive {:wt02_client_b, {:conversation_completed, _}}, 100

      assert {:ok, still_terminating} = ConversationServer.inspect_state(conversation_id)
      retry_token_2 = still_terminating.terminal_intent.retry_token
      assert is_reference(retry_token_2)

      # Remove only the injected failure and trigger the retained retry intent.
      drop_terminal_constraint()
      monitor = Process.monitor(pid)
      send(pid, {:retry_terminal_persistence, retry_token_2})

      assert_receive {:wt02_client_a,
                      {:conversation_completed,
                       %{status: "ended", reason: "participant_completed"}}},
                     1_000

      assert_receive {:wt02_client_b,
                      {:conversation_completed,
                       %{status: "ended", reason: "participant_completed"}}},
                     1_000

      assert_receive {:conversation_event, :"conversation.ended",
                      %{
                        "payload" => %{
                          "conversation_id" => ^conversation_id,
                          "reason" => "PARTICIPANT_COMPLETED"
                        }
                      }},
                     1_000

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000

      terminal = Repo.get!(Conversation, conversation_id)
      assert terminal.conversation_status == :ENDED
      assert terminal.ending_type == :NATURAL_END
      assert terminal.conversation_completed == true
      assert active_reservations(conversation.match_id) == 0
      assert ConversationServer.lookup(conversation_id) == {:error, :not_started}

      refute_receive {:wt02_client_a, {:conversation_completed, _}}, 100
      refute_receive {:wt02_client_b, {:conversation_completed, _}}, 100
      refute_receive {:conversation_event, :"conversation.ended", _}, 100
    after
      drop_terminal_constraint()
    end
  end

  test "D: process death in pre-commit TERMINATING window loses terminal intent and resurrects ACTIVE runtime" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    %{pid: pid} = activate_runtime(conversation_id, a.participant_id, b.participant_id)

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "wt02 precommit crash message"
             )

    assert_receive {:wt02_client_a,
                    {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}},
                   500

    assert_receive {:wt02_client_b, {:conversation_message, %{message_id: ^message_id}}}, 500

    assert {:ok, before_cut} = ConversationServer.inspect_state(conversation_id)
    old_epoch = before_cut.epoch_id

    add_terminal_constraint()

    try do
      assert {:ok, %{status: "ending"}} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      assert_receive {:wt02_client_a,
                      {:conversation_message_status,
                       %{
                         message_id: ^message_id,
                         status: "failed",
                         reason: "participant_completed"
                       }}},
                     500

      assert Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
      assert active_reservations(conversation.match_id) == 2

      assert {:ok, %{lifecycle_status: :TERMINATING}} =
               ConversationServer.inspect_state(conversation_id)

      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 500

      # Because durable truth never committed, the transient child is restarted from
      # the still-ACTIVE row. The volatile terminal intent and all message metadata are gone.
      new_pid = await_restarted_runtime(conversation_id, pid)
      assert Process.alive?(new_pid)

      assert {:ok, restarted} = ConversationServer.inspect_state(conversation_id)
      assert restarted.lifecycle_status == :ACTIVE
      assert restarted.terminal_intent == nil
      assert restarted.pending == %{}
      assert restarted.completed == %{}
      assert restarted.recent_messages == []
      assert restarted.pending_count == 0
      assert restarted.next_sequence == 1
      refute restarted.epoch_id == old_epoch

      durable_after_restart = Repo.get!(Conversation, conversation_id)
      assert durable_after_restart.conversation_status == :ACTIVE
      assert durable_after_restart.ended_at == nil
      assert active_reservations(conversation.match_id) == 2

      assert {:ok,
              %{
                canonical_state: :CONVERSATION,
                conversation: %{conversation_id: ^conversation_id, status: "ACTIVE"}
              }} = SessionReconciliation.reconcile(a.participant_id)

      # A reconnect sees a fresh epoch with no replay of the already-failed accepted
      # message, and the conversation resumes accepting new work.
      reconnect_a = start_probe(:wt02_reconnect_a)
      reconnect_b = start_probe(:wt02_reconnect_b)

      assert {:ok, %{status: "epoch_changed", epoch_id: new_epoch, messages: []}} =
               ConversationServer.sync_and_register_channel(
                 conversation_id,
                 a.participant_id,
                 reconnect_a,
                 old_epoch,
                 1
               )

      assert new_epoch == restarted.epoch_id

      assert {:ok, _} =
               ConversationServer.sync_and_register_channel(
                 conversation_id,
                 b.participant_id,
                 reconnect_b,
                 old_epoch,
                 1
               )

      drain_mailbox()

      assert {:ok, %{status: "sent"}} =
               ConversationServer.append_message(
                 conversation_id,
                 a.participant_id,
                 Ecto.UUID.generate(),
                 "conversation resumed after lost terminal intent"
               )

      refute_receive {:wt02_client_a, {:conversation_completed, _}}, 100
      refute_receive {:wt02_client_b, {:conversation_completed, _}}, 100

      # Cleanup only after the proof: remove the injected DB failure and terminalize
      # the resurrected isolated conversation so the test leaves no live runtime.
      drop_terminal_constraint()

      assert {:ok, %{status: "ended"}} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      assert_eventually(fn ->
        ConversationServer.lookup(conversation_id) == {:error, :not_started}
      end)
    after
      drop_terminal_constraint()
    end
  end

  test "F/G: duplicate and simultaneous participant terminal requests converge on one durable terminal row" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    %{pid: _pid} = activate_runtime(conversation_id, a.participant_id, b.participant_id)

    :ok =
      Phoenix.PubSub.subscribe(
        StrangertalksNew.PubSub,
        "strangertalks:matchmaking"
      )

    task_a =
      Task.async(fn ->
        receive do
          :go -> ConversationServer.complete_conversation(conversation_id, a.participant_id)
        end
      end)

    task_b =
      Task.async(fn ->
        receive do
          :go -> ConversationServer.complete_conversation(conversation_id, b.participant_id)
        end
      end)

    send(task_a.pid, :go)
    send(task_b.pid, :go)

    results = [Task.await(task_a, 2_000), Task.await(task_b, 2_000)]

    assert Enum.all?(
             results,
             &match?({:ok, %{status: status}} when status in ["ended", "ending"], &1)
           )

    assert_receive {:wt02_client_a, {:conversation_completed, %{status: "ended"}}}, 1_000
    assert_receive {:wt02_client_b, {:conversation_completed, %{status: "ended"}}}, 1_000

    assert_receive {:conversation_event, :"conversation.ended",
                    %{"payload" => %{"conversation_id" => ^conversation_id}}},
                   1_000

    refute_receive {:wt02_client_a, {:conversation_completed, _}}, 100
    refute_receive {:wt02_client_b, {:conversation_completed, _}}, 100
    refute_receive {:conversation_event, :"conversation.ended", _}, 100

    terminal = Repo.get!(Conversation, conversation_id)
    assert terminal.conversation_status == :ENDED
    assert terminal.ending_type == :NATURAL_END
    assert terminal.ending_initiator in [a.participant_id, b.participant_id]
    assert active_reservations(conversation.match_id) == 0

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, a.participant_id)

    assert {:ok, %{status: "ended"}} =
             ConversationServer.complete_conversation(conversation_id, b.participant_id)
  end

  test "PENDING variant: same pre-commit gap exists, then converges to FAILED/PARTICIPANT_LEFT" do
    %{conversation: conversation, a: a, b: b} = queue_match()
    conversation_id = conversation.conversation_id
    assert conversation.conversation_status == :PENDING

    assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
    a_client = start_probe(:wt02_client_a)

    # Register only one participant so durable conversation truth remains PENDING.
    assert {:ok, %{status: "initial"}} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a.participant_id,
               a_client,
               nil,
               0
             )

    assert Repo.get!(Conversation, conversation_id).conversation_status == :PENDING
    drain_mailbox()

    message_id = Ecto.UUID.generate()

    assert {:ok, %{status: "sent"}} =
             ConversationServer.append_message(
               conversation_id,
               a.participant_id,
               message_id,
               "wt02 pending-path message"
             )

    assert_receive {:wt02_client_a,
                    {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}},
                   500

    assert {:ok, %{pending_count: 1}} = ConversationServer.inspect_state(conversation_id)
    assert active_reservations(conversation.match_id) == 2

    add_terminal_constraint()

    try do
      assert {:ok, %{status: "ending"}} =
               ConversationServer.complete_conversation(conversation_id, a.participant_id)

      assert_receive {:wt02_client_a,
                      {:conversation_message_status,
                       %{
                         message_id: ^message_id,
                         status: "failed",
                         reason: "left_during_transition"
                       }}},
                     500

      assert Repo.get!(Conversation, conversation_id).conversation_status == :PENDING
      assert active_reservations(conversation.match_id) == 2

      assert {:ok, terminating} = ConversationServer.inspect_state(conversation_id)
      assert terminating.lifecycle_status == :TERMINATING
      assert terminating.pending_count == 0
      assert terminating.completed[message_id].final_state == :failed
      retry_token = terminating.terminal_intent.retry_token
      assert is_reference(retry_token)

      drop_terminal_constraint()
      monitor = Process.monitor(pid)
      send(pid, {:retry_terminal_persistence, retry_token})

      assert_receive {:wt02_client_a,
                      {:conversation_completed,
                       %{status: "ended", reason: "left_during_transition"}}},
                     1_000

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000

      terminal = Repo.get!(Conversation, conversation_id)
      assert terminal.conversation_status == :FAILED
      assert terminal.ending_type == :PARTICIPANT_LEFT
      assert terminal.ending_initiator == a.participant_id
      assert terminal.conversation_completed == false
      assert active_reservations(conversation.match_id) == 0
    after
      drop_terminal_constraint()
    end
  end

  defp activate_runtime(conversation_id, a_id, b_id) do
    assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
    a_client = start_probe(:wt02_client_a)
    b_client = start_probe(:wt02_client_b)

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               a_id,
               a_client,
               nil,
               0
             )

    assert {:ok, _} =
             ConversationServer.sync_and_register_channel(
               conversation_id,
               b_id,
               b_client,
               nil,
               0
             )

    assert_eventually(fn ->
      Repo.get!(Conversation, conversation_id).conversation_status == :ACTIVE
    end)

    drain_mailbox()

    %{pid: pid, a_client: a_client, b_client: b_client}
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

  defp add_terminal_constraint do
    drop_terminal_constraint()

    Repo.query!("""
    ALTER TABLE conversations
    ADD CONSTRAINT #{@terminal_constraint}
    CHECK (ended_at IS NULL)
    """)

    :ok
  end

  defp drop_terminal_constraint do
    Repo.query!("""
    ALTER TABLE conversations
    DROP CONSTRAINT IF EXISTS #{@terminal_constraint}
    """)

    :ok
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

  defp await_restarted_runtime(conversation_id, old_pid) do
    assert_eventually(fn ->
      case ConversationServer.lookup(conversation_id) do
        {:ok, pid} when pid != old_pid -> Process.alive?(pid)
        _ -> false
      end
    end)

    {:ok, pid} = ConversationServer.lookup(conversation_id)
    pid
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
