defmodule Mix.Tasks.Strangertalks.Intelligence do
  use Mix.Task

  @shortdoc "Prints the privacy-safe StrangerTalks V1 intelligence report"

  @moduledoc """
  Produces an on-demand, read-only Team 8 report from canonical durable outcomes.

      mix strangertalks.intelligence
      mix strangertalks.intelligence 24

  The optional argument is the number of trailing hours to inspect. V1 is capped
  at 31 days. The task never writes analytics, learning, product configuration or
  participant state.
  """

  alias StrangertalksNew.Intelligence.{V1Metrics, V1Recommendations}

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, hours} <- parse_hours(args),
         to <- DateTime.utc_now(),
         from <- DateTime.add(to, -hours, :hour),
         {:ok, metrics} <- V1Metrics.snapshot(from, to),
         {:ok, recommendations} <- V1Recommendations.analyze(metrics) do
      Mix.shell().info(
        Jason.encode!(
          %{
            metrics: metrics,
            recommendations: recommendations,
            metric_dictionary: V1Metrics.metric_dictionary()
          },
          pretty: true
        )
      )
    else
      {:error, reason} -> Mix.raise("Intelligence report failed: #{inspect(reason)}")
    end
  end

  defp parse_hours([]), do: {:ok, 24}

  defp parse_hours([hours]) do
    case Integer.parse(hours) do
      {value, ""} when value >= 1 and value <= 31 * 24 -> {:ok, value}
      _ -> {:error, :invalid_reporting_window}
    end
  end

  defp parse_hours(_args), do: {:error, :invalid_reporting_window}
end
