defmodule StrangertalksNewWeb.PageControllerTest do
  use StrangertalksNewWeb.ConnCase, async: true

  test "GET / serves the plain text client without participant identifiers", %{conn: conn} do
    conn = get(conn, "/")
    body = html_response(conn, 200)

    assert body =~ "What would help right now?"

    assert body =~
             "Normal messages are not permanently stored on StrangerTalks servers. Messages shown during this Conversation were temporarily cached on this device. You decide whether to keep them."

    assert body =~ "Saved only on this device unless you export an encrypted backup."
    assert body =~ "/assets/app.js"
    refute body =~ "participant_id"
  end

  test "root exposes Talk Chats Bonds You and historical copies have no live controls", %{
    conn: conn
  } do
    body = conn |> get("/") |> html_response(200)

    for tab <- ["Talk", "Chats", "Bonds", "You"], do: assert(body =~ ">#{tab}</button>")

    [_, history] = Regex.run(~r/(<section data-screen="history".*?<\/section>)/s, body)
    assert history =~ "Saved on this device. This is a local copy, not an active Conversation."
    refute history =~ "message-form"
    refute history =~ "typing"
    refute history =~ "presence"
  end
end
