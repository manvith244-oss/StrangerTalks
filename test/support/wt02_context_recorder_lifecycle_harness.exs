alias StrangertalksNew.WT02ContextRecorder

artifact = Path.join(System.tmp_dir!(), "wt02-r11a-r2-recorder-lifecycle-#{System.unique_integer([:positive])}.json")
File.rm(artifact)
System.put_env("WT02_ARTIFACT", artifact)
System.put_env("WT02_TEAM6_SHA", "ac867b346426c782b90031b3d770a0d294761065")
System.put_env("WT02_SEED", "synthetic-lifecycle")
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

predecessor = %{
  module: StrangertalksNew.WT02SyntheticPredecessor,
  name: :synthetic_predecessor,
  tags: %{async: false},
  state: nil,
  time: 11
}

predecessor_module = %{
  name: StrangertalksNew.WT02SyntheticPredecessor,
  tests: [predecessor]
}

target = %{
  module: StrangertalksNew.RelationshipReconnectionsTest,
  name: :"concurrent second-intent attempts still create one Match and one Conversation synthetic lifecycle",
  tags: %{async: false},
  state: nil,
  time: 17
}

wait_until = fn predicate, description ->
  deadline = System.monotonic_time(:millisecond) + 2_000

  Stream.repeatedly(fn ->
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "timeout waiting for #{description}"
      end

      Process.sleep(10)
      :retry
    end
  end)
  |> Enum.find(&(&1 == :ok))
end

start_formatter = fn red_context ->
  {:ok, formatter_pid} = GenServer.start_link(WT02ContextRecorder, [max_cases: 1])
  IO.puts("FORMATTER_PID=#{inspect(formatter_pid)}")

  recorder_pid = Process.whereis(WT02ContextRecorder)

  if is_nil(recorder_pid) do
    IO.puts("NAMED_RECORDER=nil")

    try do
      GenServer.call(WT02ContextRecorder, {:context, red_context}, 1_000)
      raise "expected missing-recorder handoff to fail"
    catch
      :exit, reason ->
        IO.puts("RED_NO_PROCESS=#{inspect(reason)}")
        raise "synthetic RED: WT02ContextRecorder formatter is not registered as recorder"
    end
  end

  IO.puts("NAMED_RECORDER=#{inspect(recorder_pid)}")

  if recorder_pid == formatter_pid do
    raise "formatter pid must not be the dedicated recorder authority"
  end

  formatter_pid
end

read_artifact = fn ->
  wait_until.(fn -> File.exists?(artifact) end, "synthetic artifact")
  artifact |> File.read!() |> Jason.decode!()
end

stop_round = fn formatter_pid ->
  GenServer.cast(formatter_pid, {:suite_finished, %{run: 1}})
  wait_until.(fn -> Process.whereis(WT02ContextRecorder) == nil end, "recorder shutdown")
  GenServer.stop(formatter_pid, :normal)
end

unless function_exported?(WT02ContextRecorder, :record_context, 1) do
  raise "record_context/1 handoff authority is missing"
end

formatter_pid = start_formatter.(valid_context)
:ok = WT02ContextRecorder.record_context(valid_context)

GenServer.cast(formatter_pid, {:test_finished, predecessor})
GenServer.cast(formatter_pid, {:module_finished, predecessor_module})
GenServer.cast(formatter_pid, {:test_started, target})
GenServer.cast(formatter_pid, {:test_finished, target})

artifact_data = read_artifact.()

unless artifact_data["pre_reset"]["synthetic"] == true, do: raise("PRE_RESET not preserved")
unless artifact_data["after_setup"]["queue_state_expected_empty"] == true, do: raise("AFTER_SETUP not preserved")
unless artifact_data["post_race"]["synthetic"] == true, do: raise("POST_RACE not preserved")
unless artifact_data["target"]["t1_result"] != nil and artifact_data["target"]["t2_result"] != nil, do: raise("caller results not preserved")
unless length(artifact_data["predecessors"]["recent_tests"]) == 1, do: raise("formatter test history did not reach recorder")
unless length(artifact_data["predecessors"]["recent_modules"]) == 1, do: raise("formatter module history did not reach recorder")
unless artifact_data["classification"]["observation_valid"] == true, do: raise("synthetic observation unexpectedly invalid")
unless artifact_data["classification"]["target_contract_satisfied"] == true, do: raise("synthetic valid contract did not satisfy")

IO.puts("CONTEXT_HANDOFF=PASS")
IO.puts("FORMATTER_HISTORY=PASS")
IO.puts("ARTIFACT_ASSEMBLY=PASS")

stop_round.(formatter_pid)
IO.puts("RECORDER_SHUTDOWN=PASS")

case WT02ContextRecorder.record_context(valid_context) do
  {:error, {:recorder_unavailable, _reason}} ->
    IO.puts("OBSERVER_EFFECT_NONFATAL=PASS")

  other ->
    raise "expected explicit nonfatal recorder-unavailable result, got #{inspect(other)}"
end

File.rm(artifact)
missing_result_context = %{valid_context | results: [hd(valid_context.results)]}
formatter_pid = start_formatter.(missing_result_context)
:ok = WT02ContextRecorder.record_context(missing_result_context)
GenServer.cast(formatter_pid, {:test_started, target})
GenServer.cast(formatter_pid, {:test_finished, target})
missing_result_artifact = read_artifact.()

if missing_result_artifact["classification"]["observation_valid"] != false,
  do: raise("missing result unexpectedly valid")

if missing_result_artifact["classification"]["target_contract_satisfied"] != false,
  do: raise("missing result unexpectedly satisfied target contract")

IO.puts("MISSING_RESULT_CANNOT_PASS=PASS")
stop_round.(formatter_pid)

File.rm(artifact)
partial_context = %{
  valid_context
  | post_race: nil,
    observation_error: "Postgrex.Error"
}

formatter_pid = start_formatter.(partial_context)
:ok = WT02ContextRecorder.record_context(partial_context)
GenServer.cast(formatter_pid, {:test_started, target})
GenServer.cast(formatter_pid, {:test_finished, target})
partial_artifact = read_artifact.()

unless partial_artifact["pre_reset"]["synthetic"] == true, do: raise("partial PRE_RESET lost")
unless partial_artifact["after_setup"]["queue_state_expected_empty"] == true, do: raise("partial AFTER_SETUP lost")
unless is_nil(partial_artifact["post_race"]), do: raise("partial POST_RACE should be nil")

if partial_artifact["classification"]["observation_valid"] != false,
  do: raise("observation-error artifact unexpectedly valid")

if partial_artifact["classification"]["target_contract_satisfied"] != false,
  do: raise("invalid observation unexpectedly satisfied target contract")

IO.puts("INVALID_OBSERVATION_CANNOT_PASS=PASS")
IO.puts("PARTIAL_ARTIFACT_PRESERVED=PASS")
stop_round.(formatter_pid)

File.rm(artifact)
IO.puts("SYNTHETIC_LIFECYCLE_GREEN=PASS")
