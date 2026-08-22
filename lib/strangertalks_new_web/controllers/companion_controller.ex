defmodule StrangertalksNewWeb.CompanionController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Companion
  alias StrangertalksNewWeb.ParticipantToken

  @allowed_keys ~w(mode request draft tone)

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    companion_params = Map.drop(params, ["conversation_id"])

    with {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id),
         true <- allowed_keys?(companion_params),
         :ok <- rate_limit(:companion_burst, participant_id, 4, 30_000),
         :ok <- rate_limit(:companion_hourly, participant_id, 30, 3_600_000),
         {:ok, result} <- Companion.request(conversation_id, participant_id, companion_params) do
      conn
      |> put_resp_header("cache-control", "no-store, private")
      |> json(result)
    else
      false -> error_response(conn, :invalid_payload)
      error -> error_response(conn, error)
    end
  end

  def create(conn, _params), do: error_response(conn, :invalid_payload)

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, participant_id} <- ParticipantToken.verify(token) do
      {:ok, participant_id}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp valid_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_payload}
    end
  end

  defp valid_uuid(_value), do: {:error, :invalid_payload}

  defp allowed_keys?(params) when is_map(params) do
    Enum.all?(Map.keys(params), &(&1 in @allowed_keys))
  end

  defp allowed_keys?(_params), do: false

  defp rate_limit(bucket, participant_id, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(bucket, participant_id, limit, window_ms) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp error_response(conn, {:error, reason}), do: error_response(conn, reason)

  defp error_response(conn, {:rate_limited, retry_after_ms}) do
    conn
    |> put_status(429)
    |> put_resp_header("cache-control", "no-store, private")
    |> json(%{
      error: %{
        code: "COMPANION_RATE_LIMITED",
        retryable: true,
        retry_after_ms: retry_after_ms
      }
    })
  end

  defp error_response(conn, :invalid_token),
    do: companion_error(conn, 401, "COMPANION_INVALID_TOKEN", false)

  defp error_response(conn, :conversation_not_found),
    do: companion_error(conn, 404, "COMPANION_CONVERSATION_NOT_FOUND", false)

  defp error_response(conn, :not_conversation_member),
    do: companion_error(conn, 403, "COMPANION_NOT_CONVERSATION_MEMBER", false)

  defp error_response(conn, :invalid_payload),
    do: companion_error(conn, 400, "COMPANION_INVALID_PAYLOAD", false)

  defp error_response(conn, :conversation_unavailable),
    do: companion_error(conn, 409, "COMPANION_CONVERSATION_UNAVAILABLE", false)

  defp error_response(conn, :companion_stale),
    do: companion_error(conn, 409, "COMPANION_STALE", true)

  defp error_response(conn, :companion_unsafe_output),
    do: companion_error(conn, 422, "COMPANION_OUTPUT_REJECTED", true)

  defp error_response(conn, reason)
       when reason in [:companion_unavailable, :companion_provider_failure] do
    companion_error(conn, 503, "COMPANION_UNAVAILABLE", true)
  end

  defp error_response(conn, _reason),
    do: companion_error(conn, 500, "COMPANION_FAILED", true)

  defp companion_error(conn, status, code, retryable) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store, private")
    |> json(%{error: %{code: code, retryable: retryable}})
  end
end
