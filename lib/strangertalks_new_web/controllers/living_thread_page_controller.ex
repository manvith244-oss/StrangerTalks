defmodule StrangertalksNewWeb.LivingThreadPageController do
  use StrangertalksNewWeb, :controller

  def show(conn, _params) do
    body =
      Application.app_dir(:strangertalks_new, "priv/static/living-thread.html")
      |> File.read!()

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, body)
  end
end
