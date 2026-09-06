defmodule StrangertalksNew.AgentSystemsBreakTest do
  use StrangertalksNew.DataCase, async: false

  alias StrangertalksNew.AgentSystems.{
    LearningAdvisor,
    SafetyReviewAssistant,
    TrendBridgeResearch
  }

  alias StrangertalksNew.Companion
  alias StrangertalksNew.Companion.OpenAIProvider

  defmodule DeclineHTTPClient do
    def responses(_config, body) do
      send(test_pid(), {:decline_response_request, body})

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "test-model",
           "output" => [
             %{
               "type" => "message",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" =>
                     Jason.encode!(%{
                       decision: "decline",
                       reason: "I can’t help with that request.",
                       suggestions: []
                     })
                 }
               ]
             }
           ]
         }
       }}
    end

    def moderate(_config, texts) do
      send(test_pid(), {:decline_moderation_request, texts})
      flagged = Application.get_env(:strangertalks_new, :decline_test_flagged, false)

      {:ok,
       %{
         status: 200,
         body: %{"results" => Enum.map(texts, fn _ -> %{"flagged" => flagged} end)}
       }}
    end

    defp test_pid, do: Application.fetch_env!(:strangertalks_new, :agent_break_test_pid)
  end

  defmodule ScriptedAgentProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :agent_break_test_pid), {
        :scripted_agent_request,
        agent_id,
        payload
      })

      Application.fetch_env!(:strangertalks_new, :agent_break_structured_result)
    end
  end

  setup do
    keys = [
      :companion,
      :agent_break_test_pid,
      :decline_test_flagged,
      :learning_advisor,
      :safety_review_assistant,
      :trend_bridge_research,
      :agent_break_structured_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:strangertalks_new, &1)})

    Application.put_env(:strangertalks_new, :agent_break_test_pid, self())
    Application.put_env(:strangertalks_new, :decline_test_flagged, false)

    Application.put_env(:strangertalks_new, :companion,
      enabled: true,
      api_key: "test-secret",
      model: "test-model",
      moderation_model: "test-moderation",
      http_client: DeclineHTTPClient
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
    end)

    :ok
  end

  test "Companion decline reason is moderated before it can be returned" do
    assert {:ok, %{decision: :decline, reason: reason}} =
             OpenAIProvider.generate(%{
               conversation_id: "opaque-conversation",
               participant_id: "opaque-participant",
               peer_id: "opaque-peer",
               language: "en",
               door: "JUST_TALK",
               mode: "respond",
               tone: "natural",
               request: "Help me pressure them",
               draft: nil,
               messages: []
             })

    assert is_binary(reason)
    assert_receive {:decline_response_request, %{store: false}}
    assert_receive {:decline_moderation_request, [^reason]}
  end

  test "flagged Companion decline reason fails closed" do
    Application.put_env(:strangertalks_new, :decline_test_flagged, true)

    assert {:error, :companion_unsafe_output} =
             OpenAIProvider.generate(%{
               conversation_id: "opaque-conversation",
               participant_id: "opaque-participant",
               peer_id: "opaque-peer",
               language: "en",
               door: "JUST_TALK",
               mode: "respond",
               tone: "natural",
               request: "unsafe request",
               draft: nil,
               messages: []
             })
  end

  test "invalid mode content never enters Companion telemetry" do
    handler_id = "agent-break-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:strangertalks_new, :companion, :request],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:companion_telemetry, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    secret = "my-private-secret-mode"

    assert {:error, :conversation_not_found} =
             Companion.request(Ecto.UUID.generate(), Ecto.UUID.generate(), %{"mode" => secret})

    assert_receive {:companion_telemetry, metadata}
    assert metadata.mode == "invalid"
    refute inspect(metadata) =~ secret
  end

  test "generic structured agent provider remains disabled without explicit Agent Systems enablement" do
    previous = Application.get_env(:strangertalks_new, :agent_systems)

    Application.put_env(:strangertalks_new, :agent_systems,
      enabled: false,
      api_key: "test-secret",
      http_client: DeclineHTTPClient
    )

    on_exit(fn -> restore(:agent_systems, previous) end)

    assert {:error, :agent_unavailable} =
             OpenAIProvider.structured(
               "learning_advisor",
               %{analytics: []},
               "Return JSON.",
               %{type: "object", additionalProperties: false, properties: %{}, required: []},
               []
             )

    refute_receive {:decline_response_request, _}, 20
  end

  test "A02 rejects schema-violating recommendation sets instead of salvaging partial model output" do
    configure_agent(LearningAdvisor, :learning_advisor)

    valid = valid_recommendation()

    cases = [
      {"extra top-level field", %{"recommendations" => [valid], "apply" => true}},
      {"extra recommendation field",
       %{"recommendations" => [Map.put(valid, "configuration_key", "match_threshold")]}},
      {"mixed valid and malformed recommendations",
       %{"recommendations" => [valid, %{"title" => "incomplete"}]}},
      {"too many recommendations",
       %{"recommendations" => Enum.map(1..6, &Map.put(valid, "title", "Recommendation #{&1}"))}}
    ]

    Enum.each(cases, fn {label, decoded} ->
      Application.put_env(
        :strangertalks_new,
        :agent_break_structured_result,
        {:ok, decoded}
      )

      assert LearningAdvisor.advise([
               %{
                 analytics_period: :DAILY,
                 source_type: :SYSTEM,
                 source_count: 10,
                 aggregation_level: :AGGREGATED
               }
             ]) == {:error, :invalid_learning_output},
             label
    end)
  end

  test "A03 rejects extra, malformed, and punitive output before it can leave advisory authority" do
    configure_agent(SafetyReviewAssistant, :safety_review_assistant)

    valid = valid_safety_recommendation()

    cases = [
      {"extra top-level field", Map.put(valid, "block_now", true)},
      {"missing required field", Map.delete(valid, "rationale")},
      {"wrong enum", Map.put(valid, "recommendation", "shadow_ban")},
      {"wrong type", Map.put(valid, "needs_human_review", "true")},
      {"punitive without human review",
       valid
       |> Map.put("severity", "critical")
       |> Map.put("recommendation", "permanent_ban")
       |> Map.put("needs_human_review", false)}
    ]

    Enum.each(cases, fn {label, decoded} ->
      Application.put_env(
        :strangertalks_new,
        :agent_break_structured_result,
        {:ok, decoded}
      )

      assert SafetyReviewAssistant.review(%{
               category: "HARASSMENT",
               status: "SUBMITTED",
               evidence: "bounded evidence",
               media_attached: false
             }) == {:error, :invalid_safety_review_output},
             label
    end)
  end

  test "A04 rejects schema-violating candidate sets instead of publishing or salvaging them" do
    configure_agent(TrendBridgeResearch, :trend_bridge_research)

    candidates = valid_bridge_candidates()

    cases = [
      {"extra top-level field", %{"candidates" => candidates, "publish" => true}},
      {"extra candidate field",
       %{
         "candidates" => [
           Map.put(hd(candidates), "publish_now", true)
           | tl(candidates)
         ]
       }},
      {"mixed valid and malformed candidates",
       %{"candidates" => candidates ++ [%{"tier" => "broad", "bridge" => "incomplete"}]}},
      {"too many candidates",
       %{
         "candidates" =>
           Enum.map(1..9, fn index ->
             %{
               "tier" => "broad",
               "bridge" => "Candidate #{index}",
               "rationale" => "Synthetic deterministic test candidate #{index}."
             }
           end)
       }}
    ]

    Enum.each(cases, fn {label, decoded} ->
      Application.put_env(
        :strangertalks_new,
        :agent_break_structured_result,
        {:ok, decoded}
      )

      assert TrendBridgeResearch.research("en", ["bounded current signal"]) ==
               {:error, :invalid_trend_research_output},
             label
    end)
  end

  defp configure_agent(_module, key) do
    Application.put_env(:strangertalks_new, key, provider: ScriptedAgentProvider)
  end

  defp valid_recommendation do
    %{
      "title" => "Test queue recovery before changing thresholds",
      "hypothesis" => "Recovery behavior may explain the observed drop.",
      "evidence" => "The supplied aggregate snapshot shows recovery activation.",
      "experiment" => "Run a small reviewed recovery-copy experiment.",
      "confidence" => "medium"
    }
  end

  defp valid_safety_recommendation do
    %{
      "severity" => "medium",
      "recommendation" => "warning",
      "rationale" => "The supplied text warrants contextual human review.",
      "needs_human_review" => true
    }
  end

  defp valid_bridge_candidates do
    [
      %{
        "tier" => "universal",
        "bridge" => "What small thing made this week better than expected?",
        "rationale" => "Ordinary lived experience."
      },
      %{
        "tier" => "broad",
        "bridge" => "What are people talking about that you actually enjoy?",
        "rationale" => "Broad shared curiosity."
      },
      %{
        "tier" => "niche",
        "bridge" => "Has a recent match, movie, or festival changed your mood?",
        "rationale" => "Optional cultural anchor."
      }
    ]
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
