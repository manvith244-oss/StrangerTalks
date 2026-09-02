defmodule StrangertalksNewWeb.GifController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.GifProvider
  alias StrangertalksNew.GifSearchAuthority
  alias StrangertalksNewWeb.ParticipantToken

  @allowed_search_keys ~w(q conversation_id)

  def status(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(GifProvider.status())
  end

  def index(conn, %{"q" => query, "conversation_id" => conversation_id} = params) do
    with true <- allowed_search_keys?(params),
         {:ok, participant_id} <- authenticate(conn),
         :ok <- valid_uuid(conversation_id),
         :ok <- rate_limit(:gif_search_burst, participant_id, 12, 60_000),
         :ok <- rate_limit(:gif_search_hourly, participant_id, 120, 3_600_000),
         {:ok, authority} <- GifSearchAuthority.capture(conversation_id, participant_id),
         {:ok, results} <- GifProvider.search(query),
         :ok <- GifSearchAuthority.revalidate(authority) do
      conn
      |> put_resp_header("cache-control", "no-store, private")
      |> json(%{results: results})
    else
      false -> error_response(conn, :invalid_payload)
      error -> error_response(conn, error)
    end
  end

  def index(conn, _params), do: error_response(conn, :invalid_payload)

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

  defp allowed_search_keys?(params) when is_map(params) do
    Enum.all?(Map.keys(params), &(&1 in @allowed_search_keys))
  end

  defp allowed_search_keys?(_params), do: false

  defp rate_limit(bucket, participant_id, limit, window_ms) do
    case StrangertalksNew.RateLimiter.allow(bucket, participant_id, limit, window_ms) do
      :ok -> :ok
      {:error, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp error_response(conn, {:error, reason}), do: error_response(conn, reason)

  defp error_response(conn, {:rate_limited, retry_after_ms}) do
    conn
    |> put_status(:too_many_requests)
    |> put_resp_header("cache-control", "no-store, private")
    |> json(%{error: "rate_limited", retry_after_ms: retry_after_ms})
  end

  defp error_response(conn, :invalid_token), do: gif_error(conn, :unauthorized, "invalid_token")

  defp error_response(conn, :invalid_payload),
    do: gif_error(conn, :bad_request, "invalid_request")

  defp error_response(conn, :invalid_query), do: gif_error(conn, :bad_request, "invalid_query")

  defp error_response(conn, :conversation_not_found),
    do: gif_error(conn, :not_found, "conversation_not_found")

  defp error_response(conn, :not_conversation_member),
    do: gif_error(conn, :forbidden, "not_conversation_member")

  defp error_response(conn, reason)
       when reason in [:conversation_unavailable, :conversation_stale],
       do: gif_error(conn, :conflict, "conversation_unavailable")

  defp error_response(conn, :provider_unavailable),
    do: gif_error(conn, :service_unavailable, "provider_unavailable")

  defp error_response(conn, :malformed_provider_response),
    do: gif_error(conn, :bad_gateway, "provider_malformed")

  defp error_response(conn, :rate_limited),
    do: gif_error(conn, :too_many_requests, "provider_rate_limited")

  defp error_response(conn, :provider_timeout),
    do: gif_error(conn, :gateway_timeout, "provider_timeout")

  defp error_response(conn, _reason), do: gif_error(conn, :bad_gateway, "provider_error")

  defp gif_error(conn, status, code) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store, private")
    |> json(%{error: code})
  end
end
