alias StrangertalksNew.WT02ContextRecorder
alias StrangertalksNew.WT02ContextRecorderTargetGate
alias StrangertalksNew.WT02ContextRecorderTargetGate.InvalidObservationError

defmodule WT02R11AR4Harness do
  alias StrangertalksNew.WT02ContextRecorder

  def artifact_path do
    Path.join(
      System.tmp_dir!(),
      "wt02-r11a-r4-green-#{System.unique_integer([:positive])}.json"
    )
  end

  def valid_context do
    t1 = {:ok, %{status: "matched", conversation_id: "synthetic-c1", caller: "t1"}}
    t2 = {:ok, %{status: "matched", conversation_id: "synthetic-c1", caller: "t2"}}

    %{
      pre_reset: %{
        monotonic: 101,
        queue_state: %{entry_count: 0, synthetic: true}
      },
      after_setup: %{
        queue_state_entry_count: 0,
        queue_state_expected_empty: true
      },
      results: [t1, t2],
      post_race: %{
        synthetic: true,
        durable: %{matches: 1, conversations: 1, reservations: 2}
      },
      observation_error: nil
    }
  end

  def target do
    %{
      module: StrangertalksNew.RelationshipReconnectionsTest,
      name:
        :"concurrent second-intent attempts still create one Match and one Conversation synthetic green",
      tags: %{async: false},
      state: nil,
      time: 17
    }
  end

  def predecessor_test do
    %{
      module: StrangertalksNew.WT02SyntheticPredecessor,
      name: :synthetic_predecessor,
      tags: %{async: false},
      state: nil,
      time: 3
    }
  end

  def predecessor_module do
    %{
      name: StrangertalksNew.WT02SyntheticPredecessor,
      tests: [predecessor_test()]
    }
  end

  def wait_until(predicate, description) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_until(predicate, description, deadline)
  end

  defp do_wait_until(predicate, description, deadline) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "timeout waiting for #{description}"

      true ->
        Process.sleep(10)
        do_wait_until(predicate, description, deadline)
    end
  end

  def start_formatter! do
    {:ok, formatter_pid} = GenServer.start_link(WT02ContextRecorder, [max_cases: 1])
    recorder_pid = Process.whereis(WT02ContextRecorder)

    if is_nil(recorder_pid) or recorder_pid == formatter_pid do
      raise "dedicated recorder authority did not start"
    end

    {formatter_pid, recorder_pid}
  end

  def shutdown!(formatter_pid, label) do
    if Process.whereis(WT02ContextRecorder) do
      GenServer.cast(formatter_pid, {:suite_finished, %{run: label}})
      wait_until(fn -> Process.whereis(WT02ContextRecorder) == nil end, "#{label} recorder shutdown")
    end

    if Process.alive?(formatter_pid), do: GenServer.stop(formatter_pid, :normal)
    :ok
  end

  def classify!(artifact, context) do
    File.rm(artifact)
    {formatter_pid, _recorder_pid} = start_formatter!()
    :ok = WT02ContextRecorder.record_context(context)
    GenServer.cast(formatter_pid, {:test_started, target()})
    GenServer.cast(formatter_pid, {:test_finished, target()})
    wait_until(fn -> File.exists?(artifact) end, "synthetic GREEN artifact")
    data = artifact |> File.read!() |> Jason.decode!()
    shutdown!(formatter_pid, :classification)
    data
  end

  def assert_invalid!(data, description) do
    classification = data["classification"]

    unless classification["observation_valid"] == false and
             classification["target_contract_satisfied"] == false and
             classification["existing_error_class"] == "INVALID_OBSERVATION" do
      raise "#{description} was not classified INVALID_OBSERVATION: #{inspect(classification)}"
    end

    :ok
  end
end

artifact = WT02R11AR4Harness.artifact_path()
File.rm(artifact)
System.put_env("WT02_ARTIFACT", artifact)
System.put_env("WT02_TEAM6_SHA", "ac867b346426c782b90031b3d770a0d294761065")
System.put_env("WT02_SEED", "synthetic-observation-truth-green")
System.put_env("WT02_POSTGRES_VERSION", "NOT_USED")

valid_context = WT02R11AR4Harness.valid_context()
[t1, t2] = valid_context.results

complete = WT02R11AR4Harness.classify!(artifact, valid_context)
classification = complete["classification"]

unless classification["observation_valid"] == true and
         classification["target_contract_satisfied"] == true and
         classification["existing_error_class"] == "NONE" do
  raise "complete valid observation did not pass: #{inspect(classification)}"
end

IO.puts("ARTIFACT_ASSEMBLY=PASS")

missing_pre = WT02R11AR4Harness.classify!(artifact, %{valid_context | pre_reset: nil})
WT02R11AR4Harness.assert_invalid!(missing_pre, "missing PRE_RESET")
IO.puts("MISSING_PRE_RESET_CANNOT_PASS=PASS")

missing_after = WT02R11AR4Harness.classify!(artifact, %{valid_context | after_setup: nil})
WT02R11AR4Harness.assert_invalid!(missing_after, "missing AFTER_SETUP")
IO.puts("MISSING_AFTER_SETUP_CANNOT_PASS=PASS")

missing_t1 = WT02R11AR4Harness.classify!(artifact, %{valid_context | results: [t2]})
WT02R11AR4Harness.assert_invalid!(missing_t1, "missing T1")
IO.puts("MISSING_T1_CANNOT_PASS=PASS")

missing_t2 = WT02R11AR4Harness.classify!(artifact, %{valid_context | results: [t1]})
WT02R11AR4Harness.assert_invalid!(missing_t2, "missing T2")
IO.puts("MISSING_T2_CANNOT_PASS=PASS")
IO.puts("MISSING_RESULT_CANNOT_PASS=PASS")

