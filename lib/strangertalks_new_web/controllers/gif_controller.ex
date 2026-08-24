defmodule StrangertalksNewWeb.GifController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.GifProvider

  def status(conn, _params) do
    json(conn, GifProvider.status())
  end

  def index(conn, %{"q" => query}) do
    case GifProvider.search(query) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, :invalid_query} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_query"})

      {:error, :provider_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "provider_unavailable"})

      {:error, :malformed_provider_response} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "provider_malformed"})

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{error: "provider_rate_limited"})

      {:error, _reason} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "provider_error"})
    end
  end

  def index(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_query"})
  end
end
