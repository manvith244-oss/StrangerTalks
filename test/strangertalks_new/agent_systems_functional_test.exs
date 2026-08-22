defmodule StrangertalksNew.AgentSystemsFunctionalTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.{
    LearningAdvisor,
    SafetyReviewAssistant,
    TrendBridgeResearch
  }

  defmodule FakeProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :agent_systems_test_pid), {
        :agent_request,
        agent_id,
        payload
      })

      case agent_id do
        "learning_advisor" ->
          {:ok,
           %{
             "recommendations" => [
               %{
                 "title" => "Test queue recovery before changing thresholds",
                 "hypothesis" => "Recovery behavior may explain the observed drop.",
                 "evidence" => "The supplied aggregate snapshot shows recovery activation.",
                 "experiment" => "Run a small reviewed recovery-copy experiment.",
                 "confidence" => "medium"
               }
             ]
           }}

        "safety_review_assistant" ->
          mode = Application.get_env(:strangertalks_new, :safety_agent_test_mode, :normal)

          case mode do
            :unsafe_high_without_human ->
              {:ok,
               %{
                 "severity" => "critical",
                 "recommendation" => "permanent_ban",
                 "rationale" => "Severe threat language.",
                 "needs_human_review" => false
               }}

            _ ->
              {:ok,
               %{
                 "severity" => "medium",
                 "recommendation" => "warning",
                 "rationale" => "The supplied text warrants contextual human review.",
                 "needs_human_review" => true
               }}
          end

        "trend_bridge_research" ->
          {:ok,
           %{
             "candidates" => [
               %{
                 "tier" => "universal",
                 "bridge" => "What small thing has made this week better than expected?",
                 "rationale" => "Turns a current-week signal into ordinary lived experience."
               },
               %{
                 "tier" => "broad",
                 "bridge" =>
                   "What is something everyone seems to be talking about that you actually enjoy?",
                 "rationale" => "Keeps the prompt broad without requiring specialist knowledge."
               },
               %{
                 "tier" => "niche",
                 "bridge" =>
                   "Has a recent match, movie, or festival changed your mood this week?",
                 "rationale" =>
                   "Offers optional cultural anchors without assuming one shared interest."
               }
             ]
           }}
      end
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :agent_systems_test_pid)
    previous_learning = Application.get_env(:strangertalks_new, :learning_advisor)
    previous_safety = Application.get_env(:strangertalks_new, :safety_review_assistant)
    previous_trend = Application.get_env(:strangertalks_new, :trend_bridge_research)
    previous_mode = Application.get_env(:strangertalks_new, :safety_agent_test_mode)

    Application.put_env(:strangertalks_new, :agent_systems_test_pid, self())
    Application.put_env(:strangertalks_new, :learning_advisor, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :safety_review_assistant, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :trend_bridge_research, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :safety_agent_test_mode, :normal)

    on_exit(fn ->
      restore(:agent_systems_test_pid, previous_pid)
      restore(:learning_advisor, previous_learning)
      restore(:safety_review_assistant, previous_safety)
      restore(:trend_bridge_research, previous_trend)
      restore(:safety_agent_test_mode, previous_mode)
    end)

    :ok
  end

  test "Learning Advisor accepts only bounded aggregate data and has zero mutation authority" do
    assert {:ok, result} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 source_count: 100,
                 queue_success_rate: "0.82",
                 recovery_mode_activation_count: 8,
                 aggregation_level: :AGGREGATED
               }
             ])

    assert result.status == "ready"
    assert result.mutation_authority == false
    assert result.source_rows == 1
    assert length(result.recommendations) == 1

    assert_receive {:agent_request, "learning_advisor", %{analytics: [payload]}}
    refute Map.has_key?(payload, :participant_id)
    refute Map.has_key?(payload, :conversation_id)
  end

  test "Learning Advisor rejects personal identifiers before provider invocation" do
    assert {:error, :personal_data_not_allowed} =
             LearningAdvisor.advise([
               %{
                 participant_id: Ecto.UUID.generate(),
                 analytics_period: :DAILY,
                 source_type: :SYSTEM
               }
             ])

    refute_receive {:agent_request, "learning_advisor", _}, 20
  end

  test "Safety Review Assistant is advisory and strips identity authority" do
    assert {:ok, result} =
             SafetyReviewAssistant.review(%{
               category: "HARASSMENT",
               status: "SUBMITTED",
               evidence: "They kept insulting me after I asked them to stop.",
               media_attached: false,
               participant_id: "must-not-pass"
             })

    assert result.status == "ready"
    assert result.mutation_authority == false
    assert result.needs_human_review == true

    assert_receive {:agent_request, "safety_review_assistant", payload}
    refute Map.has_key?(payload, :participant_id)
    refute Map.has_key?(payload, "participant_id")
  end

  test "Safety Review Assistant rejects high punitive output without human review" do
    Application.put_env(:strangertalks_new, :safety_agent_test_mode, :unsafe_high_without_human)

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "THREATS",
               status: "SUBMITTED",
               evidence: "threat evidence",
               media_attached: false
             })
  end

  test "media safety review can never bypass human review" do
    Application.put_env(:strangertalks_new, :safety_agent_test_mode, :unsafe_high_without_human)

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "THREATS",
               status: "SUBMITTED",
               evidence: "[View-Once Video Evidence Attached]",
               media_attached: true
             })
  end

  test "Trend research returns candidates without publication authority" do
    assert {:ok, result} =
             TrendBridgeResearch.research("en", [
               "A big cricket match is being discussed this weekend",
               "Monsoon evenings are back"
             ])

    assert result.status == "ready"
    assert result.language == "en"
    assert result.publication_authority == false
    assert length(result.candidates) == 3

    assert_receive {:agent_request, "trend_bridge_research", payload}
    assert payload.language == "en"
    assert length(payload.signals) == 2
  end

  test "Trend research rejects unsupported languages and oversized signals before provider" do
    assert {:error, :unsupported_language} = TrendBridgeResearch.research("fr", ["signal"])

    assert {:error, :invalid_trend_research} =
             TrendBridgeResearch.research("en", [String.duplicate("x", 241)])

    refute_receive {:agent_request, "trend_bridge_research", _}, 20
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
