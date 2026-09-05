defmodule StrangertalksNew.Evaluation.ExecutorTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Evaluation.{Config, Executor}

  @tmp_base_dir Path.expand("tmp/test_eval_exec", File.cwd!())

  setup do
    File.rm_rf!(@tmp_base_dir)
    File.mkdir_p!(@tmp_base_dir)
    on_exit(fn -> File.rm_rf!(@tmp_base_dir) end)
    :ok
  end

  test "dry-run pilot completes successfully and guarantees LIVE_TERRA_REQUESTS = 0" do
    opts = [
      base_dir: @tmp_base_dir,
      run_id: "pilot_test_001",
      dry_run: true
    ]

    assert {:ok, result} = Executor.run_pilot(opts)

    assert result.status == :completed
    assert result.live_terra_requests == 0
    assert result.manifest.live_terra_requests == 0
    assert result.manifest.requested_model == "gpt-5.6-terra"
    assert result.manifest.pairing_status == true
    assert result.written_records == 24
    assert result.manifest.pilot_inventory["primary_runs"] == 24
    assert File.exists?(result.manifest_path)
  end

  test "dry-run full run completes all 444 primary runs across frozen conditions with LIVE_TERRA_REQUESTS = 0" do
    opts = [
      base_dir: @tmp_base_dir,
      run_id: "full_test_001",
      dry_run: true
    ]

    assert {:ok, result} = Executor.run_full(opts)

    assert result.status == :completed
    assert result.live_terra_requests == 0
    assert result.manifest.live_terra_requests == 0
    assert result.manifest.full_inventory["FULL PRIMARY TOTAL"] == 444
    assert result.manifest.full_inventory["CORE C2"] == 234
    assert result.manifest.full_inventory["CTX C2"] == 72
    assert result.manifest.full_inventory["CTX C3"] == 72
    assert result.manifest.full_inventory["C4"] == 48
    assert result.manifest.full_inventory["SAFETY COLLISION"] == 18
    assert result.written_records == 444
  end

  test "refuses execution when pre-flight fails" do
    bad_config = %{Config.frozen_config() | temperature: 0.9}

    assert {:error, {:preflight_failed, reason}} =
             Executor.run_pilot(config: bad_config, base_dir: @tmp_base_dir)

    assert reason =~ "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY"
  end

  test "aborts immediately if provider returns a model discrepancy" do
    bad_provider = fn _model, condition, _item, _opts ->
      {:ok,
       %{
         request_id: "r1",
         response_id: "r2",
         model: "gpt-4o",
         condition: condition,
         output: "Unexpected model output",
         raw: %{"model" => "gpt-4o"}
       }}
    end

    opts = [
      base_dir: @tmp_base_dir,
      run_id: "discrepancy_run",
      provider_fn: bad_provider,
      dry_run: true
    ]

    assert {:ok, result} = Executor.run_pilot(opts)
    assert result.status == :stopped
    assert :model_identity_discrepancy in result.errors
  end

  test "preserves refusal, malformed output, truncation, and API failure without normalization" do
    sample_item = %{"id" => "TEST-01", "language" => "en", "corpus" => "ml_core"}

    # Refusal preservation
    {:ok, refusal_res} =
      StrangertalksNew.Evaluation.MockProvider.call("gpt-5.6-terra", "C2", sample_item,
        simulate: :refusal
      )

    assert refusal_res.refusal == true
    assert refusal_res.output =~ "cannot fulfill"

    # Malformed output preservation
    {:ok, malformed_res} =
      StrangertalksNew.Evaluation.MockProvider.call("gpt-5.6-terra", "C2", sample_item,
        simulate: :malformed
      )

    assert malformed_res.malformed_output == true
    assert malformed_res.output =~ "incomplete"

    # Truncation preservation
    {:ok, truncation_res} =
      StrangertalksNew.Evaluation.MockProvider.call("gpt-5.6-terra", "C2", sample_item,
        simulate: :truncation
      )

    assert truncation_res.truncation == true
    assert truncation_res.output_token_limit_event == true

    # API failure preservation
    {:error, api_err} =
      StrangertalksNew.Evaluation.MockProvider.call("gpt-5.6-terra", "C2", sample_item,
        simulate: :api_error
      )

    assert api_err.type == :api_error
    assert api_err.code == 500
  end
end
