defmodule StrangertalksNewWeb.RouteArchitectureTest do
  use StrangertalksNewWeb.ConnCase, async: true

  @canonical_static_routes [
    "/",
    "/matchmaking",
    "/conversation",
    "/conversation/ended",
    "/conversation/unavailable",
    "/chats",
    "/bonds",
    "/you",
    "/you/memories",
    "/you/reflections"
  ]

  test "every frozen canonical static route serves the StrangerTalks client shell with F-02 routing before app bootstrap" do
    Enum.each(@canonical_static_routes, fn path ->
      conn = get(build_conn(), path)
      body = html_response(conn, 200)

      assert body =~ "StrangerTalks"
      assert body =~ ~s(data-screen="doors")
      assert body =~ ~s(data-screen="conversation")
      assert body =~ ~s(src="/assets/route_runtime.mjs?v=20260827_f02")

      {route_position, _} = :binary.match(body, "/assets/route_runtime.mjs")
      {app_boot_position, _} = :binary.match(body, "/assets/expression_runtime.mjs")
      assert route_position < app_boot_position
    end)
  end

  test "saved Conversation detail is directly servable when its route parameter is structurally valid" do
    conversation_id = Ecto.UUID.generate()
    conn = get(build_conn(), "/chats/#{conversation_id}")
    body = html_response(conn, 200)

    assert body =~ "StrangerTalks"
    assert body =~ ~s(data-screen="history")
  end

  test "malformed saved Conversation ids are deterministic 404s" do
    conn = get(build_conn(), "/chats/not-a-uuid")
    assert response(conn, 404) == "Not Found"
  end

  test "unknown URLs are not silently rewritten to Talk" do
    conn = get(build_conn(), "/not-a-strangertalks-route")
    assert response(conn, 404) =~ "Not Found"
  end

  test "OAuth callback failures return to canonical You rather than root" do
    conn = get(build_conn(), "/auth/google/callback")

    assert redirected_to(conn, 302) == "/you?account=google_connection_failed"
  end
end
