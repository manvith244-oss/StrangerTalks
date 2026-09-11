defmodule StrangertalksNewWeb.HearthLabController do
  use StrangertalksNewWeb, :controller

  alias StrangertalksNewWeb.HearthChannel

  def show(conn, _params) do
    if HearthChannel.enabled?() do
      body =
        Application.app_dir(:strangertalks_new, "priv/static/hearth_lab.html")
        |> File.read!()

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, body)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
    end
  end
end
