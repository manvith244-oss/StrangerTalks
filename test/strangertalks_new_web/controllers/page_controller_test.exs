defmodule StrangertalksNewWeb.PageControllerTest do
  use StrangertalksNewWeb.ConnCase, async: true

  test "GET / serves the plain text client without participant identifiers", %{conn: conn} do
    conn = get(conn, "/")
    body = html_response(conn, 200)

    assert body =~ "A quiet place to talk."
    assert body =~ "Memory Space"
    assert body =~ "/assets/app.js"
    refute body =~ "participant_id"
  end
end
