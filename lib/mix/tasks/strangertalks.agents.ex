defmodule Mix.Tasks.Strangertalks.Agents do
  use Mix.Task

  @shortdoc "Runs bounded StrangerTalks Agent Systems operations"

  @moduledoc """
  Operational entry point for non-public StrangerTalks agents.

      mix strangertalks.agents learning [limit]
      mix strangertalks.agents safety REPORT_ID
      mix strangertalks.agents trends LANGUAGE "signal one" "signal two"

  The command never exposes a public HTTP administration surface. Agent-specific authority limits
  remain enforced by their owning modules.
  """

  alias StrangertalksNew.AgentSystems.{
    LearningAdvisor,
    SafetyReviewAssistant,
    TrendBridgeResearch
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    result =
      case args do
        ["learning"] ->
          LearningAdvisor.advise_latest()

        ["learning", limit] ->
          with {integer, ""} <- Integer.parse(limit), do: LearningAdvisor.advise_latest(integer)

        ["safety", report_id] ->
          SafetyReviewAssistant.review_report(report_id)

        ["trends", language | signals] when signals != [] ->
          TrendBridgeResearch.research(language, signals)

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
