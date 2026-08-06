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

    [_, navigation] = Regex.run(~r/(<nav id="bottom-nav".*?<\/nav>)/s, body)

    assert Regex.scan(~r/<button[^>]*>([^<]+)<\/button>/, navigation, capture: :all_but_first) ==
             [["Talk"], ["Chats"], ["Bonds"], ["You"]]

    [_, chats] = Regex.run(~r/(<section data-screen="chats".*?<\/section>)/s, body)
    assert chats =~ "<h1>Chats</h1>"

    [_, history] = Regex.run(~r/(<section data-screen="history".*?<\/section>)/s, body)
    assert history =~ "Saved on this device. This is a local copy, not an active Conversation."
    refute history =~ "message-form"
    refute history =~ "typing"
    refute history =~ "presence"
  end

  test "top-level screens clear the navigation and kept cards expose local-copy actions" do
    static_dir = Application.app_dir(:strangertalks_new, "priv/static")
    css = File.read!(Path.join(static_dir, "assets/app.css"))
    javascript = File.read!(Path.join(static_dir, "assets/app.js"))

    assert css =~ "--bottom-nav-block-size:"
    assert css =~ "env(safe-area-inset-bottom,0px)"
    assert css =~ ".screen.top-level{padding-bottom:calc(var(--bottom-nav-block-size)"

    assert javascript =~ ~s(label.textContent = "Local copy")
    assert javascript =~ ~s(open.textContent = "Open local copy")
    assert javascript =~ ~s(open.setAttribute("aria-label", `Open local copy:)

    refute javascript =~
             ~s(label.textContent = "Saved only on this device unless you export an encrypted backup.")
  end
end
