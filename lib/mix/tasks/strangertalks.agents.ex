defmodule Mix.Tasks.Strangertalks.Agents do
  use Mix.Task

  @shortdoc "Runs bounded StrangerTalks model-assisted operations"

  @moduledoc """
  Operational entry point for the remaining non-public model-assisted services.

      mix strangertalks.agents safety REPORT_ID
      mix strangertalks.agents trends LANGUAGE "signal one" "signal two"

  The historical `learning` command is intentionally superseded for V1. Team 8
  uses the deterministic, aggregate-only `mix strangertalks.intelligence` report
  instead; V1 does not need a model to interpret its canonical operational
  outcomes.
  """

  alias StrangertalksNew.AgentSystems.{SafetyReviewAssistant, TrendBridgeResearch}

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    result =
      case args do
        ["learning" | _rest] ->
          {:error, :learning_advisor_superseded_by_team8_v1}

        ["safety", report_id] ->
          SafetyReviewAssistant.review_report(report_id)

        ["trends", language | signals] when signals != [] ->
          operator_signals =
            Enum.map(signals, fn signal ->
              %{text: signal, provenance: :OPERATOR_PROVIDED}
            end)

          TrendBridgeResearch.research(language, operator_signals)

        _ ->
          {:error, :invalid_agent_command}
      end

    case result do
      {:ok, payload} ->
        Mix.shell().info(Jason.encode!(payload, pretty: true))

      {:error, reason} ->
        Mix.raise("Agent Systems operation failed: #{reason}")

      _ ->
        Mix.raise("Agent Systems operation failed: invalid result")
    end
  end
end