missing_post = WT02R11AR4Harness.classify!(artifact, %{valid_context | post_race: nil})
WT02R11AR4Harness.assert_invalid!(missing_post, "missing POST_RACE")
IO.puts("MISSING_POST_RACE_CANNOT_PASS=PASS")

observer_error =
  WT02R11AR4Harness.classify!(artifact, %{
    valid_context
    | observation_error: "SyntheticObserverError"
  })

WT02R11AR4Harness.assert_invalid!(observer_error, "observer error")
IO.puts("OBSERVER_ERROR_CANNOT_PASS=PASS")
IO.puts("INVALID_OBSERVATION_CANNOT_PASS=PASS")

{formatter_1, recorder_1} = WT02R11AR4Harness.start_formatter!()
generation_1 = Map.put(valid_context, :synthetic_generation, 1)
:ok = WT02ContextRecorder.record_context(generation_1)
GenServer.cast(formatter_1, {:test_finished, WT02R11AR4Harness.predecessor_test()})
GenServer.cast(formatter_1, {:module_finished, WT02R11AR4Harness.predecessor_module()})

WT02R11AR4Harness.wait_until(
  fn ->
    state = :sys.get_state(recorder_1)
    length(state.tests) == 1 and length(state.modules) == 1
  end,
  "generation 1 predecessor history"
)

state_1 = :sys.get_state(recorder_1)

unless state_1.context[:synthetic_generation] == 1 and length(state_1.tests) == 1 and
         length(state_1.modules) == 1 do
  raise "generation 1 synthetic state was not established"
end

case GenServer.start(WT02ContextRecorder, [max_cases: 1]) do
  {:error, {:stale_recorder, ^recorder_1}} -> :ok
  other -> raise "duplicate formatter did not reject stale recorder: #{inspect(other)}"
end

state_after_rejection = :sys.get_state(recorder_1)

unless Process.whereis(WT02ContextRecorder) == recorder_1 and
         state_after_rejection.context[:synthetic_generation] == 1 and
         length(state_after_rejection.tests) == 1 and
         length(state_after_rejection.modules) == 1 do
  raise "stale recorder rejection mutated generation 1 state unexpectedly"
end

IO.puts("STALE_RECORDER_STATE_REJECTED=PASS")

WT02R11AR4Harness.shutdown!(formatter_1, :generation_1)

{formatter_2, recorder_2} = WT02R11AR4Harness.start_formatter!()
state_2_fresh = :sys.get_state(recorder_2)

unless recorder_2 != recorder_1 and state_2_fresh.context == nil and state_2_fresh.tests == [] and
         state_2_fresh.modules == [] do
  raise "fresh generation inherited stale recorder state: #{inspect(state_2_fresh)}"
end

generation_2 = Map.put(valid_context, :synthetic_generation, 2)
:ok = WT02ContextRecorder.record_context(generation_2)
state_2_recorded = :sys.get_state(recorder_2)

unless state_2_recorded.context[:synthetic_generation] == 2 do
  raise "fresh generation did not accept its own context"
end

IO.puts("FRESH_GENERATION_STATE=PASS")
WT02R11AR4Harness.shutdown!(formatter_2, :generation_2)
IO.puts("RECORDER_SHUTDOWN=PASS")

handoff = WT02ContextRecorder.record_context(valid_context)

unless match?({:error, {:recorder_unavailable, _}}, handoff) do
  raise "synthetic recorder-unavailable condition was not established: #{inspect(handoff)}"
end

Process.delete(:wt02_product_assertions_executed)

diagnostic_error =
  try do
    WT02ContextRecorderTargetGate.after_product_assertions!(handoff, fn ->
      Process.put(:wt02_product_assertions_executed, true)
      :native_product_pass
    end)

    :no_error
  rescue
    error in InvalidObservationError -> error
  end

unless Process.get(:wt02_product_assertions_executed) == true do
  raise "product-like assertions did not execute before recorder failure gating"
end

unless match?(%InvalidObservationError{}, diagnostic_error) and
         diagnostic_error.diagnostic_result == handoff do
  raise "recorder failure was not surfaced as explicit diagnostic invalidity"
end

IO.puts("PRODUCT_ASSERTIONS_SURVIVE_RECORDER_FAILURE=PASS")
IO.puts("RECORDER_UNAVAILABLE_NOT_SILENT=PASS")

native_product_error =
  try do
    WT02ContextRecorderTargetGate.after_product_assertions!(handoff, fn ->
      raise "synthetic native product failure"
    end)

    :no_error
  rescue
    error in RuntimeError -> error
  end

unless match?(%RuntimeError{message: "synthetic native product failure"}, native_product_error) do
  raise "native product failure was reclassified by the diagnostic gate"
end

IO.puts("PRODUCT_FAILURE_REMAINS_NATIVE=PASS")

{formatter_3, _recorder_3} = WT02R11AR4Harness.start_formatter!()
:ok = WT02ContextRecorder.record_context(valid_context)

:native_product_pass =
  WT02ContextRecorderTargetGate.after_product_assertions!(:ok, fn -> :native_product_pass end)

IO.puts("DIAGNOSTIC_HANDOFF_ACCEPTED=PASS")
WT02R11AR4Harness.shutdown!(formatter_3, :available_handoff)

source = File.read!("test/support/wt02_context_recorder.ex")

unless String.contains?(source, "Ecto.UUID.dump!(f.a)") and
         String.contains?(source, "Ecto.UUID.dump!(f.b)") do
  raise "UUID dump repair regressed"
end

IO.puts("UUID_REPAIR_PRESERVED=PASS")
IO.puts("SYNTHETIC_OBSERVATION_TRUTH_GREEN=PASS")
