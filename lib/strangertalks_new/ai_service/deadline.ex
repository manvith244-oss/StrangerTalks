defmodule StrangertalksNew.AIService.Deadline do
  @moduledoc false

  @spec run((-> term()), pos_integer()) :: {:ok, term()} | {:error, :timeout | {:exit, term()}}
  def run(fun, timeout_ms)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:error, {:exit, reason}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
