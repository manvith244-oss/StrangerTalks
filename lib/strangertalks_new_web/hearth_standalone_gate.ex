defmodule StrangertalksNewWeb.HearthStandaloneGate do
  @moduledoc false

  import Plug.Conn

  alias StrangertalksNew.Experiments.Hearth.Runtime

  def init(opts), do: opts

  def call(conn, _opts) do
    if Runtime.standalone?() and not allowed?(conn.method, conn.path_info) do
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    else
      conn
    end
  end

  defp allowed?("GET", ["lab", "hearth"]), do: true
  defp allowed?("POST", ["api", "hearth", "participants"]), do: true

  defp allowed?("GET", ["assets", asset])
       when asset in ["hearth_lab.css", "hearth_lab.mjs"],
       do: true

  defp allowed?("GET", ["vendor", "phoenix.mjs"]), do: true
  defp allowed?(_method, _path), do: false
end
