defmodule StrangertalksNew.A02AuthorityReconciliationTest do
  use ExUnit.Case, async: true

  test "current A02 authority is deterministic while model-backed LearningAdvisor stays historical" do
    agent_task = File.read!("lib/mix/tasks/strangertalks.agents.ex")
    intelligence_task = File.read!("lib/mix/tasks/strangertalks.intelligence.ex")

    assert agent_task =~ ":learning_advisor_superseded_by_team8_v1"
    refute agent_task =~ "LearningAdvisor"

    assert intelligence_task =~ "V1Metrics.snapshot"
    assert intelligence_task =~ "V1Recommendations.analyze"
    refute intelligence_task =~ "LearningAdvisor"
    refute intelligence_task =~ "OpenAIProvider"
    refute intelligence_task =~ "AgentSystems.Provider"

    boundaries = File.read!("docs/AGENT_SYSTEMS_V1_BOUNDARIES.md")
    current_context = File.read!("docs/STRANGERTALKS_CURRENT_CONTEXT.md")
    team8 = File.read!("docs/TEAM8_INTELLIGENCE_V1.md")

    assert boundaries =~ "### A02 — Organizational Learning Advisor"
    assert boundaries =~ "`SUPERSEDED_FOR_CURRENT_V1`"
    assert boundaries =~ "StrangertalksNew.AgentSystems.LearningAdvisor"
    assert boundaries =~ "mix strangertalks.intelligence [hours]"
    assert boundaries =~ "Current V1 A02 organizational learning uses no model provider."

    operator_section =
      section(
        boundaries,
        "## Operational invocation",
        "## Deterministic authority retained from remediation"
      )

    assert operator_section =~ "Current operators use:"
    assert operator_section =~ "mix strangertalks.intelligence [hours]"

    assert operator_section =~
             "Historical/superseded reference: `mix strangertalks.agents learning [limit]`"

    refute operator_section =~
             "Current operators use:\n\n```text\nmix strangertalks.agents learning [limit]"

    assert current_context =~ "**A02 — Organizational Learning Advisor:**"
    assert current_context =~ "`SUPERSEDED_FOR_CURRENT_V1`"
    assert current_context =~ "mix strangertalks.intelligence [hours]"
    assert current_context =~ "Current V1 A02 organizational learning uses no model provider."

    refute current_context =~
             "A02–A04 use the shared schema-constrained `AgentSystems.Provider.structured/5` boundary"

    assert team8 =~ "Historical Team 8"
    assert team8 =~ "T-A08"

    assert team8 =~
             "historical model-based `mix strangertalks.agents learning` path is superseded"
  end

  defp section(document, start_heading, end_heading) do
    [_before, after_start] = String.split(document, start_heading, parts: 2)
    [body | _rest] = String.split(after_start, end_heading, parts: 2)
    body
  end
end
