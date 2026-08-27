defmodule StrangertalksNewWeb.PageController do
  use StrangertalksNewWeb, :controller

  @route_runtime_tag ~s(<script type="module" src="/assets/route_runtime.mjs?v=20260827_f02"></script>)
  @mobile_runtime_tag ~s(<script type="module" src="/assets/mobile_flow.mjs?v=20260827_f09"></script>)
  @app_bootstrap_tag ~s(<script type="module" src="/assets/flow_loading_runtime.mjs?v=20260826_f07_v1"></script>)
  @viewport_tag ~s(<meta name="viewport" content="width=device-width, initial-scale=1">)
  @mobile_viewport_tag ~s(<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">)

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
      |> String.replace(@viewport_tag, @mobile_viewport_tag)
      |> String.replace(
        @app_bootstrap_tag,
        @route_runtime_tag <> "\n    " <> @mobile_runtime_tag <> "\n    " <> @app_bootstrap_tag
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
