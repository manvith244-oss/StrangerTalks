defmodule StrangertalksNew.Evaluation.PreflightTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.Evaluation.{Config, Preflight}

  test "single pre-flight gate passes with frozen configuration and valid inventory" do
    assert {:pass, manifest} = Preflight.run()
    assert manifest.preflight_state == "PASS"
    assert manifest.live_terra_requests == 0
    assert manifest.provider_state == "WAITING_ON_AUTHORIZED_TERRA_EXECUTION_SURFACE"
    assert manifest.corpus_counts["ml_core"] == 104
    assert manifest.corpus_counts["ctx"] == 24
    assert manifest.corpus_counts["safety_collision"] == 3
    assert manifest.config.requested_model == "gpt-5.6-terra"
  end

  test "pre-flight gate fails if configuration is incompatible" do
    bad_config = %{Config.frozen_config() | temperature: 0.7}
    assert {:fail, reason} = Preflight.run(config: bad_config)
    assert reason =~ "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY"
  end

  test "pre-flight gate fails if forbidden tools or retrieval are enabled" do
    bad_config = %{Config.frozen_config() | web: true}
    assert {:fail, reason} = Preflight.run(config: bad_config)
    assert reason =~ "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY"
  end
end
