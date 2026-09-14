defmodule StrangertalksNew.WT02ContextRecorderTargetGate do
  defmodule InvalidObservationError do
    defexception [:message, :diagnostic_result]
  end

  alias __MODULE__.InvalidObservationError

  def after_product_assertions!(diagnostic_result, product_assertions)
      when is_function(product_assertions, 0) do
    product_result = product_assertions.()
    enforce_diagnostic!(diagnostic_result)
    product_result
  end

  defp enforce_diagnostic!(:ok), do: :ok

  defp enforce_diagnostic!({:error, {:recorder_unavailable, reason}} = result) do
    raise InvalidObservationError,
      message: "WT02 recorder unavailable after native product assertions: #{inspect(reason)}",
      diagnostic_result: result
  end

  defp enforce_diagnostic!(other) do
    raise InvalidObservationError,
      message: "WT02 invalid diagnostic handoff after native product assertions: #{inspect(other)}",
      diagnostic_result: other
  end
end
