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

  test "every frozen canonical static route serves the StrangerTalks client shell" do
    Enum.each(@canonical_static_routes, fn path ->
      conn = get(build_conn(), path)
      body = html_response(conn, 200)

      assert body =~ "StrangerTalks"
      assert body =~ ~s(data-screen="doors")
      assert body =~ ~s(data-screen="conversation")
    end)
  end

  test "saved Conversation detail is directly servable without making Phoenix own local-history validation" do
    conversation_id = Ecto.UUID.generate()
    conn = get(build_conn(), "/chats/#{conversation_id}")
    body = html_response(conn, 200)

    assert body =~ "StrangerTalks"
    assert body =~ ~s(data-screen="history")
  end

  test "unknown URLs are not silently rewritten to Talk" do
    assert_error_sent 404, fn ->
      get(build_conn(), "/not-a-strangertalks-route")
    end
  end
end
