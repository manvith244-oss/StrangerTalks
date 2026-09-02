defmodule StrangertalksNew.ConversationDeliveryTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Message
  alias StrangertalksNew.Repo

  setup do
    fixture = conversation_fixture()

    on_exit(fn ->
      case ConversationServer.lookup(fixture.conversation.conversation_id) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(StrangertalksNew.ConversationDynamicSupervisor, pid)

        {:error, :not_started} ->
          :ok
      end
    end)

    fixture
  end

  test "ensure_started is idempotent and tracks multiple tabs", context do
    conversation_id = context.conversation.conversation_id
    assert {:ok, pid} = ConversationServer.ensure_started(conversation_id)
    assert {:ok, ^pid} = ConversationServer.ensure_started(conversation_id)

    tab = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok =
             ConversationServer.register_channel(conversation_id, context.participant_a, self())

    assert :ok = ConversationServer.register_channel(conversation_id, context.participant_a, tab)

    assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert MapSet.size(state.participant_channels[context.participant_a]) == 2

    monitor = Process.monitor(tab)
    Process.exit(tab, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^tab, :killed}
    _ = :sys.get_state(pid)

    assert {:ok, state} = ConversationServer.inspect_state(conversation_id)
    assert MapSet.size(state.participant_channels[context.participant_a]) == 1
  end

  test "concurrent starts resolve to one registered supervised process", context do
    conversation_id = context.conversation.conversation_id

    results =
      1..20
      |> Task.async_stream(
        fn _index -> ConversationServer.ensure_started(conversation_id) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _pid}, &1))
    pids = Enum.map(results, fn {:ok, pid} -> pid end)
    assert [pid] = Enum.uniq(pids)
    assert {:ok, ^pid} = ConversationServer.lookup(conversation_id)

    matching_children =
      StrangertalksNew.ConversationDynamicSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.filter(fn {_id, child_pid, _type, modules} ->
        child_pid == pid and ConversationServer in modules
      end)

    assert length(matching_children) == 1
  end

  test "client message ID is retained, exact retries are idempotent, and conflicts are rejected",
       context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    assert {:ok, %{message_id: ^message_id, sequence: 1, status: "sent"}} =
             append(context, context.participant_a, message_id, "hello")

    assert {:ok, %{message_id: ^message_id, sequence: 1, status: "sent"}} =
             append(context, context.participant_a, message_id, "hello")

    assert {:error, :message_id_conflict} =
             append(context, context.participant_a, message_id, "changed")

    assert {:error, :message_id_conflict} =
             append(context, context.participant_b, message_id, "hello")

    assert {:ok, state} = state(context)
    assert state.pending_count == 1
    assert state.pending_bytes == 5
  end

  test "concurrent distinct sends receive one contiguous canonical sequence", context do
    register_both(context)
    ids = for _ <- 1..4, do: Ecto.UUID.generate()

    results =
      race(Enum.map(ids, fn id -> fn -> append(context, context.participant_a, id, id) end end))

    assert Enum.all?(results, &match?({:ok, %{status: "sent"}}, &1))

    assert results |> Enum.map(fn {:ok, result} -> result.sequence end) |> Enum.sort() ==
             Enum.to_list(1..4)

    assert {:ok, state} = state(context)
    assert state.pending_count == 4
    assert state.next_sequence == 5
  end

  test "concurrent exact retries converge and conflicting reuse cannot overwrite", context do
    register_both(context)
    message_id = Ecto.UUID.generate()

    exact =
      race([
        fn -> append(context, context.participant_a, message_id, "original") end,
        fn -> append(context, context.participant_a, message_id, "original") end
      ])

    assert Enum.all?(exact, &match?({:ok, %{sequence: 1}}, &1))

    conflict =
      race([
        fn -> append(context, context.participant_a, message_id, "original") end,
        fn -> append(context, context.participant_a, message_id, "changed") end
      ])

    assert Enum.count(conflict, &match?({:ok, %{sequence: 1}}, &1)) == 1
    assert Enum.count(conflict, &match?({:error, :message_id_conflict}, &1)) == 1
    assert {:ok, state} = state(context)
    assert state.pending_count == 1
    assert state.next_sequence == 2
    assert state.pending[message_id].content == "original"
  end

  test "concurrent duplicate progress terminalizes once", context do
    register_both(context)
    message_id = Ecto.UUID.generate()
    assert {:ok, _} = append(context, context.participant_a, message_id, "ack")

    results =
      race(4, fn ->
        report_progress(context, context.participant_b, 1)
      end)

    assert Enum.count(results, &match?({:ok, %{status: "applied"}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{status: "no_op"}}, &1)) == 3
    assert {:ok, state} = state(context)
    assert state.pending_count == 0
    assert Map.has_key?(state.completed, message_id)
  end

  test "server rejects malformed IDs even when called outside the channel", context do
    register_both(context)

    assert {:error, :invalid_message_id} =
             append(context, context.participant_a, "not-a-uuid", "hello")
  end

  test "delivery progress, duplicate progress, and content cleanup", context do
    register_both(context)
    message_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, message_id, "hello")

    assert_receive {:conversation_message,
                    %{message_id: ^message_id, sequence: 1, content: "hello", sent_at: _sent_at}}

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    assert {:error, :invalid_sequence} = report_progress(context, context.participant_a, 1)

    assert {:ok, state_before_recipient_progress} = state(context)
    assert state_before_recipient_progress.pending[message_id]

    assert {:ok, %{status: "applied"}} = report_progress(context, context.participant_b, 1)

    assert {:ok, %{status: "no_op"}} = report_progress(context, context.participant_b, 1)

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"}}

    assert {:ok, state} = state(context)
    assert state.pending == %{}
    assert state.pending_count == 0
    assert state.pending_bytes == 0
    refute Map.has_key?(state.completed[message_id], :content)

    assert {:ok, %{status: "delivered", sequence: 1}} =
             append(context, context.participant_a, message_id, "hello")

    assert {:error, :message_id_conflict} =
             append(context, context.participant_a, message_id, "different")
  end

  test "recipient progress matrix keeps candidate routing sent until authenticated cumulative evidence",
       context do
    register_both(context)
    sender_channel = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok =
             ConversationServer.register_channel(
               context.conversation.conversation_id,
               context.participant_a,
               sender_channel
             )

    message_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1, status: "sent"}} =
             append(context, context.participant_a, message_id, "truth")

    assert_receive {:conversation_message, %{message_id: ^message_id, sequence: 1}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    assert {:ok, before_progress} = state(context)
    assert before_progress.pending[message_id]
    refute Map.has_key?(before_progress.completed, message_id)

    recipient_channel = before_progress.participant_channels[context.participant_b] |> Enum.at(0)

    assert {:ok, %{status: "stale"}} =
             ConversationServer.report_delivery_progress(
               context.conversation.conversation_id,
               context.participant_b,
               recipient_channel,
               Ecto.UUID.generate(),
               1
             )

    assert {:error, :invalid_sequence} =
             ConversationServer.report_delivery_progress(
               context.conversation.conversation_id,
               context.participant_b,
               recipient_channel,
               before_progress.epoch_id,
               2
             )

    assert {:error, :invalid_sequence} =
             ConversationServer.report_delivery_progress(
               context.conversation.conversation_id,
               context.participant_b,
               sender_channel,
               before_progress.epoch_id,
               1
             )

    assert {:ok, %{status: "applied", highest_contiguous_sequence: 1}} =
             report_progress(context, context.participant_b, 1)

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"}}

    assert {:ok, %{status: "no_op", highest_contiguous_sequence: 1}} =
             report_progress(context, context.participant_b, 1)

    assert {:ok, after_progress} = state(context)
    assert after_progress.delivery_progress[context.participant_b] == 1
    assert after_progress.completed[message_id].final_state == :delivered

    refute_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"},
                    50}

    send(sender_channel, :stop)
  end

  test "delivery progress diagnostics are coarse and identity-free for apply, retry/no-op, stale, and invalid",
       context do
    events =
      for status <- [:applied, :no_op, :stale, :invalid],
          do: [:strangertalks_new, :delivery_progress, status]

    handler_id = "delivery-progress-privacy-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn name, measurements, metadata, _config ->
          send(test_pid, {:delivery_progress_diagnostic, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    register_both(context)

    assert {:ok, %{sequence: 1}} =
             append(context, context.participant_a, Ecto.UUID.generate(), "diagnostic privacy")

    assert {:ok, current} = state(context)
    assert {:ok, %{status: "applied"}} = report_progress(context, context.participant_b, 1)
    assert {:ok, %{status: "no_op"}} = report_progress(context, context.participant_b, 1)

    recipient_channel = current.participant_channels[context.participant_b] |> Enum.at(0)

    assert {:ok, %{status: "stale"}} =
             ConversationServer.report_delivery_progress(
               context.conversation.conversation_id,
               context.participant_b,
               recipient_channel,
               Ecto.UUID.generate(),
               1
             )

    assert {:error, :invalid_sequence} =
             ConversationServer.report_delivery_progress(
               context.conversation.conversation_id,
               context.participant_b,
               recipient_channel,
               current.epoch_id,
               2
             )

    for status <- [:applied, :no_op, :stale, :invalid] do
      assert_receive {:delivery_progress_diagnostic,
                      [:strangertalks_new, :delivery_progress, ^status], %{count: 1}, %{}}
    end
  end

  test "higher cumulative progress covers earlier obligations and makes a late lower report a no-op",
       context do
    register_both(context)
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    assert {:ok, %{sequence: 1, status: "sent"}} =
             append(context, context.participant_a, first_id, "first cumulative obligation")

    assert {:ok, %{sequence: 2, status: "sent"}} =
             append(context, context.participant_a, second_id, "second cumulative obligation")

    assert {:ok, %{status: "applied", highest_contiguous_sequence: 2}} =
             report_progress(context, context.participant_b, 2)

    assert {:ok, %{status: "no_op", highest_contiguous_sequence: 2}} =
             report_progress(context, context.participant_b, 1)

    assert {:ok, current} = state(context)
    assert current.delivery_progress[context.participant_b] == 2
    assert current.completed[first_id].final_state == :delivered
    assert current.completed[second_id].final_state == :delivered
  end

  test "disconnected recipient is buffered and replayed in sequence on reconnect", context do
    conversation_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, context.participant_a, self())

    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    assert {:ok, %{sequence: 1}} = append(context, context.participant_a, first_id, "first")
    assert {:ok, %{sequence: 2}} = append(context, context.participant_a, second_id, "second")
    refute_receive {:conversation_message, _payload}

    :ok = ConversationServer.register_channel(conversation_id, context.participant_b, self())
    assert_receive {:conversation_message, %{message_id: ^first_id, sequence: 1}}
    assert_receive {:conversation_message, %{message_id: ^second_id, sequence: 2}}
  end

  test "bounded JOIN establishes retained suffix as authoritative baseline", context do
    register_both(context)

    for sequence <- 1..51 do
      message_id = Ecto.UUID.generate()

      assert {:ok, %{sequence: ^sequence}} =
               append(context, context.participant_a, message_id, "retained")

      assert {:ok, _result} = report_progress(context, context.participant_b, sequence)
    end

    channel = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, payload} =
             ConversationServer.sync_and_register_channel(
               context.conversation.conversation_id,
               context.participant_b,
               channel,
               nil,
               0
             )

    assert payload.status == "initial"
    assert payload.baseline_sequence == 2
    assert payload.latest_sequence == 51
    assert Enum.map(payload.messages, & &1.sequence) == Enum.to_list(2..51)
    send(channel, :stop)
  end

  test "retry generations ignore stale and duplicate events without changing state", context do
    register_both(context)
    message_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, message_id, "retry me")
    assert_receive {:conversation_message, %{message_id: ^message_id}}

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}

    {:ok, pid} = ConversationServer.lookup(context.conversation.conversation_id)
    assert {:ok, initial_state} = state(context)
    first_token = initial_state.pending[message_id].retry_token

    send(pid, {:retry_message, message_id, first_token})
    send(pid, {:retry_message, message_id, first_token})
    _ = :sys.get_state(pid)

    assert_receive {:conversation_message, %{message_id: ^message_id, sequence: 1}}
    refute_receive {:conversation_message, %{message_id: ^message_id}}, 50
    refute_receive {:conversation_message_status, %{message_id: ^message_id}}, 50

    assert {:ok, after_valid_retry} = state(context)
    second_token = after_valid_retry.pending[message_id].retry_token
    assert second_token != first_token
    assert after_valid_retry.pending_count == 1
    assert after_valid_retry.pending_bytes == 8

    send(pid, {:retry_message, message_id, first_token})
    _ = :sys.get_state(pid)
    refute_receive {:conversation_message, %{message_id: ^message_id}}, 50

    send(pid, {:retry_message, message_id, second_token})
    _ = :sys.get_state(pid)
    assert_receive {:conversation_message, %{message_id: ^message_id, sequence: 1}}

    assert {:ok, before_ack} = state(context)
    third_token = before_ack.pending[message_id].retry_token

    assert {:ok, _result} = report_progress(context, context.participant_b, 1)

    assert_receive {:conversation_message_status, %{message_id: ^message_id, status: "delivered"}}
    send(pid, {:retry_message, message_id, third_token})
    _ = :sys.get_state(pid)
    refute_receive {:conversation_message, %{message_id: ^message_id}}, 50

    expiring_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, expiring_id, "expire")
    assert_receive {:conversation_message, %{message_id: ^expiring_id}}
    assert_receive {:conversation_message_status, %{message_id: ^expiring_id}}
    assert {:ok, expiring_state} = state(context)
    expiry_retry_token = expiring_state.pending[expiring_id].retry_token

    send(pid, {:expire_message, expiring_id})
    _ = :sys.get_state(pid)
    assert_receive {:conversation_message_status, %{message_id: ^expiring_id, status: "failed"}}
    send(pid, {:retry_message, expiring_id, expiry_retry_token})
    _ = :sys.get_state(pid)
    refute_receive {:conversation_message, %{message_id: ^expiring_id}}, 50

    assert {:ok, final_state} = state(context)
    assert final_state.pending_count == 0
    assert final_state.pending_bytes == 0
  end

  test "multiple tabs receive fan-out, acknowledge idempotently, and clean up monitors",
       context do
    conversation_id = context.conversation.conversation_id
    {:ok, pid} = ConversationServer.ensure_started(conversation_id)
    parent = self()
    sender_tabs = for label <- [:sender_one, :sender_two], do: relay_tab(parent, label)
    recipient_tabs = for label <- [:recipient_one, :recipient_two], do: relay_tab(parent, label)

    Enum.each(sender_tabs, fn tab ->
      assert :ok =
               ConversationServer.register_channel(conversation_id, context.participant_a, tab)
    end)

    Enum.each(recipient_tabs, fn tab ->
      assert :ok =
               ConversationServer.register_channel(conversation_id, context.participant_b, tab)
    end)

    message_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, message_id, "all tabs")

    for label <- [:sender_one, :sender_two] do
      assert_receive {:relayed, ^label,
                      {:conversation_message_status, %{message_id: ^message_id, status: "sent"}}}
    end

    for label <- [:recipient_one, :recipient_two] do
      assert_receive {:relayed, ^label,
                      {:conversation_message, %{message_id: ^message_id, content: "all tabs"}}}
    end

    assert {:ok, %{status: "applied"}} = report_progress(context, context.participant_b, 1)

    assert {:ok, %{status: "no_op"}} = report_progress(context, context.participant_b, 1)

    for label <- [:sender_one, :sender_two] do
      assert_receive {:relayed, ^label,
                      {:conversation_message_status,
                       %{message_id: ^message_id, status: "delivered"}}}
    end

    [first_recipient | _] = recipient_tabs
    ref = Process.monitor(first_recipient)
    Process.exit(first_recipient, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first_recipient, _}
    _ = :sys.get_state(pid)
    assert {:ok, one_tab_left} = state(context)
    assert MapSet.size(one_tab_left.participant_channels[context.participant_b]) == 1
    refute Map.has_key?(one_tab_left.recovery_timers, context.participant_b)

    remaining_tabs = sender_tabs ++ tl(recipient_tabs)
    remaining_refs = Enum.map(remaining_tabs, fn tab -> {tab, Process.monitor(tab)} end)
    Enum.each(remaining_tabs, &Process.exit(&1, :kill))
    Enum.each(remaining_refs, fn {tab, r} -> assert_receive {:DOWN, ^r, :process, ^tab, _} end)
    _ = :sys.get_state(pid)
    assert {:ok, empty_tabs} = state(context)

    assert Enum.all?(empty_tabs.participant_channels, fn {_id, tabs} -> MapSet.size(tabs) == 0 end)

    assert empty_tabs.monitor_refs == %{}
  end

  test "recovery expiry fails pending messages, persists abandonment, and stops", context do
    conversation_id = context.conversation.conversation_id
    register_both(context)
    :ok = ConversationServer.unregister_channel(conversation_id, context.participant_b, self())
    message_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, message_id, "waiting")

    assert {:ok, state} = state(context)
    timer_token = state.recovery_timers[context.participant_b].token
    {:ok, pid} = ConversationServer.lookup(conversation_id)
    monitor = Process.monitor(pid)
    send(pid, {:recovery_grace_expired, context.participant_b, timer_token})

    assert_receive {:conversation_message_status,
                    %{message_id: ^message_id, status: "failed", reason: "conversation_abandoned"}}

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert Repo.get!(Conversation, conversation_id).conversation_status == :ABANDONED
    assert Repo.get!(Conversation, conversation_id).ended_at
  end

  test "terminal persistence failure retains no content and retries safely until ENDED persists",
       context do
    conversation_id = context.conversation.conversation_id
    register_both(context)
    Phoenix.PubSub.subscribe(StrangertalksNew.PubSub, "strangertalks:matchmaking")
    message_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, message_id, "temporary")
    assert_receive {:conversation_message, %{message_id: ^message_id}}
    assert_receive {:conversation_message_status, %{message_id: ^message_id}}

    canonical_conversation = Repo.get!(Conversation, conversation_id)
    assert canonical_conversation.conversation_status == :ACTIVE
    deleted_conversation = Repo.delete!(canonical_conversation)
    {:ok, pid} = ConversationServer.lookup(conversation_id)
    :ok = ConversationServer.trigger_safety_terminate(conversation_id)
    _ = :sys.get_state(pid)

    assert_receive {:conversation_message_status,
                    %{message_id: ^message_id, status: "failed", reason: "safety_terminated"}}

    assert {:ok, terminating} = state(context)
    assert terminating.lifecycle_status == :TERMINATING
    assert terminating.pending == %{}
    assert terminating.pending_count == 0
    assert terminating.pending_bytes == 0
    refute is_nil(terminating.terminal_intent.retry_token)
    refute_receive {:conversation_event, :"conversation.ended", _packet}, 50

    assert {:error, :conversation_terminating} =
             append(context, context.participant_a, Ecto.UUID.generate(), "rejected")

    assert {:error, :conversation_terminating} =
             ConversationServer.acknowledge_message(
               conversation_id,
               context.participant_b,
               message_id
             )

    first_retry_token = terminating.terminal_intent.retry_token
    send(pid, {:retry_terminal_persistence, first_retry_token})
    send(pid, {:retry_terminal_persistence, first_retry_token})
    _ = :sys.get_state(pid)
    assert {:ok, still_terminating} = state(context)
    current_token = still_terminating.terminal_intent.retry_token
    assert current_token != first_retry_token
    refute_receive {:conversation_event, :"conversation.ended", _packet}, 50

    deleted_conversation
    |> Ecto.put_meta(state: :built)
    |> Repo.insert!()

    monitor = Process.monitor(pid)
    send(pid, {:retry_terminal_persistence, current_token})

    assert_receive {:conversation_event, :"conversation.ended",
                    %{"payload" => %{"reason" => "SAFETY_TERMINATED"}}}

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute_receive {:conversation_event, :"conversation.ended", _packet}, 50

    persisted = Repo.get!(Conversation, conversation_id)
    assert persisted.conversation_status == :ENDED
    assert persisted.ended_at
  end

  test "limits apply only to unacknowledged content", context do
    register_both(context)

    for sequence <- 1..51 do
      message_id = Ecto.UUID.generate()

      assert {:ok, %{sequence: ^sequence}} =
               append(context, context.participant_a, message_id, "ok")

      assert {:ok, _result} = report_progress(context, context.participant_b, sequence)
    end

    assert {:ok, state} = state(context)
    assert state.pending_count == 0
    assert state.pending_bytes == 0
  end

  test "51st simultaneous message, total byte cap, and individual size cap are enforced",
       context do
    register_both(context)

    for _index <- 1..50 do
      assert {:ok, _result} =
               append(context, context.participant_a, Ecto.UUID.generate(), "pending")
    end

    assert {:error, :buffer_overflow_imminent} =
             append(context, context.participant_a, Ecto.UUID.generate(), "overflow")

    assert {:error, :message_too_large} =
             append(
               context,
               context.participant_a,
               Ecto.UUID.generate(),
               String.duplicate("x", 16_385)
             )
  end

  test "total byte cap counts only pending content", context do
    conversation_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, context.participant_a, self())
    payload = String.duplicate("x", 16_384)

    for _index <- 1..16 do
      assert {:ok, _result} =
               append(context, context.participant_a, Ecto.UUID.generate(), payload)
    end

    assert {:ok, state} = state(context)
    assert state.pending_count == 16
    assert state.pending_bytes == 262_144

    assert {:error, :buffer_overflow_imminent} =
             append(context, context.participant_a, Ecto.UUID.generate(), "x")
  end

  test "completed metadata is content-free and pruned by its timer", context do
    register_both(context)
    message_id = Ecto.UUID.generate()
    assert {:ok, _result} = append(context, context.participant_a, message_id, "done")

    assert {:ok, _result} = report_progress(context, context.participant_b, 1)

    assert {:ok, state} = state(context)
    completed_at = state.completed[message_id].completed_at
    {:ok, pid} = ConversationServer.lookup(context.conversation.conversation_id)
    send(pid, {:prune_completed, message_id, completed_at})
    _ = :sys.get_state(pid)

    assert {:ok, state} = state(context)
    refute Map.has_key?(state.completed, message_id)
  end

  test "live delivery creates no PostgreSQL Message row", context do
    register_both(context)

    assert {:ok, _result} =
             append(context, context.participant_a, Ecto.UUID.generate(), "memory only")

    assert Repo.aggregate(Message, :count, :message_id) == 0
  end

  defp register_both(context) do
    conversation_id = context.conversation.conversation_id
    {:ok, _pid} = ConversationServer.ensure_started(conversation_id)
    :ok = ConversationServer.register_channel(conversation_id, context.participant_a, self())
    :ok = ConversationServer.register_channel(conversation_id, context.participant_b, self())
  end

  defp append(context, sender_id, message_id, content) do
    ConversationServer.append_message(
      context.conversation.conversation_id,
      sender_id,
      message_id,
      content
    )
  end

  defp state(context), do: ConversationServer.inspect_state(context.conversation.conversation_id)

  defp report_progress(context, participant_id, sequence) do
    {:ok, current} = state(context)
    channel_pid = current.participant_channels[participant_id] |> Enum.at(0)

    ConversationServer.report_delivery_progress(
      context.conversation.conversation_id,
      participant_id,
      channel_pid,
      current.epoch_id,
      sequence
    )
  end

  defp relay_tab(parent, label) do
    spawn(fn -> relay_messages(parent, label) end)
  end

  defp relay_messages(parent, label) do
    receive do
      message ->
        send(parent, {:relayed, label, message})
        relay_messages(parent, label)
    end
  end

  defp race(count, operation), do: race(List.duplicate(operation, count))

  defp race(operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> operation.()
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      task_pid = task.pid
      assert_receive {:ready, ^task_pid}
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, :infinity))
  end

  defp conversation_fixture do
    {:ok, participant_a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, participant_b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, match} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        compatibility_score: Decimal.new("1.0"),
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
        learning_processed: false
      })

    {:ok, conversation} =
      StrangertalksNew.Conversations.create_conversation(%{
        created_at: now,
        match_id: match.match_id,
        participant_a_id: participant_a.participant_id,
        participant_b_id: participant_b.participant_id,
        conversation_status: :PENDING,
        door_type: :JUST_TALK,
        message_count: 0,
        voice_note_count: 0,
        bridge_shown: false,
        bridge_used: false,
        bridge_ignored: false,
        conversation_completed: false,
        memory_created: false,
        relationship_created: false,
        reconnected_later: false,
        memory_count: 0,
        relationship_created_at_end: false,
        report_count: 0,
        block_count: 0,
        safety_flagged: false,
        learning_processed: false,
        duration_seconds: 0
      })

    %{
      conversation: conversation,
      participant_a: participant_a.participant_id,
      participant_b: participant_b.participant_id
    }
  end
end
