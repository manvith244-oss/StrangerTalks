defmodule StrangertalksNewWeb.AccountSyncController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.AccountSync
  alias StrangertalksNewWeb.{AccountController, AccountCSRF}

  def show(conn, _params),
    do:
      with_session(conn, fn session ->
        if rate_allowed?(:sync_get, session.account_id, 30) do
          case AccountSync.get(session.account_id) do
            {:ok, response} ->
              conn |> put_resp_header("cache-control", "no-store, private") |> json(response)

            {:error, reason} ->
              error(conn, reason)
          end
        else
          conn |> put_status(:too_many_requests) |> json(%{error: %{reason: "rate_limited"}})
        end
      end)

  def update(conn, %{"base_revision" => base_revision, "envelope" => envelope}),
    do:
      with_session(conn, fn session ->
        with :ok <- AccountCSRF.verify(conn, session),
             true <-
               StrangertalksNew.GoogleContinuity.RateLimiter.allow?(
                 :sync_put,
                 session.account_id,
                 30,
                 60
               ) do
          case AccountSync.put(session.account_id, base_revision, envelope) do
            {:ok, response} -> json(conn, response)
            {:error, reason} -> error(conn, reason)
          end
        else
          {:error, :forbidden} ->
            error(conn, :forbidden)

          false ->
            conn |> put_status(:too_many_requests) |> json(%{error: %{reason: "rate_limited"}})
        end
      end)

  def update(conn, _params), do: error(conn, :invalid_sync_envelope)

  def delete(conn, _params),
    do:
      with_session(conn, fn session ->
        with :ok <- AccountCSRF.verify(conn, session),
             true <- rate_allowed?(:sync_delete, session.account_id, 10) do
          case AccountSync.delete(session.account_id) do
            :ok -> send_resp(conn, :no_content, "")
            {:error, reason} -> error(conn, reason)
          end
        else
          {:error, :forbidden} ->
            error(conn, :forbidden)

          false ->
            conn |> put_status(:too_many_requests) |> json(%{error: %{reason: "rate_limited"}})
        end
      end)

  defp with_session(conn, function) do
    case AccountController.current_session(conn) do
      {:ok, session} -> function.(session)
      _ -> error(conn, :account_session_required)
    end
  end

  defp error(conn, :sync_conflict),
    do: conn |> put_status(:conflict) |> json(%{error: %{reason: "sync_conflict"}})

  defp error(conn, :sync_too_large),
    do:
      conn |> put_status(:request_entity_too_large) |> json(%{error: %{reason: "sync_too_large"}})

  defp error(conn, :google_reauthorization_required),
    do:
      conn
      |> put_status(:unauthorized)
      |> json(%{error: %{reason: "google_reauthorization_required"}})

  defp error(conn, :account_session_required),
    do: conn |> put_status(:unauthorized) |> json(%{error: %{reason: "account_session_required"}})

  defp error(conn, :forbidden),
    do: conn |> put_status(:forbidden) |> json(%{error: %{reason: "forbidden"}})

  defp error(conn, reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: %{reason: to_string(reason)}})

  defp rate_allowed?(bucket, key, limit),
    do: StrangertalksNew.GoogleContinuity.RateLimiter.allow?(bucket, key, limit, 60)
end
