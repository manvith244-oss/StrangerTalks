defmodule StrangertalksNewWeb.AccountController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Accounts
  alias StrangertalksNewWeb.{AccountCSRF, GoogleAuthController, ParticipantToken}

  def session(conn, _params) do
    if StrangertalksNew.GoogleContinuity.enabled?() do
      with {:ok, account_session} <- current_session(conn),
           true <- rate_allowed?(:account_session, account_session.account_id, 60) do
        participant_id = account_session.account.participant_id

        json(conn, %{
          available: true,
          connected: true,
          participant_id: participant_id,
          participant_token: ParticipantToken.sign_account_session(account_session),
          csrf_token: AccountCSRF.token(account_session),
          continuity_id: AccountCSRF.continuity_id(account_session),
          capabilities: %{google_continuity: true, encrypted_sync: true}
        })
      else
        _ -> json(conn, %{available: true, connected: false})
      end
    else
      json(conn, %{available: false, connected: false})
    end
  end

  def logout(conn, _params) do
    with {:ok, account_session} <- current_session(conn),
         :ok <- AccountCSRF.verify(conn, account_session),
         {:ok, _} <- Accounts.revoke_session(account_session) do
      disconnect_participant_sockets(account_session.account.participant_id)
      conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    else
      {:error, :forbidden} -> forbidden(conn)
      _ -> conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    end
  end

  def logout_all(conn, _params) do
    with {:ok, account_session} <- current_session(conn),
         :ok <- AccountCSRF.verify(conn, account_session),
         :ok <- Accounts.revoke_all_sessions(account_session.account_id) do
      disconnect_participant_sockets(account_session.account.participant_id)
      conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    else
      {:error, :forbidden} ->
        forbidden(conn)

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: %{reason: "account_session_required"}})
    end
  end

  def disconnect(conn, _params) do
    with {:ok, account_session} <- current_session(conn),
         true <- rate_allowed?(:disconnect, account_session.account_id, 10),
         :ok <- AccountCSRF.verify(conn, account_session),
         :ok <- Accounts.disconnect(account_session) do
      disconnect_participant_sockets(account_session.account.participant_id)
      conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    else
      {:error, :google_revocation_failed} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{reason: "google_revocation_failed"}})

      {:error, :forbidden} ->
        forbidden(conn)

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: %{reason: "account_session_required"}})
    end
  end

  def current_session(conn) do
    conn = fetch_cookies(conn)
    Accounts.authenticate_session(conn.req_cookies[GoogleAuthController.cookie_name()])
  end

  defp disconnect_participant_sockets(participant_id) do
    StrangertalksNewWeb.Endpoint.broadcast("participant_socket:#{participant_id}", "disconnect", %{})
  end

  defp rate_allowed?(bucket, key, limit),
    do: StrangertalksNew.RateLimiter.allow?(bucket, key, limit, 60)

  defp forbidden(conn),
    do: conn |> put_status(:forbidden) |> json(%{error: %{reason: "forbidden"}})
end
