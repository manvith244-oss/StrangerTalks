defmodule StrangertalksNew.AgentSystemsFunctionalTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.{
    LearningAdvisor,
    SafetyReviewAssistant,
    TrendBridgeResearch
  }

  alias StrangertalksNew.AgentSystemsFakeProvider, as: FakeProvider

  setup do
    previous_learning = Application.get_env(:strangertalks_new, :learning_advisor)
    previous_safety = Application.get_env(:strangertalks_new, :safety_review_assistant)
    previous_trend = Application.get_env(:strangertalks_new, :trend_bridge_research)

    FakeProvider.reset()
    script_default_responses()

    Application.put_env(:strangertalks_new, :learning_advisor, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :safety_review_assistant, provider: FakeProvider)
    Application.put_env(:strangertalks_new, :trend_bridge_research, provider: FakeProvider)

    on_exit(fn ->
      restore(:learning_advisor, previous_learning)
      restore(:safety_review_assistant, previous_safety)
      restore(:trend_bridge_research, previous_trend)
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

    assert [request] = FakeProvider.requests()
    assert request.agent_id == "learning_advisor"
    assert %{analytics: [payload]} = request.payload
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

    assert FakeProvider.requests() == []
  end

  test "Learning Advisor rejects nested private identifiers before provider invocation" do
    assert {:error, :personal_data_not_allowed} =
             LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 trend_category: %{
                   nested: %{
                     "conversation_id" => Ecto.UUID.generate(),
                     report_id: Ecto.UUID.generate()
                   }
                 },
                 aggregation_level: :AGGREGATED
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

    assert [request] = FakeProvider.requests()
    assert request.agent_id == "safety_review_assistant"
    refute Map.has_key?(request.payload, :participant_id)
    refute Map.has_key?(request.payload, "participant_id")
  end

  test "Safety Review Assistant rejects high punitive output without human review" do
    FakeProvider.script(
      "safety_review_assistant",
      {:ok,
       %{
         "severity" => "critical",
         "recommendation" => "permanent_ban",
         "rationale" => "Severe threat language.",
         "needs_human_review" => false
       }}
    )

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "THREATS",
               status: "SUBMITTED",
               evidence: "threat evidence",
               media_attached: false
             })
  end

  test "media safety review can never bypass human review" do
    FakeProvider.script(
      "safety_review_assistant",
      {:ok,
       %{
         "severity" => "critical",
         "recommendation" => "permanent_ban",
         "rationale" => "Severe threat language.",
         "needs_human_review" => false
       }}
    )

    assert {:error, :invalid_safety_review_output} =
             SafetyReviewAssistant.review(%{
               category: "THREATS",
               status: "SUBMITTED",
               evidence: "[View-Once Video Evidence Attached]",
               media_attached: true
             })
  end

  test "Safety Review Assistant propagates the existing provider error unchanged" do
    FakeProvider.script("safety_review_assistant", {:error, :agent_unavailable})

    assert {:error, :agent_unavailable} =
             SafetyReviewAssistant.review(%{
               category: "HARASSMENT",
               status: "SUBMITTED",
               evidence: "bounded evidence",
               media_attached: false
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

    assert [request] = FakeProvider.requests()
    assert request.agent_id == "trend_bridge_research"
    assert request.payload.language == "en"
    assert length(request.payload.signals) == 2
  end

  test "Trend research rejects unsupported languages and oversized signals before provider" do
    assert {:error, :unsupported_language} = TrendBridgeResearch.research("fr", ["signal"])

    assert {:error, :invalid_trend_research} =
             TrendBridgeResearch.research("en", [String.duplicate("x", 241)])

    assert FakeProvider.requests() == []
  end

  defp script_default_responses do
    FakeProvider.script(
      "learning_advisor",
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
    )

    FakeProvider.script(
      "safety_review_assistant",
      {:ok,
       %{
         "severity" => "medium",
         "recommendation" => "warning",
         "rationale" => "The supplied text warrants contextual human review.",
         "needs_human_review" => true
       }}
    )

    FakeProvider.script(
      "trend_bridge_research",
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
             "bridge" => "Has a recent match, movie, or festival changed your mood this week?",
             "rationale" =>
               "Offers optional cultural anchors without assuming one shared interest."
           }
         ]
       }}
    )
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
