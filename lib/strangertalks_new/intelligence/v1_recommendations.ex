defmodule StrangertalksNew.Intelligence.V1Recommendations do
  @moduledoc """
  Deterministic V1 recommendation layer over Team 8 aggregate metrics.

  Recommendations are evidence packets for human/Command review. They have no
  code path for writing product configuration, safety state, matchmaking rules or
  Conversation state.
  """

  alias StrangertalksNew.Intelligence.V1Metrics

  @logic_version "team8-v1-recommendations-1"
  @max_window_seconds 31 * 24 * 60 * 60

  @system_keys MapSet.new([
                 :matches_created,
                 :same_door_matches,
                 :cross_door_matches,
                 :average_queue_time_seconds,
                 :conversations_started,
                 :natural_ends,
                 :technical_disconnects,
                 :failed_conversations
               ])

  @outcome_keys MapSet.new([
                  :voluntary_relationships_created,
                  :reports_submitted,
                  :block_terminated_conversations
                ])

  def logic_version, do: @logic_version

  @doc "Build reviewed observations from one canonical privacy-safe aggregate snapshot."
  def analyze(snapshot) when is_map(snapshot) do
    cond do
      not V1Metrics.safe_output?(snapshot) ->
        {:error, :unsafe_analytics_input}

      not canonical_snapshot?(snapshot) ->
        {:error, :invalid_analytics_input}

      true ->
        {:ok,
         %{
           logic_version: @logic_version,
           mutation_authority: false,
           requires_review: true,
           recommendations: build_recommendations(snapshot)
         }}
    end
  end

  def analyze(_snapshot), do: {:error, :invalid_analytics_input}

  defp canonical_snapshot?(
         %{
           schema_version: schema_version,
           window: window,
           system: system,
           human_outcomes: outcomes
         } = snapshot
       ) do
    MapSet.new(Map.keys(snapshot)) ==
      MapSet.new([:schema_version, :window, :system, :human_outcomes]) and
      schema_version == V1Metrics.schema_version() and
      valid_window?(window) and
      valid_metric_map?(system, @system_keys, [:average_queue_time_seconds]) and
      valid_metric_map?(outcomes, @outcome_keys, [])
  end

  defp canonical_snapshot?(_snapshot), do: false

  defp valid_window?(%{from: from, to: to} = window) do
    with true <- MapSet.new(Map.keys(window)) == MapSet.new([:from, :to]),
         {:ok, from_datetime, _from_offset} <- parse_iso8601(from),
         {:ok, to_datetime, _to_offset} <- parse_iso8601(to),
         seconds <- DateTime.diff(to_datetime, from_datetime, :second),
         true <- seconds > 0 and seconds <= @max_window_seconds do
      true
    else
      _ -> false
    end
  end

  defp valid_window?(_window), do: false

  defp parse_iso8601(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_iso8601(_value), do: :error

  defp valid_metric_map?(metrics, allowed_keys, numeric_keys) when is_map(metrics) do
    MapSet.new(Map.keys(metrics)) == allowed_keys and
      Enum.all?(metrics, fn {key, value} ->
        if key in numeric_keys do
          is_number(value) and value >= 0
        else
          is_integer(value) and value >= 0
        end
      end)
  end

  defp valid_metric_map?(_metrics, _allowed_keys, _numeric_keys), do: false

  defp build_recommendations(%{system: system, human_outcomes: outcomes, window: window}) do
    []
    |> maybe_add_reliability(system, window)
    |> maybe_add_safety(outcomes, window)
    |> Enum.reverse()
  end

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
    from = Map.get(window, :from)
    to = Map.get(window, :to)

    :crypto.hash(:sha256, Enum.join([@logic_version, area, from, to], "|"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
