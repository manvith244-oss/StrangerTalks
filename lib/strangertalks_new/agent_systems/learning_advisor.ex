defmodule StrangertalksNew.AgentSystems.LearningAdvisor do
  @moduledoc """
  A02 offline Learning Advisor.

  It reasons only over aggregated/system analytics and returns recommendations. It has no mutation
  path into matchmaking, Conversation Start, safety policy, application configuration, or deploys.
  """

  import Ecto.Query, warn: false

  alias StrangertalksNew.{AnalyticsRecord, Repo}
  alias StrangertalksNew.Companion.OpenAIProvider

  @max_rows 20
  @allowed_fields [
    :analytics_period,
    :analytics_date,
    :source_type,
    :source_count,
    :active_participants,
    :matches_created,
    :average_queue_time_seconds,
    :queue_success_rate,
    :match_failure_rate,
    :recovery_mode_activation_count,
    :conversations_started,
    :conversations_completed,
    :average_conversation_duration,
    :conversation_success_rate,
    :icebreakers_shown,
    :icebreakers_used,
    :icebreaker_usage_rate,
    :relationships_created,
    :relationship_creation_rate,
    :reports_submitted,
    :blocks_created,
    :emergency_exits,
    :safety_review_rate,
    :platform_health_score,
    :connection_success_score,
    :participant_satisfaction_score,
    :trust_score,
    :quality_weighted_conversations_rate,
    :trend_category,
    :trend_direction,
    :trend_strength,
    :aggregation_level
  ]

  @forbidden_personal_keys [
    :participant_id,
    :participant_a_id,
    :participant_b_id,
    :conversation_id,
    :match_id,
    :message_id,
    :report_id,
    :reporter_context,
    :review_notes,
    "participant_id",
    "participant_a_id",
    "participant_b_id",
    "conversation_id",
    "match_id",
    "message_id",
    "report_id",
    "reporter_context",
    "review_notes"
  ]

  def advise_latest(limit \\ 12)

  def advise_latest(limit) when is_integer(limit) and limit in 1..@max_rows do
    with {:ok, rows} <- snapshot(limit), do: advise(rows)
  end

  def advise_latest(_limit), do: {:error, :invalid_learning_snapshot}

  def snapshot(limit \\ 12)

  def snapshot(limit) when is_integer(limit) and limit in 1..@max_rows do
    rows =
      AnalyticsRecord
      |> where([a], a.contains_personal_data == false)
      |> where([a], a.aggregation_level in [:AGGREGATED, :SYSTEM_ONLY])
      |> order_by([a], desc: a.created_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&project_row/1)

    {:ok, rows}
  end

  def snapshot(_limit), do: {:error, :invalid_learning_snapshot}

  def advise(rows) when is_list(rows) and length(rows) <= @max_rows do
    with {:ok, snapshot} <- normalize_snapshot(rows),
         true <- snapshot != [],
         {:ok, decoded} <-
           provider().structured(
             "learning_advisor",
             %{analytics: snapshot},
             instructions(),
             schema(),
             max_output_tokens: 900
           ),
         {:ok, recommendations} <- validate_output(decoded) do
      {:ok,
       %{
         status: "ready",
         recommendations: recommendations,
         mutation_authority: false,
         source_rows: length(snapshot)
       }}
    else
      false -> {:error, :insufficient_learning_data}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_learning_output}
    end
  end

  def advise(_rows), do: {:error, :invalid_learning_snapshot}

  defp provider do
    :strangertalks_new
    |> Application.get_env(:learning_advisor, [])
    |> Keyword.get(:provider, OpenAIProvider)
  end

  defp project_row(%AnalyticsRecord{} = row) do
    row
    |> Map.from_struct()
    |> Map.take(@allowed_fields)
    |> normalize_values()
  end

  defp normalize_snapshot(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      if is_map(row) do
        projected =
          row
          |> Map.take(@allowed_fields)
          |> normalize_values()

        if personal_key_present?(row) do
          {:halt, {:error, :personal_data_not_allowed}}
        else
          {:cont, {:ok, [projected | acc]}}
        end
      else
        {:halt, {:error, :invalid_learning_snapshot}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp personal_key_present?(value) when is_map(value) do
    Map.get(value, :contains_personal_data) == true or
      Map.get(value, "contains_personal_data") == true or
      Enum.any?(value, fn {key, nested} ->
        key in @forbidden_personal_keys or personal_key_present?(nested)
      end)
  end

  defp personal_key_present?(value) when is_list(value),
    do: Enum.any?(value, &personal_key_present?/1)

  defp personal_key_present?(_value), do: false

  defp normalize_values(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp normalize_values(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_values(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_values(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, normalize_values(item)} end)
  end

  defp normalize_values(value) when is_list(value), do: Enum.map(value, &normalize_values/1)
  defp normalize_values(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_values(value), do: value

  defp validate_output(%{"recommendations" => recommendations}) when is_list(recommendations) do
    normalized =
      recommendations
      |> Enum.map(&normalize_recommendation/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, item} -> item end)
      |> Enum.uniq_by(&String.downcase(&1.title))
      |> Enum.take(5)

    if normalized == [], do: {:error, :invalid_learning_output}, else: {:ok, normalized}
  end

  defp validate_output(_decoded), do: {:error, :invalid_learning_output}

  defp normalize_recommendation(%{
         "title" => title,
         "hypothesis" => hypothesis,
         "evidence" => evidence,
         "experiment" => experiment,
         "confidence" => confidence
       })
       when confidence in ["low", "medium", "high"] do
    values = [title, hypothesis, evidence, experiment]

    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "" and String.length(&1) <= 600)) do
      {:ok,
       %{
         title: String.trim(title),
         hypothesis: String.trim(hypothesis),
         evidence: String.trim(evidence),
         experiment: String.trim(experiment),
         confidence: confidence
       }}
    else
      {:error, :invalid}
    end
  end

  defp normalize_recommendation(_item), do: {:error, :invalid}

  defp instructions do
    """
    You are StrangerTalks Learning Advisor. Analyze only the supplied aggregated/system analytics.
    Never infer individual participant traits and never claim access to raw conversations, private
    identity, safety notes, or hidden behavioral profiles. Produce evidence-grounded hypotheses and
    small reversible experiments. Retention/session volume must not override connection quality or
    safety. You are advisory only: never claim that you changed production behavior, configuration,
    matchmaking, safety rules, or content. Return only the required JSON.
    """
  end

  defp schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        recommendations: %{
          type: "array",
          minItems: 1,
          maxItems: 5,
          items: %{
            type: "object",
            additionalProperties: false,
            properties: %{
              title: %{type: "string"},
              hypothesis: %{type: "string"},
              evidence: %{type: "string"},
              experiment: %{type: "string"},
              confidence: %{type: "string", enum: ["low", "medium", "high"]}
            },
            required: ["title", "hypothesis", "evidence", "experiment", "confidence"]
          }
        }
      },
      required: ["recommendations"]
    }
  end
end
