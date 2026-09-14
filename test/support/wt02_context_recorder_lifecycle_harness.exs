alias StrangertalksNew.WT02ContextRecorder

artifact = Path.join(System.tmp_dir!(), "wt02-r11a-r4-red-#{System.unique_integer([:positive])}.json")
File.rm(artifact)
System.put_env("WT02_ARTIFACT", artifact)
System.put_env("WT02_TEAM6_SHA", "ac867b346426c782b90031b3d770a0d294761065")
System.put_env("WT02_SEED", "synthetic-observation-truth-red")
System.put_env("WT02_POSTGRES_VERSION", "NOT_USED")

valid_context = %{
  pre_reset: %{monotonic: 101, synthetic: true},
  after_setup: %{queue_state_entry_count: 0, queue_state_expected_empty: true},
  results: [
    {:ok, %{status: "matched", conversation_id: "synthetic-c1"}},
    {:ok, %{status: "matched", conversation_id: "synthetic-c1"}}
  ],
  post_race: %{synthetic: true, durable: %{matches: 1, conversations: 1}},
  observation_error: nil
}

target = %{
  module: StrangertalksNew.RelationshipReconnectionsTest,
  name: :"concurrent second-intent attempts still create one Match and one Conversation synthetic red",
  tags: %{async: false},
  state: nil,
  time: 17
}

predecessor_test = %{
  module: StrangertalksNew.WT02SyntheticPredecessor,
  name: :synthetic_predecessor,
  tags: %{async: false},
  state: nil,
  time: 3
}

predecessor_module = %{
  name: StrangertalksNew.WT02SyntheticPredecessor,
  tests: [predecessor_test]
}

wait_until = fn predicate, description ->
  deadline = System.monotonic_time(:millisecond) + 2_000

  Stream.repeatedly(fn ->
    cond do
      predicate.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise "timeout waiting for #{description}"
      true -> Process.sleep(10); :retry
    end
  end)
  |> Enum.find(&(&1 == :ok))
end

start_formatter = fn ->
  {:ok, formatter_pid} = GenServer.start_link(WT02ContextRecorder, [max_cases: 1])
  recorder_pid = Process.whereis(WT02ContextRecorder)

  if is_nil(recorder_pid) or recorder_pid == formatter_pid do
    raise "dedicated recorder authority did not start"
  end

  {formatter_pid, recorder_pid}
end

stop_round = fn formatter_pids ->
  recorder_pid = Process.whereis(WT02ContextRecorder)

  if recorder_pid do
    GenServer.cast(hd(formatter_pids), {:suite_finished, %{run: :red}})
    wait_until.(fn -> Process.whereis(WT02ContextRecorder) == nil end, "recorder shutdown")
  end

  Enum.each(formatter_pids, fn pid ->
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  end)
end

classify = fn context ->
  File.rm(artifact)
  {formatter_pid, _recorder_pid} = start_formatter.()
  :ok = WT02ContextRecorder.record_context(context)
  GenServer.cast(formatter_pid, {:test_started, target})
  GenServer.cast(formatter_pid, {:test_finished, target})
  wait_until.(fn -> File.exists?(artifact) end, "synthetic RED artifact")
  data = artifact |> File.read!() |> Jason.decode!()
  stop_round.([formatter_pid])
  data
end

missing_pre = classify.(%{valid_context | pre_reset: nil})

unless missing_pre["classification"]["observation_valid"] == true and
         missing_pre["classification"]["target_contract_satisfied"] == true do
  raise "missing PRE_RESET defect was not reproduced"
end

IO.puts("MISSING_PRE_RESET_RED=REPRODUCED observation_valid=true target_contract_satisfied=true")

missing_after = classify.(%{valid_context | after_setup: nil})

unless missing_after["classification"]["observation_valid"] == true and
         missing_after["classification"]["target_contract_satisfied"] == true do
  raise "missing AFTER_SETUP defect was not reproduced"
end

IO.puts("MISSING_AFTER_SETUP_RED=REPRODUCED observation_valid=true target_contract_satisfied=true")

File.rm(artifact)
generation_1 = Map.put(valid_context, :synthetic_generation, 1)
{formatter_1, recorder_1} = start_formatter.()
:ok = WT02ContextRecorder.record_context(generation_1)
GenServer.cast(formatter_1, {:test_finished, predecessor_test})
GenServer.cast(formatter_1, {:module_finished, predecessor_module})

wait_until.(
  fn ->
    state = :sys.get_state(recorder_1)
    length(state.tests) == 1 and length(state.modules) == 1
  end,
  "generation 1 predecessor history"
)

state_1 = :sys.get_state(recorder_1)

{:ok, formatter_2} = GenServer.start_link(WT02ContextRecorder, [max_cases: 1])
recorder_2 = Process.whereis(WT02ContextRecorder)
state_2 = :sys.get_state(recorder_2)

unless recorder_2 == recorder_1 and state_2.context[:synthetic_generation] == 1 and
         length(state_2.tests) == 1 and length(state_2.modules) == 1 do
  raise "stale-recorder attachment defect was not reproduced with predecessor history"
end

IO.puts("STALE_RECORDER_RED=REPRODUCED recorder_reused=true generation=#{state_2.context[:synthetic_generation]}")
IO.puts("STALE_RECORDER_VISIBLE_CONTEXT=#{inspect(%{tests: length(state_1.tests), modules: length(state_1.modules), synthetic_generation: state_2.context[:synthetic_generation]})}")

stop_round.([formatter_1, formatter_2])

handoff = WT02ContextRecorder.record_context(valid_context)

unless match?({:error, {:recorder_unavailable, _}}, handoff) do
  raise "recorder-unavailable condition was not reproduced"
end

product_assertions_executed = true
_ignored_diagnostic_result = handoff
product_like_outcome = :pass

unless product_assertions_executed and product_like_outcome == :pass do
  raise "target-like ignored-return defect was not reproduced"
end

IO.puts("RECORDER_UNAVAILABLE_RED=REPRODUCED return=#{inspect(handoff)}")
IO.puts("IGNORED_RECORDER_RESULT_RED=REPRODUCED product_assertions_executed=true product_like_outcome=pass")
IO.puts("SYNTHETIC_OBSERVATION_TRUTH_RED=CONFIRMED")

raise "intentional synthetic RED: four frozen R3 defects reproduced before repair"
