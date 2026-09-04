defmodule StrangertalksNew.AgentSecurityGateContractTest do
  use ExUnit.Case, async: true

  @workflow_path ".github/workflows/a01-conversation-companion.yml"

  setup_all do
    {:ok, workflow: File.read!(@workflow_path)}
  end

  test "Agent Systems closure gate follows current canonical and release authority", %{workflow: workflow} do
    assert workflow =~ "name: Agent Systems Closure Gate"
    assert workflow =~ "pull_request:\n    branches:\n      - main\n      - release/prep-2026-08-22"
    assert workflow =~ "push:\n    branches:\n      - main\n      - release/prep-2026-08-22"
    assert workflow =~ "workflow_dispatch:"
    refute workflow =~ "feature/a01-conversation-companion"
    refute workflow =~ "release/integration-2026-08-28"
  end

  test "Agent Systems closure gate preserves exact-head and least-privilege proof", %{workflow: workflow} do
    assert workflow =~ "permissions:\n  contents: read"
    assert workflow =~ "ref: ${{ github.event.pull_request.head.sha || github.sha }}"
    assert workflow =~
             "test \"$(git rev-parse HEAD)\" = \"${{ github.event.pull_request.head.sha || github.sha }}\""

    assert workflow =~ "git diff --exit-code -- ."
  end

  test "Agent Systems closure gate carries the current security and dependency proof surface", %{
    workflow: workflow
  } do
    for required <- [
          "test/strangertalks_new/agent_systems_remediation_test.exs",
          "test/strangertalks_new/intelligence_v1_hostile_test.exs",
          "test/strangertalks_new/privacy_persistence_guard_test.exs",
          "test/strangertalks_new/ai_service/boundary_contract_test.exs",
          "python -m pytest services/ai/tests -q -ra",
          "mix hex.audit",
          "mix precommit",
          "test/js/companion_test.mjs",
          "test/js/prompt_cards_test.mjs"
        ] do
      assert workflow =~ required
    end
  end
end
