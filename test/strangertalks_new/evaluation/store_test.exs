defmodule StrangertalksNew.Evaluation.StoreTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Evaluation.Store

  @tmp_base_dir Path.expand("tmp/test_eval_store", File.cwd!())

  setup do
    File.rm_rf!(@tmp_base_dir)
    File.mkdir_p!(@tmp_base_dir)
    on_exit(fn -> File.rm_rf!(@tmp_base_dir) end)
    :ok
  end

  test "writes structured record and immutable raw output with preserved request/response IDs" do
    record = %{
      corpus: "ml_core",
      item_id: "ML-CORE-001",
      repeat_index: 1,
      condition: "C2",
      request_id: "req-12345",
      response_id: "resp-67890",
      output: "Sample response"
    }

    raw_payload = %{"text" => "Sample response", "tokens" => 42}

    assert {:ok, result} =
             Store.write_result(
               @tmp_base_dir,
               "run_001",
               "ml_core",
               "ML-CORE-001",
               1,
               "C2",
               record,
               raw_payload
             )

    assert File.exists?(result.record_path)
    assert File.exists?(result.raw_path)
    assert result.request_id == "req-12345"
    assert result.response_id == "resp-67890"

    saved_record = result.record_path |> File.read!() |> Jason.decode!()
    assert saved_record["request_id"] == "req-12345"
    assert saved_record["response_id"] == "resp-67890"
  end

  test "strictly prevents overwriting an existing result" do
    record = %{output: "First write"}

    assert {:ok, _} =
             Store.write_result(
               @tmp_base_dir,
               "run_002",
               "ml_core",
               "ML-CORE-002",
               1,
               "C2",
               record,
               %{}
             )

    # Attempt overwrite
    assert {:error, :result_already_exists} =
             Store.write_result(
               @tmp_base_dir,
               "run_002",
               "ml_core",
               "ML-CORE-002",
               1,
               "C2",
               %{output: "Second write"},
               %{}
             )
  end

  test "writes and reads per-run provenance manifest" do
    manifest_data = %{
      mode: "pilot",
      dry_run: true,
      live_terra_requests: 0,
      requested_model: "gpt-5.6-terra"
    }

    assert {:ok, manifest_path} = Store.write_manifest(@tmp_base_dir, "run_003", manifest_data)
    assert File.exists?(manifest_path)

    assert {:ok, read_data} = Store.read_manifest(@tmp_base_dir, "run_003")
    assert read_data["run_id"] == "run_003"
    assert read_data["manifest_version"] == "T-A13-V1"
    assert read_data["live_terra_requests"] == 0
  end

  test "retry creates a new distinct result identity" do
    record_initial = %{output: "Initial attempt", request_id: "req-1", response_id: "resp-1"}
    record_retry = %{output: "Retried attempt", request_id: "req-2", response_id: "resp-2"}

    # Initial attempt stored under repeat 1
    assert {:ok, res1} =
             Store.write_result(
               @tmp_base_dir,
               "run_004",
               "ml_core",
               "ML-CORE-003",
               1,
               "C2",
               record_initial,
               %{}
             )

    # Retry creates a new provenance record under repeat 2
    assert {:ok, res2} =
             Store.write_result(
               @tmp_base_dir,
               "run_004",
               "ml_core",
               "ML-CORE-003",
               2,
               "C2",
               record_retry,
               %{}
             )

    assert res1.record_path != res2.record_path
    assert res1.request_id != res2.request_id
    assert res1.response_id != res2.response_id
  end
end
