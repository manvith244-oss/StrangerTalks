defmodule StrangertalksNewWeb.PageControllerTest do
  use StrangertalksNewWeb.ConnCase, async: true

  test "GET / serves the plain text client without participant identifiers", %{conn: conn} do
    conn = get(conn, "/")
    body = html_response(conn, 200)

    flow_runtime =
      File.read!(
        Application.app_dir(:strangertalks_new, "priv/static/assets/flow_loading_runtime.mjs")
      )

    assert body =~ "What do you need right now?"

    assert body =~
             "Normal messages are not permanently stored on StrangerTalks servers. Messages shown during this Conversation were temporarily cached on this device. You decide whether to keep them."

    assert body =~ "Saved only on this device unless you export an encrypted backup."
    assert body =~ "/assets/flow_loading_runtime.mjs"
    refute body =~ ~r/<script[^>]+src="\/assets\/expression_runtime\.mjs/

    assert flow_runtime =~
             ~S|const APP_ENTRY = "/assets/expression_runtime.mjs?v=20260824_v2"|

    assert body =~ "/assets/expression_surface.css"
    refute body =~ ~r/<script[^>]+src="\/assets\/app\.js/
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

    static_dir = Application.app_dir(:strangertalks_new, "priv/static")
    loading = File.read!(Path.join(static_dir, "assets/flow_loading.mjs"))

    [_, matching] = Regex.run(~r/(<section data-screen="queue".*?<\/section>)/s, body)
    assert matching =~ "Starting matchmaking…"
    assert matching =~ "Confirming your place in the queue."
    refute matching =~ "Finding someone…"
    assert loading =~ "Finding someone…"
    assert loading =~ "Looking for someone compatible with your choice."
    assert matching =~ "Leave Queue"

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
    # "No profile required" is intentional reassurance copy, not a profile feature.
    reassurance = "Anonymous, one-to-one conversation with another person. No profile required."
    assert body =~ reassurance

    refute String.replace(body, reassurance, "") =~
             ~r/profile|avatar|user[\s_-]*name|(?:^|[^a-z])bio(?:$|[^a-z])|public[\s_-]*presence/i
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

  test "voice recording is explicit and remains absent from historical local copies", %{
    conn: conn
  } do
    body = conn |> get("/") |> html_response(200)
    [_, conversation] = Regex.run(~r/(<section data-screen="conversation".*?<\/section>)/s, body)
    [_, history] = Regex.run(~r/(<section data-screen="history".*?<\/section>)/s, body)
    javascript = File.read!(Application.app_dir(:strangertalks_new, "priv/static/assets/app.js"))

    assert conversation =~ ~s(id="voice-start")
    assert conversation =~ "Your voice may reveal personal details"
    assert conversation =~ "Voice notes are delivered temporarily through StrangerTalks"
    assert body =~ ~s(id="voice-preview-audio" controls)
    refute body =~ ~r/<audio[^>]*autoplay/
    refute conversation =~ ~s(type="file")
    refute history =~ "voice-start"
    refute history =~ "message-form"
    assert javascript =~ "URL.revokeObjectURL"
    assert javascript =~ "navigator.mediaDevices.getUserMedia"
  end

  test "Bonds offer private mutual reconnection without social-presence disclosure", %{conn: conn} do
    body = conn |> get("/") |> html_response(200)
    javascript = File.read!(Application.app_dir(:strangertalks_new, "priv/static/assets/app.js"))
    [_, bonds] = Regex.run(~r/(<section data-screen="relationships".*?<\/section>)/s, body)

    assert bonds =~ "visible only to you"
    assert javascript =~ "Reconnect privately"
    assert javascript =~ "What kind of Conversation do you need right now?"
    assert javascript =~ "Available to reconnect for 15 minutes."
    assert javascript =~ "They will never know unless they choose the same."
    assert javascript =~ ~s("bond:reconnect_status")
    assert javascript =~ ~s("bond:reconnect_cancel")
    assert javascript =~ ~s("bond:reconnect_start")
    refute javascript =~ "Request sent"
    refute javascript =~ "Waiting for them"
    refute bonds =~ "online"
    refute bonds =~ "last seen"
    refute bonds =~ "participant_id"
  end

  test "Bond matched responses and pushes share the existing Conversation transition" do
    javascript = File.read!(Application.app_dir(:strangertalks_new, "priv/static/assets/app.js"))

    assert javascript =~ ~S|app.participant.on("match_found", (payload) => {|
    assert javascript =~ ~S|navigation.activityEvent("match_found")|
    assert javascript =~ ~S|handleMatchedConversation(payload)|

    assert javascript =~
             ~S|if (state.status === "matched") await handleMatchedConversation(state, relationshipId)|

    assert javascript =~
             "async function handleMatchedConversation(payload, relationshipId = null)"

    assert javascript =~ "await ensureTemporaryConversation(conversationId)"
    assert javascript =~ ~S|announce("Reconnecting to the Conversation…")|

    refute javascript =~
             ~S|if (state.status === "matched") renderReconnectState(container, state)|
  end

  test "guest-first private continuity and encrypted sync controls explain their boundaries", %{
    conn: conn
  } do
    body = conn |> get("/") |> html_response(200)
    javascript = File.read!(Application.app_dir(:strangertalks_new, "priv/static/assets/app.js"))

    [_, settings] =
      Regex.run(~r/(<section data-screen="settings".*?<section data-screen="memories")/s, body)

    assert settings =~ "Continue across devices"
    assert settings =~ "Connect this guest privately"
    assert settings =~ "Use an existing private account"
    assert settings =~ "Connected privately."
    assert settings =~ "Voice notes remain on the device where they were kept."
    assert settings =~ "Sync now"
    assert settings =~ "Restore from Google"
    assert settings =~ "Delete Google sync data"
    assert settings =~ "Sign out on this device"
    assert settings =~ "Sign out all devices"
    assert settings =~ "Disconnect Google"
    assert settings =~ ~s(id="continuity-suggestion" class="card" hidden)
    refute settings =~ "Google email"
    refute settings =~ "Google profile"
    assert javascript =~ ~s(headers.authorization = `Bearer ${app.identity.token}`)
    assert javascript =~ ~S|fetch("/api/account/session", {credentials: "same-origin"})|
    assert javascript =~ "syncableRecords(await listRecords())"
    assert javascript =~ "unlockSync(remote.envelope"
    assert javascript =~ "decryptSyncWithKey(remote.envelope"
    assert javascript =~ "Existing kept local data will remain"
  end
end
