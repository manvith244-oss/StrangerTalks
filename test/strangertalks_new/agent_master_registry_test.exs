defmodule StrangertalksNew.AgentMasterRegistryTest do
  use ExUnit.Case, async: true

  @registry_path "docs/AGENT_MASTER_REGISTRY.md"
  @agent_task_path "lib/mix/tasks/strangertalks.agents.ex"
  @python_app_path "services/ai/src/strangertalks_ai/app.py"

  test "current registry preserves bounded authority and runtime taxonomy" do
    assert File.exists?(@registry_path),
           "canonical Agent registry must exist at #{@registry_path}"

    registry = File.read!(@registry_path)

    a01 = current_section(registry, "A01")

    assert a01 =~
             "implementation_kind: `BOUNDED MODEL-ASSISTED PARTICIPANT CAPABILITY`"

    assert a01 =~ "positive_authority: `suggest/draft only`"

    assert a01 =~
             "forbidden_authority: `send, impersonate, Matchmaking mutation, Safety mutation, Relationship mutation, deployment`"

    a02 = current_section(registry, "A02")
    assert a02 =~ "organizational_status: `CURRENT`"
    assert a02 =~ "implementation_kind: `DETERMINISTIC INTELLIGENCE SERVICE`"
    assert a02 =~ "runtime_status: `CURRENT / DETERMINISTIC V1`"
    assert a02 =~ "LearningAdvisor — SUPERSEDED_FOR_CURRENT_V1 / DORMANT"
    assert File.read!(@agent_task_path) =~ ":learning_advisor_superseded_by_team8_v1"

    a03 = current_section(registry, "A03")

    assert a03 =~
             "implementation_kind: `BOUNDED MODEL-ASSISTED SAFETY ADVISORY CAPABILITY`"

    assert a03 =~ "positive_authority: `recommendation only`"

    assert a03 =~
             "forbidden_authority: `ban, Block, punish, terminalize, Matchmaking mutation, SafetyReview mutation, deployment`"

    a04 = current_section(registry, "A04")
    assert a04 =~ "implementation_kind: `BOUNDED RESEARCH CAPABILITY`"
    assert a04 =~ "positive_authority: `research/candidate generation only`"

    assert a04 =~
             "forbidden_authority: `autonomous publication, live Conversation injection, autonomous browsing unless separately authorized, catalog mutation, deployment`"

    assert registry =~ "Python production Agent runtime: `NOT CANONICAL / HEALTH-ONLY FOUNDATION`"

    python_app = File.read!(@python_app_path)
    assert python_app =~ "app.include_router(health_router)"
    assert length(Regex.scan(~r/app\.include_router\(/, python_app)) == 1
  end

  defp current_section(registry, id) do
    marker = "## #{id} —"

    case String.split(registry, marker, parts: 2) do
      [_before, rest] -> rest |> String.split("\n## ", parts: 2) |> hd()
      _ -> flunk("missing current registry section #{id}")
    end
  end
end
