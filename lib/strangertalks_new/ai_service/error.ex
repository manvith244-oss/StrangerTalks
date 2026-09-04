defmodule StrangertalksNew.AIService.Error do
  @moduledoc false

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :request_id]

  @messages %{
    "AI_INVALID_REQUEST" => "request rejected",
    "AI_CONTRACT_UNSUPPORTED" => "contract unsupported",
    "AI_AUTH_FAILED" => "service authentication failed",
    "AI_CAPABILITY_DISABLED" => "capability disabled",
    "AI_PROVIDER_RATE_LIMITED" => "provider rate limited",
    "AI_PROVIDER_UNAVAILABLE" => "provider unavailable",
    "AI_PROVIDER_TIMEOUT" => "provider timed out",
    "AI_OUTPUT_REJECTED" => "output rejected",
    "AI_OUTPUT_INVALID" => "output invalid",
    "AI_INTERNAL_ERROR" => "internal service error",
    "AI_SERVICE_UNAVAILABLE" => "AI service unavailable",
    "AI_SERVICE_TIMEOUT" => "AI service timed out",
    "AI_CIRCUIT_OPEN" => "AI service circuit open",
    "AI_MALFORMED_RESPONSE" => "AI service response malformed"
  }

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          request_id: String.t() | nil
        }

  @spec new(String.t(), String.t() | nil) :: t()
  def new(code, request_id \\ nil) do
    %__MODULE__{
      code: code,
      message: Map.get(@messages, code, "AI service error"),
      request_id: request_id
    }
  end
end
