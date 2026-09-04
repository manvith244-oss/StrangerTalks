defmodule StrangertalksNew.T02GenerationTimelineProbeTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.Conversation
  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Repo

  @ds StrangertalksNew.ConversationDynamicSupervisor
  @reg StrangertalksNew.DistributedRegistry
  @parallel 32
  @rounds 8

  test "proof-only ConversationServer generation timeline" do
    IO.puts(
      "TRACE lane=#{System.get_env("TRACE_LANE")} parallel=#{@parallel} rounds=#{@rounds}"
    )

    for round <- 1..@rounds do
      fixture = conversation_fixture()
      cid = fixture.conversation.conversation_id
      restart = effective_restart(cid)

      snap("before_initial", round, cid, nil)
      {:ok, g1} = ConversationServer.ensure_started(cid)
      ds1 = Process.whereis(@ds)
      ds_ref = Process.monitor(ds1)
      g1_ref = Process.monitor(g1)
      Process.sleep(5)
      snap("after_initial", round, cid, g1)

      IO.puts(
        "GEN round=#{round} seq=1 cid=#{cid} pid=#{inspect(g1)} path=explicit_ensure_started " <>
          "supervisor=#{inspect(@ds)} ds=#{inspect(ds1)} restart=#{inspect(restart)} " <>
          "ts=#{System.monotonic_time()}"
      )

      parent = self()

      tasks =
        for i <- 1..@parallel do
          Task.async(fn ->
            send(parent, {:ready, self(), i})

            receive do
              {:go, ^cid} -> :ok
            end

            {i, self(), ConversationServer.ensure_started(cid)}
          end)
        end

      Enum.each(1..@parallel, fn _ -> assert_receive {:ready, _, _}, 5_000 end)
      IO.puts("CALLERS_BLOCKED round=#{round} count=#{@parallel} ts=#{System.monotonic_time()}")
      snap("before_kill", round, cid, g1)

      IO.puts(
        "KILL round=#{round} cid=#{cid} pid=#{inspect(g1)} reason=:kill " <>
          "ts=#{System.monotonic_time()}"
      )

      Process.exit(g1, :kill)

      receive do
        {:DOWN, ^g1_ref, :process, ^g1, reason} ->
          IO.puts(
            "DOWN round=#{round} seq=1 cid=#{cid} pid=#{inspect(g1)} reason=#{inspect(reason)} " <>
              "ts=#{System.monotonic_time()}"
          )
      after
        5_000 -> flunk("g1 down timeout")
      end

      snap("after_g1_down_callers_blocked", round, cid, g1)
      Process.sleep(20)
      {ds_pre, reg_pre, kids_pre, state_pre} = snap("pre_release_20ms", round, cid, g1)
      pre = one_pid(reg_pre, kids_pre)

      IO.puts(
        "PRE_RELEASE round=#{round} cid=#{cid} pid=#{inspect(pre)} prior_alive=#{Process.alive?(g1)} " <>
          "supervisor=#{inspect(@ds)} ds=#{inspect(ds_pre)} restart=#{inspect(restart)} " <>
          "state=#{inspect(state_pre, limit: :infinity)} ts=#{System.monotonic_time()}"
      )

      Enum.each(tasks, fn task -> send(task.pid, {:go, cid}) end)
      IO.puts("CALLERS_RELEASED round=#{round} ts=#{System.monotonic_time()}")
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      pids =
        results
        |> Enum.map(fn
          {_i, _caller, {:ok, pid}} -> pid
          other -> flunk("bad ensure result #{inspect(other)}")
        end)
        |> Enum.uniq()

      assert length(pids) == 1
      [g2] = pids
      {ds2, reg2, kids2, state2} = snap("after_release", round, cid, g1)

      path =
        if pre == g2,
          do: "supervisor_auto_restart_before_release",
          else: "explicit_ensure_after_release"

      IO.puts(
        "GEN round=#{round} seq=2 cid=#{cid} pid=#{inspect(g2)} path=#{path} " <>
          "prior_alive=#{Process.alive?(g1)} supervisor=#{inspect(@ds)} " <>
          "ds_before=#{inspect(ds1)} ds_after=#{inspect(ds2)} restart=#{inspect(restart)} " <>
          "registry=#{inspect(reg2)} kids=#{inspect(kids2)} " <>
          "state=#{inspect(state2, limit: :infinity)} ts=#{System.monotonic_time()}"
      )

      receive do
        {:DOWN, ^ds_ref, :process, ^ds1, reason} ->
          IO.puts(
            "DS_DOWN round=#{round} pid=#{inspect(ds1)} reason=#{inspect(reason)} " <>
              "replacement=#{inspect(Process.whereis(@ds))} ts=#{System.monotonic_time()}"
          )
      after
        0 ->
          IO.puts(
            "DS_STABLE round=#{round} pid=#{inspect(ds1)} current=#{inspect(Process.whereis(@ds))} " <>
              "ts=#{System.monotonic_time()}"
          )
      end

      g2_ref = Process.monitor(g2)
      :ok = DynamicSupervisor.terminate_child(Process.whereis(@ds), g2)

      receive do
        {:DOWN, ^g2_ref, :process, ^g2, reason} ->
          IO.puts(
            "G2_TERMINATED round=#{round} cid=#{cid} pid=#{inspect(g2)} reason=#{inspect(reason)} " <>
              "ts=#{System.monotonic_time()}"
          )
      after
        5_000 -> flunk("g2 down timeout")
      end

      Process.sleep(10)
      snap("round_end", round, cid, g2)
    end
  end

  defp snap(label, round, cid, prior) do
    ds = Process.whereis(@ds)
    reg = Registry.lookup(@reg, "conversation:#{cid}")
    kids = safe_kids(ds, cid)
    state = safe_state(ds)
    durable = Repo.get!(Conversation, cid).conversation_status

    IO.puts(
      "SNAP label=#{label} round=#{round} cid=#{cid} durable=#{inspect(durable)} " <>
        "prior=#{inspect(prior)} prior_alive=#{if is_pid(prior), do: Process.alive?(prior), else: nil} " <>
        "supervisor=#{inspect(@ds)} ds=#{inspect(ds)} registry=#{inspect(reg)} " <>
        "kids=#{inspect(kids)} state=#{inspect(state, limit: :infinity)} ts=#{System.monotonic_time()}"
    )

    {ds, reg, kids, state}
  end

  defp safe_kids(nil, _cid), do: :unavailable

  defp safe_kids(ds, cid) do
    try do
      registered =
        Registry.lookup(@reg, "conversation:#{cid}")
        |> Enum.map(&elem(&1, 0))

      DynamicSupervisor.which_children(ds)
      |> Enum.flat_map(fn {_, pid, _, modules} ->
        if is_pid(pid) and pid in registered, do: [{pid, modules}], else: []
      end)
    catch
      :exit, reason -> {:unavailable, reason}
    end
  end

  defp safe_state(nil), do: :unavailable

  defp safe_state(ds) do
    try do
      :sys.get_state(ds)
    catch
      :exit, reason -> {:unavailable, reason}
    end
  end

  defp one_pid(reg, kids) when is_list(reg) and is_list(kids) do
    case Enum.uniq(Enum.map(reg, &elem(&1, 0)) ++ Enum.map(kids, &elem(&1, 0))) do
      [pid] -> pid
      _ -> nil
    end
  end

  defp one_pid(_, _), do: nil

  defp effective_restart(conversation_id) do
    case System.get_env("TRACE_LANE") do
      "temporary" -> :temporary
      _ -> ConversationServer.child_spec(%{conversation_id: conversation_id}).restart
    end
  end

  defp conversation_fixture do
    {:ok, a} = StrangertalksNew.Participants.create_participant(%{})
    {:ok, b} = StrangertalksNew.Participants.create_participant(%{})
    now = DateTime.utc_now()

    {:ok, matching} =
      StrangertalksNew.Matches.create_match(%{
        created_at: now,
        door_type: :JUST_TALK,
        match_status: :CREATED,
        match_strategy: :COMPATIBILITY,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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
        match_id: matching.match_id,
        participant_a_id: a.participant_id,
        participant_b_id: b.participant_id,
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

    %{conversation: conversation, a: a.participant_id, b: b.participant_id}
  end
end
