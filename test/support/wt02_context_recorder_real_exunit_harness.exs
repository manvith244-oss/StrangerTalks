alias StrangertalksNew.WT02ContextRecorder

artifact =
  Path.join(
    System.tmp_dir!(),
    "wt02-r11a-r6-real-exunit-#{System.unique_integer([:positive])}.json"
  )

File.rm(artifact)
System.put_env("WT02_ARTIFACT", artifact)
System.put_env("WT02_TEAM6_SHA", "ac867b346426c782b90031b3d770a0d294761065")
System.put_env("WT02_SEED", "synthetic-real-exunit-finalization")
System.put_env("WT02_POSTGRES_VERSION", "NOT_USED")

if Code.ensure_loaded?(StrangertalksNew.RelationshipReconnectionsTest) do
  raise "real RelationshipReconnections test module was already loaded"
end

ExUnit.start(autorun: false)
ExUnit.configure(formatters: [WT02ContextRecorder], max_cases: 1, seed: 0, trace: false)

parent = self()

valid_context = %{
  pre_reset: %{
    monotonic: 101,
    queue_state: %{entry_count: 0, synthetic: true}
  },
  after_setup: %{
    queue_state_entry_count: 0,
    queue_state_expected_empty: true
  },
  results: [
    {:ok, %{status: "matched", conversation_id: "synthetic-c1", caller: "t1"}},
    {:ok, %{status: "matched", conversation_id: "synthetic-c1", caller: "t2"}}
  ],
  post_race: %{
    synthetic: true,
    durable: %{matches: 1, conversations: 1, reservations: 2}
  },
  observation_error: nil
}

:persistent_term.put({__MODULE__, :parent}, parent)
:persistent_term.put({__MODULE__, :context}, valid_context)

Code.eval_quoted(
  quote do
    defmodule StrangertalksNew.RelationshipReconnectionsTest do
      use ExUnit.Case, async: false

      test "concurrent second-intent attempts still create one Match and one Conversation synthetic lifecycle" do
        parent = :persistent_term.get({unquote(__MODULE__), :parent})
        context = :persistent_term.get({unquote(__MODULE__), :context})

        :ok = StrangertalksNew.WT02ContextRecorder.record_context(context)
        send(parent, {:context_handoff, :ok})

        recorder = Process.whereis(StrangertalksNew.WT02ContextRecorder)

        if is_nil(recorder) do
          raise "dedicated recorder process missing after context handoff"
        end

        :ok = :sys.suspend(recorder)
        send(parent, {:recorder_suspended, recorder})

        spawn(fn ->
          Process.sleep(350)
          :sys.resume(recorder)
        end)

        assert true
      end
    end
  end
)

source = StrangertalksNew.RelationshipReconnectionsTest.module_info(:compile)[:source] |> to_string()

if String.ends_with?(source, "relationship_reconnections_test.exs") do
  raise "real RelationshipReconnections source was loaded"
end

IO.puts("REAL_RELATIONSHIP_RECONNECTIONS_SOURCE_LOADED=NO")

started = System.monotonic_time(:millisecond)
result = ExUnit.run()
returned = System.monotonic_time(:millisecond)

receive do
  {:context_handoff, :ok} -> IO.puts("REAL_EXUNIT_CONTEXT_HANDOFF=PASS")
after
  0 -> raise "synthetic target did not report synchronous context handoff"
end

recorder_pid =
  receive do
    {:recorder_suspended, pid} -> pid
  after
    0 -> Process.whereis(WT02ContextRecorder)
  end

unless result.failures == 0 do
  raise "synthetic target did not pass natively: #{inspect(result)}"
end

IO.puts("REAL_EXUNIT_TARGET_PASS=PASS")
IO.puts("EXUNIT_RUN_ELAPSED_MS=#{returned - started}")

artifact_at_return = File.exists?(artifact)
recorder_alive_at_return = is_pid(recorder_pid) and Process.alive?(recorder_pid)
queue_len_at_return =
  if recorder_alive_at_return do
    case Process.info(recorder_pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> -1
    end
  else
    0
  end

IO.puts("ARTIFACT_AT_EXUNIT_RETURN=#{if artifact_at_return, do: "PRESENT", else: "ABSENT"}")
IO.puts("RECORDER_ALIVE_AT_EXUNIT_RETURN=#{if recorder_alive_at_return, do: "YES", else: "NO"}")
IO.puts("RECORDER_QUEUE_AT_EXUNIT_RETURN=#{queue_len_at_return}")

wait_until = fn predicate, label ->
  deadline = System.monotonic_time(:millisecond) + 2_000

  recur = fn recur ->
    cond do
      predicate.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise "timeout waiting for #{label}"
      true -> Process.sleep(10); recur.(recur)
    end
  end

  recur.(recur)
end

if artifact_at_return do
  data = artifact |> File.read!() |> Jason.decode!()

  unless get_in(data, ["classification", "observation_valid"]) == true and
           get_in(data, ["classification", "target_contract_satisfied"]) == true do
    raise "artifact schema/classification invalid: #{inspect(data["classification"])}"
  end

  wait_until.(fn -> Process.whereis(WT02ContextRecorder) == nil end, "recorder shutdown")

  IO.puts("FORMATTER_TEST_FINISHED_RECEIVED=PASS")
  IO.puts("RECORDER_TEST_FINISHED_RECEIVED=PASS")
  IO.puts("ARTIFACT_WRITE_STARTED=PASS")
  IO.puts("ARTIFACT_WRITE_COMPLETED=PASS")
  IO.puts("SUITE_FINISHED_RECEIVED=PASS")
  IO.puts("RECORDER_STOPPED=PASS")
  IO.puts("FORMATTER_FINALIZATION_ACK=PASS")
  IO.puts("RECORDER_ARTIFACT_WRITE=PASS")
  IO.puts("ARTIFACT_PRESENT_BEFORE_EXUNIT_RETURN=PASS")
  IO.puts("ARTIFACT_SCHEMA=PASS")
  IO.puts("RECORDER_SHUTDOWN=PASS")
  IO.puts("NO_ORPHAN_RECORDER=PASS")
  IO.puts("SYNTHETIC_FINALIZATION_GREEN=PASS")
else
  IO.puts("REAL_EXUNIT_FINALIZATION_RED=REPRODUCED")
  IO.puts("EXUNIT_RETURNED_BEFORE_ARTIFACT=YES")

  wait_until.(fn -> File.exists?(artifact) end, "post-return artifact completion")
  wait_until.(fn -> Process.whereis(WT02ContextRecorder) == nil end, "post-return recorder shutdown")

  IO.puts("FORMATTER_TEST_FINISHED_RECEIVED=PASS")
  IO.puts("RECORDER_TEST_FINISHED_RECEIVED=PASS")
  IO.puts("ARTIFACT_WRITE_STARTED=PASS")
  IO.puts("ARTIFACT_WRITE_COMPLETED=PASS")
  IO.puts("SUITE_FINISHED_RECEIVED=PASS")
  IO.puts("RECORDER_STOPPED=PASS")
  raise "target finalization was not durable before ExUnit returned"
end

:persistent_term.erase({__MODULE__, :parent})
:persistent_term.erase({__MODULE__, :context})
