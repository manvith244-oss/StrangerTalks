defmodule Mix.Tasks.Strangertalks.Retention do
  use Mix.Task

  @shortdoc "Runs one bounded StrangerTalks retention cleanup pass"

  @moduledoc """
  Runs one idempotent primary-database retention cleanup pass.

      mix strangertalks.retention

  This task does not schedule itself. Production scheduling belongs to Team 8/release operations.
  The command exits non-zero when any cleanup category fails so operators can alert and retry
  without hiding a partial failure. Successful independent categories are not rolled back.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    StrangertalksNew.RetentionCleanup.run()
    |> handle_result!()
  end

  @doc false
  def handle_result!(result) when is_map(result) do
    Enum.each(result, fn {category, outcome} ->
      Mix.shell().info("retention #{category}=#{format_outcome(outcome)}")
    end)

    failures = Enum.filter(result, fn {_category, outcome} -> match?({:error, _}, outcome) end)

    if failures != [] do
      Mix.raise("retention cleanup completed with #{length(failures)} failed categories")
    end

    :ok
  end

  defp format_outcome({:ok, count}), do: "ok count=#{inspect(count)}"
  defp format_outcome({:error, _reason}), do: "error"
  defp format_outcome(other), do: inspect(other)
end
