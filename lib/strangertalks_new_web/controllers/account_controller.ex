defmodule StrangertalksNewWeb.AccountController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Accounts
  alias StrangertalksNewWeb.{GoogleAuthController, ParticipantToken}

  def session(conn, _params) do
    with {:ok, account_session} <- current_session(conn) do
      participant_id = account_session.account.participant_id

      json(conn, %{
        connected: true,
        participant_id: participant_id,
        participant_token: ParticipantToken.sign(participant_id),
        capabilities: %{google_continuity: true, encrypted_sync: true}
      })
    else
      _ -> conn |> put_status(:unauthorized) |> json(%{connected: false})
    end
  end

  def logout(conn, _params) do
    with {:ok, account_session} <- current_session(conn),
         {:ok, _} <- Accounts.revoke_session(account_session) do
      conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    else
      _ -> conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    end
  end

  def logout_all(conn, _params) do
    with {:ok, account_session} <- current_session(conn),
         :ok <- Accounts.revoke_all_sessions(account_session.account_id) do
      conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    else
      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: %{reason: "account_session_required"}})
    end
  end

  def disconnect(conn, _params) do
    with {:ok, account_session} <- current_session(conn),
         :ok <- Accounts.disconnect(account_session) do
      conn |> GoogleAuthController.clear_account_cookie() |> send_resp(:no_content, "")
    else
      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: %{reason: "account_session_required"}})
    end
  end

  def current_session(conn) do
    conn = fetch_cookies(conn)
    Accounts.authenticate_session(conn.req_cookies[GoogleAuthController.cookie_name()])
  end
end
