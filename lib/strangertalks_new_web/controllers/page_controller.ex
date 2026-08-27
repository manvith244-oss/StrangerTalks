defmodule StrangertalksNewWeb.PageController do
  use StrangertalksNewWeb, :controller

  @route_runtime_tag ~s(<script type="module" src="/assets/route_runtime.mjs?v=20260827_f02"></script>)
  @expression_runtime_tag ~s(<script type="module" src="/assets/expression_runtime.mjs?v=20260824_v2"></script>)

  def home(conn, _params), do: serve_client(conn)

  def saved_conversation(conn, %{"conversation_id" => conversation_id}) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, _uuid} -> serve_client(conn)
      :error -> not_found(conn)
    end
  end

  defp serve_client(conn) do
    body =
      Application.app_dir(:strangertalks_new, "priv/static/index.html")
      |> File.read!()
      |> String.replace(
        @expression_runtime_tag,
        @route_runtime_tag <> "\n    " <> @expression_runtime_tag
      )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
  end
end
