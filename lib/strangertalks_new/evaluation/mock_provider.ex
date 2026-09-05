defmodule StrangertalksNew.Evaluation.MockProvider do
  @moduledoc """
  Deterministic offline Mock Provider for T-A13 evaluation testing and dry-run mode.

  Guarantees:
  - LIVE_TERRA_REQUESTS = 0
  - Refuses non-gpt-5.6-terra models with MODEL_IDENTITY_DISCREPANCY
  - Returns deterministic mock text outputs for C2 and C3 conditions
  """

  alias StrangertalksNew.Evaluation.{Config, Errors}

  def call(requested_model, condition, item, opts \\ []) do
    with :ok <- Config.verify_model_identity("gpt-5.6-terra", requested_model) do
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
      response_id = Keyword.get(opts, :response_id, "mock-resp-#{Ecto.UUID.generate()}")
      simulate = Keyword.get(opts, :simulate, nil)

      raw_request = %{
        "model" => requested_model,
        "condition" => condition,
        "item_id" => item["id"] || item[:id],
        "language" => item["language"] || item[:language],
        "temperature" => 0.2,
        "top_p" => 1.0,
        "max_tokens" => 2048
      }

      case simulate do
        :api_error ->
          {:error, %{type: :api_error, code: 500, message: "Simulated upstream provider error"}}

        :refusal ->
          refusal_text = "I cannot fulfill this request due to safety restrictions."

          {:ok,
           %{
             request_id: request_id,
             response_id: response_id,
             model: "gpt-5.6-terra",
             condition: condition,
             output: refusal_text,
             refusal: true,
             malformed_output: false,
             provider_error: nil,
             truncation: false,
             output_token_limit_event: false,
             raw_request: raw_request,
             raw: %{
               "id" => response_id,
               "model" => "gpt-5.6-terra",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{"role" => "assistant", "refusal" => refusal_text},
                   "finish_reason" => "stop"
                 }
               ]
             }
           }}

        :malformed ->
          malformed_text = "{\"incomplete\": [true, "

          {:ok,
           %{
             request_id: request_id,
             response_id: response_id,
             model: "gpt-5.6-terra",
             condition: condition,
             output: malformed_text,
             refusal: false,
             malformed_output: true,
             provider_error: nil,
             truncation: false,
             output_token_limit_event: false,
             raw_request: raw_request,
             raw: %{
               "id" => response_id,
               "model" => "gpt-5.6-terra",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{"role" => "assistant", "content" => malformed_text},
                   "finish_reason" => "stop"
                 }
               ]
             }
           }}

        :truncation ->
          truncated_output = "Sentence cut off abruptly due to token limit..."

          {:ok,
           %{
             request_id: request_id,
             response_id: response_id,
             model: "gpt-5.6-terra",
             condition: condition,
             output: truncated_output,
             refusal: false,
             malformed_output: false,
             provider_error: nil,
             truncation: true,
             output_token_limit_event: true,
             raw_request: raw_request,
             raw: %{
               "id" => response_id,
               "model" => "gpt-5.6-terra",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{"role" => "assistant", "content" => truncated_output},
                   "finish_reason" => "length"
                 }
               ]
             }
           }}

        _ ->
          simulated_output =
            case condition do
              "C2" ->
                "Mock baseline response for #{item["id"] || item[:id]} (#{item["language"] || item[:language]}): friendly stranger reply."

              "C3" ->
                "Mock companion suggestions for #{item["id"] || item[:id]} (#{item["language"] || item[:language]}): [1] Hello, nice to meet you. [2] How has your day been?"

              "C4" ->
                "Mock C4 evaluation response for #{item["id"] || item[:id]} (#{item["language"] || item[:language]})."

              other ->
                "Mock #{other} evaluation response for #{item["id"] || item[:id]} (#{item["language"] || item[:language]})."
            end

          {:ok,
           %{
             request_id: request_id,
             response_id: response_id,
             model: "gpt-5.6-terra",
             condition: condition,
             output: simulated_output,
             refusal: false,
             malformed_output: false,
             provider_error: nil,
             truncation: false,
             output_token_limit_event: false,
             raw_request: raw_request,
             raw: %{
               "id" => response_id,
               "model" => "gpt-5.6-terra",
               "choices" => [
                 %{
                   "index" => 0,
                   "message" => %{"role" => "assistant", "content" => simulated_output},
                   "finish_reason" => "stop"
                 }
               ],
               "usage" => %{prompt_tokens: 42, completion_tokens: 28, total_tokens: 70}
             }
           }}
      end
    else
      {:error, _reason} ->
        {:error, Errors.model_identity_discrepancy("gpt-5.6-terra", requested_model)}
    end
  end
end
