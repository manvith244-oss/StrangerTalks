defmodule StrangertalksNew.Intelligence.V1Recommendations do
  @moduledoc """
  Deterministic V1 recommendation layer over Team 8 aggregate metrics.

  Recommendations are evidence packets for human/Command review. They have no
  code path for writing product configuration, safety state, matchmaking rules or
  Conversation state.
  """

  alias StrangertalksNew.Intelligence.V1Metrics

  @logic_version "team8-v1-recommendations-1"

  def logic_version, do: @logic_version

  @doc "Build reviewed observations from one privacy-safe aggregate snapshot."
  def analyze(snapshot) when is_map(snapshot) do
    if V1Metrics.safe_output?(snapshot) do
      {:ok,
       %{
         logic_version: @logic_version,
         mutation_authority: false,
         requires_review: true,
         recommendations: build_recommendations(snapshot)
       }}
    else
      {:error, :unsafe_analytics_input}
    end
  end

  def analyze(_snapshot), do: {:error, :invalid_analytics_input}

  defp build_recommendations(%{system: system, human_outcomes: outcomes, window: window}) do
    []
    |> maybe_add_reliability(system, window)
    |> maybe_add_safety(outcomes, window)
    |> Enum.reverse()
  end

  defp build_recommendations(_snapshot), do: []

  defp maybe_add_reliability(recommendations, system, window) do
    disconnects = Map.get(system, :technical_disconnects, 0)
    failures = Map.get(system, :failed_conversations, 0)

    if positive_integer?(disconnects) or positive_integer?(failures) do
      [
        recommendation(
          "conversation_reliability",
          window,
          "Durable Conversation reliability failures were observed in the reporting window.",
          %{
            technical_disconnects: disconnects,
            failed_conversations: failures
          },
          "Team 5 should inspect the underlying reliability failures and regressions before any product-policy change.",
          "operational"
        )
        | recommendations
      ]
    else
      recommendations
    end
  end

  defp maybe_add_safety(recommendations, outcomes, window) do
    reports = Map.get(outcomes, :reports_submitted, 0)
    blocks = Map.get(outcomes, :block_terminated_conversations, 0)

    if positive_integer?(reports) or positive_integer?(blocks) do
      [
        recommendation(
          "safety_observation",
          window,
          "Participants used canonical safety boundaries in the reporting window.",
          %{
            reports_submitted: reports,
            block_terminated_conversations: blocks
          },
          "Team 4 should review the aggregate incidence and canonical safety records. Do not weaken or automatically retune safety boundaries from this recommendation.",
          "safety"
        )
        | recommendations
      ]
    else
      recommendations
    end
  end

  defp recommendation(area, window, observation, evidence, suggested_change, risk_class) do
    %{
      recommendation_id: stable_id(area, window),
      area: area,
      observation: observation,
      evidence_window: window,
      evidence: evidence,
      suggested_change: suggested_change,
      risk_class: risk_class,
      requires_review: true,
      mutation_authority: false,
      logic_version: @logic_version
    }
  end

  defp stable_id(area, window) do
    from = Map.get(window, :from) || Map.get(window, "from") || "unknown"
    to = Map.get(window, :to) || Map.get(window, "to") || "unknown"

    :crypto.hash(:sha256, Enum.join([@logic_version, area, from, to], "|"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
