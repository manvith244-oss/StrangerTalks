defmodule StrangertalksNew.T02GenerationTimelineProbeTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.ConversationLifecycle.ConversationServer
  alias StrangertalksNew.Conversations.Conversation
  alias StrangertalksNew.Repo

  @ds StrangertalksNew.ConversationDynamicSupervisor
  @reg StrangertalksNew.ConversationRegistry
  @parallel 32
  @rounds 8

  test "proof-only ConversationServer generation timeline" do
    IO.puts("TRACE lane=#{System.get_env("TRACE_LANE")} parallel=#{@parallel} rounds=#{@rounds}")

    for round <- 1..@rounds do
      conversation = conversation_fixture(%{status: "PENDING"})
      cid = conversation.id

      snap("before_initial", round, cid, nil)
      {:ok, g1} = ConversationServer.ensure_started(cid)
      ds1 = Process.whereis(@ds)
      ds_ref = Process.monitor(ds1)
      g1_ref = Process.monitor(g1)
      Process.sleep(5)
      snap("after_initial", round, cid, g1)
      IO.puts("GEN round=#{round} seq=1 pid=#{inspect(g1)} path=explicit_ensure_started ds=#{inspect(ds1)} ts=#{System.monotonic_time()}")

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

      IO.puts("KILL round=#{round} pid=#{inspect(g1)} reason=:kill ts=#{System.monotonic_time()}")
      Process.exit(g1, :kill)
      receive do
        {:DOWN, ^g1_ref, :process, ^g1, reason} ->
          IO.puts("DOWN round=#{round} seq=1 pid=#{inspect(g1)} reason=#{inspect(reason)} ts=#{System.monotonic_time()}")
      after
        5_000 -> flunk("g1 down timeout")
      end

      snap("after_g1_down_callers_blocked", round, cid, g1)
      Process.sleep(20)
      {ds_pre, reg_pre, kids_pre, state_pre} = snap("pre_release_20ms", round, cid, g1)
      pre = one_pid(reg_pre, kids_pre)
      IO.puts("PRE_RELEASE round=#{round} pid=#{inspect(pre)} prior_alive=#{Process.alive?(g1)} ds=#{inspect(ds_pre)} state=#{inspect(state_pre, limit: :infinity)} ts=#{System.monotonic_time()}")

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
      path = if pre == g2, do: "supervisor_auto_restart_before_release", else: "explicit_ensure_after_release"
      IO.puts("GEN round=#{round} seq=2 pid=#{inspect(g2)} path=#{path} prior_alive=#{Process.alive?(g1)} ds_before=#{inspect(ds1)} ds_after=#{inspect(ds2)} registry=#{inspect(reg2)} kids=#{inspect(kids2)} state=#{inspect(state2, limit: :infinity)} ts=#{System.monotonic_time()}")

      receive do
        {:DOWN, ^ds_ref, :process, ^ds1, reason} ->
          IO.puts("DS_DOWN round=#{round} pid=#{inspect(ds1)} reason=#{inspect(reason)} replacement=#{inspect(Process.whereis(@ds))} ts=#{System.monotonic_time()}")
      after
        0 ->
          IO.puts("DS_STABLE round=#{round} pid=#{inspect(ds1)} current=#{inspect(Process.whereis(@ds))} ts=#{System.monotonic_time()}")
      end

      g2_ref = Process.monitor(g2)
      :ok = DynamicSupervisor.terminate_child(Process.whereis(@ds), g2)
      receive do
        {:DOWN, ^g2_ref, :process, ^g2, reason} ->
          IO.puts("G2_TERMINATED round=#{round} pid=#{inspect(g2)} reason=#{inspect(reason)} ts=#{System.monotonic_time()}")
      after
        5_000 -> flunk("g2 down timeout")
      end

      Process.sleep(10)
      snap("round_end", round, cid, g2)
    end
  end

  defp snap(label, round, cid, prior) do
    ds = Process.whereis(@ds)
    reg = Registry.lookup(@reg, {:conversation, cid})
    kids = safe_kids(ds, cid)
    state = safe_state(ds)
    status = Repo.get!(Conversation, cid).status

    IO.puts(
      "SNAP label=#{label} round=#{round} cid=#{cid} status=#{inspect(status)} prior=#{inspect(prior)} " <>
        "prior_alive=#{if is_pid(prior), do: Process.alive?(prior), else: nil} ds=#{inspect(ds)} " <>
        "registry=#{inspect(reg)} kids=#{inspect(kids)} state=#{inspect(state, limit: :infinity)} ts=#{System.monotonic_time()}"
    )

    {ds, reg, kids, state}
  end

  defp safe_kids(nil, _cid), do: :unavailable
  defp safe_kids(ds, cid) do
    try do
      registered = Registry.lookup(@reg, {:conversation, cid}) |> Enum.map(&elem(&1, 0))
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
end
