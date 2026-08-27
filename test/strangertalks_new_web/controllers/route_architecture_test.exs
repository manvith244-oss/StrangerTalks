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

  @rejected_aliases [
    "/matching",
    "/settings",
    "/settings/memories",
    "/talk",
    "/home",
    "/language",
    "/door",
    "/match-found",
    "/conversation/123"
  ]

  test "every frozen canonical static route serves the StrangerTalks client shell with F-02 routing before the current app bootstrap" do
    Enum.each(@canonical_static_routes, fn path ->
      conn = get(build_conn(), path)
      body = html_response(conn, 200)

      assert body =~ "StrangerTalks"
      assert body =~ ~s(data-screen="doors")
      assert body =~ ~s(data-screen="conversation")
      assert body =~ ~s(src="/assets/route_runtime.mjs?v=20260827_f02")
      assert body =~ ~s(src="/assets/flow_loading_runtime.mjs?v=20260826_f07_v1")

      {route_position, _} = :binary.match(body, "/assets/route_runtime.mjs")
      {app_boot_position, _} = :binary.match(body, "/assets/flow_loading_runtime.mjs")
      assert route_position < app_boot_position
    end)
  end

  test "one trailing slash still serves the shell so the client can canonicalize it" do
    conn = get(build_conn(), "/you/")
    body = html_response(conn, 200)

    assert body =~ "StrangerTalks"
    assert body =~ ~s(src="/assets/route_runtime.mjs?v=20260827_f02")
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

  test "saved Conversation validation is path-scoped and does not hijack unrelated query parameters" do
    conn = get(build_conn(), "/you?conversation_id=not-a-uuid")
    assert html_response(conn, 200) =~ "StrangerTalks"
  end

  test "unknown URLs, rejected aliases, and active Conversation identity URLs do not become Talk" do
    active_id_route = "/conversation/#{Ecto.UUID.generate()}"

    Enum.each(["/not-a-strangertalks-route", active_id_route | @rejected_aliases], fn path ->
      conn = get(build_conn(), path)
      assert response(conn, 404) =~ "Not Found"
    end)
  end

  test "OAuth callback failures return to canonical You rather than root" do
    conn = get(build_conn(), "/auth/google/callback")

    assert redirected_to(conn, 302) == "/you?account=google_connection_failed"
  end
end
