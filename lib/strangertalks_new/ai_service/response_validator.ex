defmodule StrangertalksNew.AIService.ResponseValidator do
  @moduledoc false

  alias StrangertalksNew.AIService.Error

  @max_response_body_bytes 65_536
  @required_keys ~w(error_code error_message request_id result status)

  @http_status_by_error %{
    "AI_INVALID_REQUEST" => 400,
    "AI_CONTRACT_UNSUPPORTED" => 400,
    "AI_AUTH_FAILED" => 401,
    "AI_CAPABILITY_DISABLED" => 403,
    "AI_PROVIDER_RATE_LIMITED" => 429,
    "AI_PROVIDER_UNAVAILABLE" => 502,
    "AI_PROVIDER_TIMEOUT" => 504,
    "AI_OUTPUT_REJECTED" => 422,
    "AI_OUTPUT_INVALID" => 422,
    "AI_INTERNAL_ERROR" => 500
  }

  @spec max_response_body_bytes() :: pos_integer()
  def max_response_body_bytes, do: @max_response_body_bytes

  @spec validate(non_neg_integer(), binary(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def validate(status, body, expected_request_id)
      when is_integer(status) and is_binary(body) and is_binary(expected_request_id) do
    with :ok <- body_size_ok(body),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- exact_envelope(decoded),
         :ok <- request_id_matches(decoded, expected_request_id) do
      validate_shape(status, decoded, expected_request_id)
    else
      _ -> {:error, Error.new("AI_MALFORMED_RESPONSE", expected_request_id)}
    end
  end

  defp body_size_ok(body) when byte_size(body) <= @max_response_body_bytes, do: :ok
  defp body_size_ok(_body), do: :error

  defp exact_envelope(decoded) when is_map(decoded) do
    if Enum.sort(Map.keys(decoded)) == @required_keys, do: :ok, else: :error
  end

  defp exact_envelope(_decoded), do: :error

  defp request_id_matches(%{"request_id" => request_id}, expected_request_id)
       when is_binary(request_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(request_id),
         true <- request_id == expected_request_id do
      :ok
    else
      _ -> :error
    end
  end

  defp request_id_matches(_decoded, _expected_request_id), do: :error

  defp validate_shape(
         200,
         %{
           "status" => "ok",
           "result" => %{"value" => value} = result,
           "error_code" => nil,
           "error_message" => nil
         },
         _request_id
       )
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 128 and
              map_size(result) == 1 do
    {:ok, result}
  end

  defp validate_shape(
         http_status,
         %{
           "status" => "error",
           "result" => nil,
           "error_code" => error_code,
           "error_message" => error_message
         },
         request_id
       )
       when is_binary(error_code) and is_binary(error_message) and byte_size(error_message) <= 256 do
    case Map.fetch(@http_status_by_error, error_code) do
      {:ok, ^http_status} -> {:error, Error.new(error_code, request_id)}
      _ -> {:error, Error.new("AI_MALFORMED_RESPONSE", request_id)}
    end
  end

  defp validate_shape(_status, _decoded, request_id),
    do: {:error, Error.new("AI_MALFORMED_RESPONSE", request_id)}
end
