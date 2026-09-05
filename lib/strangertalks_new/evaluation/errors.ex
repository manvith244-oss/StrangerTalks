defmodule StrangertalksNew.Evaluation.Errors do
  @moduledoc """
  Explicit representations for refusal, malformed outputs, API errors,
  truncation, model discrepancies, and experiment configuration rejections.
  """

  def refusal(reason) do
    %{
      type: :refusal,
      status: "refusal",
      reason: reason,
      terminal: true
    }
  end

  def malformed(raw_output, parse_error \\ nil) do
    %{
      type: :malformed,
      status: "malformed",
      raw_output: raw_output,
      parse_error: parse_error,
      terminal: true
    }
  end

  def api_error(status_code, code, message) do
    %{
      type: :api_error,
      status: "api_error",
      http_status: status_code,
      code: code,
      message: message,
      retryable: retryable_status?(status_code)
    }
  end

  def credit_balance_exhausted do
    %{
      type: :api_error,
      status: "credit_balance_exhausted",
      http_status: 429,
      code: "credit_balance_exhausted",
      message: "The account has reached its billing limit or credit balance is exhausted",
      retryable: false,
      terminal: true
    }
  end

  def truncation(tokens_used, max_tokens \\ 2048) do
    %{
      type: :truncation,
      status: "truncated",
      tokens_used: tokens_used,
      max_output_tokens: max_tokens,
      finish_reason: "length"
    }
  end

  def model_identity_discrepancy(requested, returned) do
    %{
      type: :model_identity_discrepancy,
      status: "MODEL_IDENTITY_DISCREPANCY",
      requested_model: requested,
      returned_model: returned,
      terminal: true
    }
  end

  def configuration_incompatibility(reason) do
    %{
      type: :configuration_incompatibility,
      status: "T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY",
      reason: reason,
      terminal: true
    }
  end

  defp retryable_status?(status) when status in [408, 409, 500, 502, 503, 504], do: true
  defp retryable_status?(_status), do: false
end
