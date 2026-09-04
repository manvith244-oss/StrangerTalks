defmodule StrangertalksNew.TrendBridgeResearchProvenanceTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.AgentSystems.TrendBridgeResearch

  defmodule CaptureProvider do
    @behaviour StrangertalksNew.AgentSystems.Provider

    @impl true
    def structured(agent_id, payload, _instructions, _schema, _opts) do
      send(Application.fetch_env!(:strangertalks_new, :a04_provenance_test_pid), {
        :agent_request,
        agent_id,
        payload
      })

      {:ok,
       %{
         "candidates" => [
           %{
             "tier" => "universal",
             "bridge" => "What small thing has made this week better than expected?",
             "rationale" => "Turns a current signal into ordinary lived experience."
           },
           %{
             "tier" => "broad",
             "bridge" => "What is something people are talking about that you actually enjoy?",
             "rationale" => "Keeps the prompt broad without specialist knowledge."
           },
           %{
             "tier" => "niche",
             "bridge" => "Has a recent match, movie, or festival changed your mood this week?",
             "rationale" => "Offers optional cultural anchors."
           }
         ]
       }}
    end
  end

  setup do
    previous_pid = Application.get_env(:strangertalks_new, :a04_provenance_test_pid)
    previous_trend = Application.get_env(:strangertalks_new, :trend_bridge_research)

    Application.put_env(:strangertalks_new, :a04_provenance_test_pid, self())
    Application.put_env(:strangertalks_new, :trend_bridge_research, provider: CaptureProvider)

    on_exit(fn ->
      restore(:a04_provenance_test_pid, previous_pid)
      restore(:trend_bridge_research, previous_trend)
    end)

    :ok
  end

  test "unclassified raw-string research reaches the provider instead of failing closed" do
    result =
      TrendBridgeResearch.research("en", [
        "Copied from a private participant Conversation without provenance metadata"
      ])

    assert_receive {:agent_request, "trend_bridge_research", payload}
    assert payload == %{
             language: "en",
             signals: ["Copied from a private participant Conversation without provenance metadata"]
           }

    assert {:error, :unclassified_research_signal} = result
  end

  defp restore(key, nil), do: Application.delete_env(:strangertalks_new, key)
  defp restore(key, value), do: Application.put_env(:strangertalks_new, key, value)
end
