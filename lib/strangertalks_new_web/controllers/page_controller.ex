defmodule StrangertalksNewWeb.PageController do
  use StrangertalksNewWeb, :controller

  @app_script ~s(<script type="module" src="/assets/app.js?v=20260807_v2"></script>)
  @expression_script ~s(<script type="module" src="/assets/expression_runtime.mjs?v=20260824_v1" data-app-entry="/assets/app.js?v=20260807_v2"></script>)
  @expression_css ~s(<link rel="stylesheet" href="/assets/expression_surface.css?v=20260824_v1">)

  def home(conn, _params) do
    html =
      :strangertalks_new
      |> Application.app_dir("priv/static/index.html")
      |> File.read!()
      |> String.replace("</head>", @expression_css <> "\n  </head>", global: false)
      |> String.replace(@app_script, @expression_script, global: false)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
