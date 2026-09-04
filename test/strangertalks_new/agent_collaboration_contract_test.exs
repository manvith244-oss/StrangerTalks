defmodule StrangertalksNew.AgentCollaborationContractTest do
  use ExUnit.Case, async: true

  @contract_path "docs/AGENT_COLLABORATION_CONTRACT_V1.md"

  @capability_modules %{
    "A01" => "StrangertalksNew.Companion",
    "A02" => "StrangertalksNew.AgentSystems.LearningAdvisor",
    "A03" => "StrangertalksNew.AgentSystems.SafetyReviewAssistant",
    "A04" => "StrangertalksNew.AgentSystems.TrendBridgeResearch"
  }

  @capability_surfaces %{
    "A01" => [
      "lib/strangertalks_new/companion.ex",
      "lib/strangertalks_new/companion/context.ex",
      "lib/strangertalks_new/companion/output.ex",
      "lib/strangertalks_new/companion/provider.ex",
      "lib/strangertalks_new/companion/open_ai_provider.ex"
    ],
    "A02" => ["lib/strangertalks_new/agent_systems/learning_advisor.ex"],
    "A03" => ["lib/strangertalks_new/agent_systems/safety_review_assistant.ex"],
    "A04" => ["lib/strangertalks_new/agent_systems/trend_bridge_research.ex"]
  }

  test "V1 collaboration contract freezes capability identities and authority boundaries" do
    assert File.exists?(@contract_path),
           "Team 8 collaboration contract must exist at #{@contract_path}"

    contract = File.read!(@contract_path)

    assert contract =~ "# StrangerTalks Agent Collaboration Contract V1"
    assert contract =~ "default caller policy: **DENY**"
    assert contract =~ "T-A06 owns lifecycle/deployment/activation/governance truth"

    assert contract =~ "`conversation_companion.assist:v1`"
    assert contract =~ "`learning_advisor.model:v1`"
    assert contract =~ "`organizational_learning.recommend:v1`"
    assert contract =~ "`safety_review.recommend:v1`"
    assert contract =~ "`trend_bridge.research:v1`"

    for data_class <- [
          "public",
          "operational",
          "participant-private",
          "Safety-sensitive",
          "secret/prohibited"
        ] do
      assert contract =~ "`#{data_class}`"
    end

    for authority_class <- [
          "deterministic authority",
          "human-authorized action",
          "advisory",
          "research",
          "evidence",
          "provider result"
        ] do
      assert contract =~ "`#{authority_class}`"
    end

    assert contract =~ "`mutation_authority = false`"
    assert contract =~ "Provider execution is infrastructure, not Agent collaboration"
  end

  test "V1 contract freezes every direct A01-A04 Agent edge as NO EDGE" do
    contract = File.read!(@contract_path)

    for caller <- ~w(A01 A02 A03 A04),
        callee <- ~w(A01 A02 A03 A04),
        caller != callee do
      assert contract =~ "#{caller} -> #{callee} = NO EDGE"
    end
  end

  test "current Agent runtime surfaces do not directly reference another Agent capability" do
    for {owner, paths} <- @capability_surfaces do
      source =
        paths
        |> Enum.map(fn path ->
          assert File.exists?(path), "expected #{owner} runtime surface #{path}"
          File.read!(path)
        end)
        |> Enum.join("\n")
        |> sanitize_shared_provider()

      @capability_modules
      |> Map.drop([owner])
      |> Enum.each(fn {other_id, other_module} ->
        refute source =~ other_module,
               "#{owner} directly references #{other_id} (#{other_module}); V1 direct A2A edges are denied"
      end)
    end
  end

  test "historical model A02 remains dormant while deterministic V1 learning remains current" do
    task = File.read!("lib/mix/tasks/strangertalks.agents.ex")
    metrics = File.read!("lib/strangertalks_new/intelligence/v1_metrics.ex")
    recommendations = File.read!("lib/strangertalks_new/intelligence/v1_recommendations.ex")

    assert task =~ ":learning_advisor_superseded_by_team8_v1"
    assert metrics =~ "defmodule StrangertalksNew.Intelligence.V1Metrics"
    assert recommendations =~ "defmodule StrangertalksNew.Intelligence.V1Recommendations"
  end

  defp sanitize_shared_provider(source) do
    String.replace(
      source,
      "StrangertalksNew.Companion.OpenAIProvider",
      "StrangertalksNew.Infrastructure.SharedModelProvider"
    )
  end
end
