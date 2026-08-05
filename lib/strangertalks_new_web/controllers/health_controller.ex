defmodule StrangertalksNewWeb.HealthController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNew.Repo

  def live(conn, _params), do: json(conn, %{status: "live"})

  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        json(conn, %{status: "ready"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "not_ready"})
    end
  rescue
    _exception -> conn |> put_status(:service_unavailable) |> json(%{status: "not_ready"})
  catch
    :exit, _reason -> conn |> put_status(:service_unavailable) |> json(%{status: "not_ready"})
  end
end
