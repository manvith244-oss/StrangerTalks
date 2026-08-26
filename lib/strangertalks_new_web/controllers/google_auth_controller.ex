defmodule StrangertalksNewWeb.GoogleAuthController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.{Accounts, GoogleContinuity, Participants}
  alias StrangertalksNewWeb.ParticipantToken

  @cookie "strangertalks_account"
  @max_age 30 * 24 * 60 * 60

  def start(conn, %{"mode" => mode}) do
    with true <- GoogleContinuity.enabled?(),
         true <- rate_allowed?(:oauth_start, conn, 10),
         {:ok, internal_mode, participant_id} <- mode(mode, conn),
         {:ok, _attempt, state, nonce} <- Accounts.start_oauth(internal_mode, participant_id) do
      conn = put_session(conn, :google_oauth_nonce, nonce)

      authorization_url =
        GoogleContinuity.provider().authorization_url(state, nonce, internal_mode)

      if accepts_json?(conn) do
        json(conn, %{authorization_url: authorization_url})
      else
        redirect(conn, external: authorization_url)
      end
    else
      false ->
        unavailable_or_limited(conn)

      {:error, :unauthorized_participant} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{reason: "verified_participant_required"}})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{reason: "oauth_start_failed"}})
    end
  end

  def start(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: %{reason: "invalid_mode"}})

  def callback(conn, %{"state" => state, "code" => code}) do
    nonce = get_session(conn, :google_oauth_nonce)

    with true <- GoogleContinuity.enabled?(),
         true <- rate_allowed?(:oauth_callback, conn, 20),
         true <- is_binary(nonce),
         {:ok, attempt} <- Accounts.consume_oauth(state),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, nonce), attempt.nonce_hash),
         {:ok, provider_result} <- GoogleContinuity.provider().exchange_and_verify(code, nonce),
         {:ok, result} <- Accounts.complete_oauth(attempt, provider_result) do
      if attempt.mode == "LINK_CURRENT_GUEST" do
        disconnect_participant_sockets(result.account.participant_id)
      end

      conn
      |> delete_session(:google_oauth_nonce)
      |> put_account_cookie(result.raw_token)
      |> redirect(to: "/you?account=connected")
    else
      {:error, :existing_account_available} ->
        redirect(conn, to: "/you?account=existing_account_available")

      _ ->
        redirect(conn, to: "/you?account=google_connection_failed")
    end
  end

  def callback(conn, _params), do: redirect(conn, to: "/you?account=google_connection_failed")

  def cookie_name, do: @cookie

  def put_account_cookie(conn, token) do
    put_resp_cookie(conn, @cookie, token,
      http_only: true,
      same_site: "Lax",
      secure: Application.get_env(:strangertalks_new, :account_cookie_secure, Mix.env() == :prod),
      path: "/",
      max_age: @max_age
    )
  end

  def clear_account_cookie(conn), do: delete_resp_cookie(conn, @cookie, path: "/")

  defp mode("login", _conn), do: {:ok, "SIGN_IN_EXISTING", nil}

  defp mode("link", conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, participant_id} <- ParticipantToken.verify(token),
         participant when not is_nil(participant) <- Participants.get_participant(participant_id) do
      {:ok, "LINK_CURRENT_GUEST", participant.participant_id}
    else
      _ -> {:error, :unauthorized_participant}
    end
  end

  defp mode(_, _conn), do: {:error, :invalid_mode}

  defp unavailable(conn),
    do: conn |> put_status(:not_found) |> json(%{error: %{reason: "google_continuity_disabled"}})

  defp unavailable_or_limited(conn) do
    if GoogleContinuity.enabled?(),
      do: conn |> put_status(:too_many_requests) |> json(%{error: %{reason: "rate_limited"}}),
      else: unavailable(conn)
  end

  defp disconnect_participant_sockets(participant_id) do
    StrangertalksNewWeb.Endpoint.broadcast("participant_socket:#{participant_id}", "disconnect", %{})
  end

  defp rate_allowed?(bucket, conn, limit) do
    StrangertalksNew.RateLimiter.allow?(bucket, conn.remote_ip, limit, 60)
  end

  defp accepts_json?(conn), do: "application/json" in get_req_header(conn, "accept")
end
