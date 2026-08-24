defmodule StrangertalksNewWeb.PageController do
  use StrangertalksNewWeb, :controller

  def home(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:strangertalks_new, "priv/static/index.html"))
  end
end
