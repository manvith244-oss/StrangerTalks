defmodule StrangertalksNewWeb.PageControllerTest do
  use StrangertalksNewWeb.ConnCase, async: true

  test "GET / serves the plain text client without participant identifiers", %{conn: conn} do
    conn = get(conn, "/")
    body = html_response(conn, 200)

    assert body =~ "What do you need right now?"

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
    assert history =~ "<strong>Local copy</strong>"
    assert history =~ "This is not an active Conversation."
    refute history =~ "message-form"
    refute history =~ "typing"
    refute history =~ "presence"
  end

  test "top-level screens clear the navigation and kept cards expose local-copy actions" do
    static_dir = Application.app_dir(:strangertalks_new, "priv/static")
    css = File.read!(Path.join(static_dir, "assets/app.css"))
    javascript = File.read!(Path.join(static_dir, "assets/app.js"))

    assert css =~ "--bottom-nav-block-size:"
    assert css =~ ~r/env\(safe-area-inset-bottom,\s*0px\)/

    assert css =~
             ~r/\.screen\.top-level\s*\{\s*padding-bottom:\s*calc\(var\(--bottom-nav-block-size\)/

    assert javascript =~ ~s(label.textContent = "Local copy")
    assert javascript =~ ~s(open.textContent = "Open local copy")
    assert javascript =~ ~s(open.setAttribute("aria-label", `Open local copy:)

    refute javascript =~
             ~s(label.textContent = "Saved only on this device unless you export an encrypted backup.")
  end

  test "visual screen hierarchy preserves restrained matching conversation and retention controls",
       %{
         conn: conn
       } do
    body = conn |> get("/") |> html_response(200)

    [_, matching] = Regex.run(~r/(<section data-screen="queue".*?<\/section>)/s, body)
    assert matching =~ "Finding someone who chose the same space."
    assert matching =~ "Leave queue"
    refute matching =~ "queue count"
    refute matching =~ "%"
    refute matching =~ "compatibility"

    [_, conversation] = Regex.run(~r/(<section data-screen="conversation".*?<\/section>)/s, body)
    assert conversation =~ ~s(id="message-form")
    assert conversation =~ ~s(id="message-viewport")
    assert conversation =~ ~s(id="new-messages")
    assert conversation =~ ">New messages</button>"
    assert conversation =~ ~s(id="new-messages" class="new-messages" hidden)
    assert conversation =~ ~s(id="end-conversation")
    assert conversation =~ ~s(id="report-open")
    assert conversation =~ ~s(id="block")
    refute conversation =~ "read receipt"

    [_, ended] = Regex.run(~r/(<section data-screen="ended".*?<\/section>)/s, body)
    assert ended =~ "Keep this Conversation"
    assert ended =~ "Save only a summary"
    assert ended =~ "Let it fade"

    refute body =~ "<img"
    refute body =~ "avatar"
    refute body =~ "profile"
  end

  test "message timeline is bottom anchored without reversing chronological DOM order" do
    static_dir = Application.app_dir(:strangertalks_new, "priv/static")
    css = File.read!(Path.join(static_dir, "assets/app.css"))
    javascript = File.read!(Path.join(static_dir, "assets/app.js"))

    assert css =~ ~r/\.message-viewport\s*\{[^}]*overflow-y:\s*auto/s
    assert css =~ ~r/\.conversation #messages\s*\{[^}]*justify-content:\s*flex-end/s
    refute css =~ "column-reverse"

    assert javascript =~ "a.value.sent_at.localeCompare(b.value.sent_at)"
    assert javascript =~ "container.append(item)"
    assert javascript =~ "timelineNearBottom()"
    assert javascript =~ ~S|$("#new-messages").hidden = false|
  end
end
