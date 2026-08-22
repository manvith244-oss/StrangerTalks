import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {
  ICEBREAKER_CATALOG, applyIcebreakerSnapshot, approvedIcebreaker, dismissIcebreaker,
  initialIcebreakerState, resetIcebreakerState, visibleIcebreaker
} from "../../priv/static/assets/icebreakers.mjs"

const APP_PATH = "priv/static/assets/app.js"
const CSS_PATH = "priv/static/assets/app.css"
const HTML_PATH = "priv/static/index.html"
const SERVER_PATH = "lib/strangertalks_new/conversation_lifecycle/conversation_server.ex"
const CHANNEL_PATH = "lib/strangertalks_new_web/conversation_channel.ex"
const CATALOG_PATH = "lib/strangertalks_new/icebreaker_catalog.ex"

test("1K catalog is bounded first-party content mirrored exactly across server and browser", async () => {
  assert.equal(ICEBREAKER_CATALOG.length, 7)
  assert.equal(new Set(ICEBREAKER_CATALOG.map(({id}) => id)).size, 7)
  for (const item of ICEBREAKER_CATALOG) {
    assert.equal(approvedIcebreaker(item.id), item)
    assert.equal(typeof item.text, "string")
    assert.ok(item.text.length > 0)
  }
  assert.equal(approvedIcebreaker("<script>alert(1)</script>"), null)
  assert.equal(approvedIcebreaker("https://example.invalid/bridge"), null)

  const serverCatalog = await readFile(CATALOG_PATH, "utf8")
  for (const {id, text} of ICEBREAKER_CATALOG) {
    assert.ok(serverCatalog.includes(`"${id}"`))
    assert.ok(serverCatalog.includes(JSON.stringify(text)))
  }
})

test("1K ACTIVE snapshot renders approved content and has no message identity or lifecycle", () => {
  const state = applyIcebreakerSnapshot(initialIcebreakerState(), {
    status: "active",
    identity: "ocean-or-space"
  })
  assert.deepEqual(state, {
    canonicalStatus: "active",
    identity: "ocean-or-space",
    localDismissed: false
  })
  assert.equal(visibleIcebreaker(state)?.text, "Would you rather explore the ocean or outer space?")
  assert.equal("client_message_id" in state, false)
  assert.equal("sequence" in state, false)
  assert.equal("delivery_status" in state, false)
  assert.equal("revision" in state, false)
})

test("1K unknown identity and unavailable catalog fail closed while Conversation remains usable", () => {
  const unknown = applyIcebreakerSnapshot(initialIcebreakerState(), {
    status: "active",
    identity: "<img src=x onerror=alert(1)>"
  })
  assert.equal(unknown.canonicalStatus, "unavailable")
  assert.equal(visibleIcebreaker(unknown), null)
  assert.equal(visibleIcebreaker(applyIcebreakerSnapshot(unknown, null)), null)
})

test("1K local dismiss hides one tab without changing canonical ACTIVE", () => {
  const active = applyIcebreakerSnapshot(initialIcebreakerState(), {
    status: "active",
    identity: "small-comfort"
  })
  const dismissed = dismissIcebreaker(active)
  assert.equal(dismissed.canonicalStatus, "active")
  assert.equal(dismissed.identity, active.identity)
  assert.equal(dismissed.localDismissed, true)
  assert.equal(visibleIcebreaker(dismissed), null)
})

test("1K sync reconcile preserves local dismiss while ACTIVE and RETIRED always wins", () => {
  const active = applyIcebreakerSnapshot(initialIcebreakerState(), {
    status: "active",
    identity: "ordinary-meaning"
  })
  const dismissed = dismissIcebreaker(active)
  const reconciledActive = applyIcebreakerSnapshot(dismissed, {
    status: "active",
    identity: "ordinary-meaning"
  })
  assert.equal(reconciledActive.localDismissed, true)
  assert.equal(reconciledActive.canonicalStatus, "active")
  assert.equal(visibleIcebreaker(reconciledActive), null)

  const retired = applyIcebreakerSnapshot(reconciledActive, {status: "retired"})
  assert.equal(retired.canonicalStatus, "retired")
  assert.equal(retired.identity, null)
  assert.equal(visibleIcebreaker(retired), null)

  const attemptedResurrection = applyIcebreakerSnapshot(retired, {status: "retired"})
  assert.equal(visibleIcebreaker(attemptedResurrection), null)
})

test("1K reconcile restores genuinely ACTIVE missing presentation when not locally dismissed", () => {
  const restored = applyIcebreakerSnapshot(initialIcebreakerState(), {
    status: "active",
    identity: "instant-skill"
  })
  assert.equal(restored.localDismissed, false)
  assert.equal(visibleIcebreaker(restored)?.id, "instant-skill")
})

test("1K sibling tabs are independent and refresh clears only local dismissal", () => {
  const snapshot = {status: "active", identity: "new-city-afternoon"}
  const tabA1 = dismissIcebreaker(applyIcebreakerSnapshot(initialIcebreakerState(), snapshot))
  const tabA2 = applyIcebreakerSnapshot(initialIcebreakerState(), snapshot)
  assert.equal(visibleIcebreaker(tabA1), null)
  assert.equal(visibleIcebreaker(tabA2)?.id, snapshot.identity)

  const refreshedA1 = applyIcebreakerSnapshot(resetIcebreakerState(), snapshot)
  assert.equal(refreshedA1.localDismissed, false)
  assert.equal(visibleIcebreaker(refreshedA1)?.id, snapshot.identity)
  assert.equal(visibleIcebreaker(applyIcebreakerSnapshot(resetIcebreakerState(), {status: "retired"})), null)
})

test("1K dismissal is zero-network and cannot mutate composer Reply or 1J Prompt state", async () => {
  const appSource = await readFile(APP_PATH, "utf8")
  const start = appSource.indexOf("function locallyDismissIcebreaker()")
  const end = appSource.indexOf("\nfunction resetIcebreaker()", start)
  const dismissOwner = appSource.slice(start, end)
  assert.ok(start >= 0 && end > start)
  assert.equal(/push\(|message-input[^)]*\.value|replyState\s*=|promptCards\s*=/.test(dismissOwner), false)
  assert.match(dismissOwner, /message-input[^\n]*focus/)
  assert.match(appSource, /conversation:icebreaker/)
  assert.equal(/icebreaker:(dismiss|select|skip|vote|answer|next)/.test(appSource), false)
})

test("1K markup is small accessible non-modal UI and CSS preserves touch small-screen and forced-color use", async () => {
  const [html, css] = await Promise.all([readFile(HTML_PATH, "utf8"), readFile(CSS_PATH, "utf8")])
  assert.match(html, /<aside id="icebreaker-card"[^>]*aria-labelledby="icebreaker-title"[^>]*hidden>/)
  assert.match(html, /id="icebreaker-text"/)
  assert.match(html, /id="icebreaker-dismiss" type="button"[^>]*aria-label="Hide this Ice Breaker in this tab"/)
  assert.equal(/icebreaker[^>]*(role="dialog"|aria-modal="true")/.test(html), false)
  assert.match(css, /#icebreaker-dismiss[\s\S]*min-height:\s*2\.75rem/)
  assert.match(css, /@media \(max-width: 40rem\)[\s\S]*\.icebreaker-card/)
  assert.match(css, /@media \(forced-colors: active\)[\s\S]*\.icebreaker-card/)
  assert.match(css, /body\.reduce-motion \*[^{]*\{[^}]*animation:\s*none !important/)
})

test("1K JOIN and sync share canonical truth while retirement listens independently of message rendering", async () => {
  const [appSource, serverSource, channelSource] = await Promise.all([
    readFile(APP_PATH, "utf8"),
    readFile(SERVER_PATH, "utf8"),
    readFile(CHANNEL_PATH, "utf8")
  ])
  assert.match(serverSource, /calculate_sync_payload[\s\S]*icebreaker_snapshot/)
  assert.match(serverSource, /get_messages_after[\s\S]*icebreaker:\s*icebreaker_snapshot/)
  assert.match(channelSource, /conversation_icebreaker[\s\S]*conversation:icebreaker/)
  assert.match(appSource, /applySyncPayload[\s\S]*applyCanonicalIcebreaker\(syncPayload\.icebreaker\)/)
  assert.match(appSource, /conversation\.on\("conversation:icebreaker", applyCanonicalIcebreaker\)/)
})

test("1K retirement covers every current human timeline representation and excludes operational owners", async () => {
  const server = await readFile(SERVER_PATH, "utf8")
  const ordinaryAcceptance = server.slice(server.indexOf("defp accept_or_replay_message"), server.indexOf("defp resolve_reply_context"))
  const voiceAcceptance = server.slice(server.indexOf("defp accept_or_replay_voice_note"), server.indexOf("defp voice_idempotent_result"))
  assert.match(ordinaryAcceptance, /append_recent_message\(state, replay_entry\)[\s\S]*retire_icebreaker\(state\)/)
  assert.match(voiceAcceptance, /append_recent_message\(state, replay_entry\)[\s\S]*retire_icebreaker\(state\)/)
  for (const owner of ["mutate_reaction", "mutate_pin", "report_delivery_progress", "update_session_visibility", "sync_and_register_channel", "get_messages_after", "typing"]) {
    const ownerStart = server.indexOf(`{:${owner}`)
    if (ownerStart >= 0) {
      const ownerEnd = server.indexOf("\n  def handle_call", ownerStart + 10)
      assert.equal(server.slice(ownerStart, ownerEnd < 0 ? undefined : ownerEnd).includes("retire_icebreaker"), false)
    }
  }
})

test("1K adds no behavioral analytics persistence provider history or content-bearing diagnostics", async () => {
  const [appSource, serverSource, channelSource, catalogSource] = await Promise.all([
    readFile(APP_PATH, "utf8"), readFile(SERVER_PATH, "utf8"),
    readFile(CHANNEL_PATH, "utf8"), readFile(CATALOG_PATH, "utf8")
  ])
  const icebreakerBrowser = appSource.match(/function renderIcebreakerUI[\s\S]*?function resetIcebreaker\(\)[\s\S]*?\n}/)?.[0] || ""
  const icebreakerServer = serverSource.match(/defp retire_icebreaker[\s\S]*?defp retire_icebreaker\(state\), do: state/)?.[0] || ""
  for (const source of [icebreakerBrowser, icebreakerServer, catalogSource]) {
    assert.equal(/console\.|Logger\.|Telemetry|localStorage|indexedDB|putRecord|Repo\.|HTTP|(?:window|globalThis)\.fetch|fetch\(\s*["']https?:|profile|transcript|view_duration|response_classification/i.test(source), false)
  }
  assert.equal(/handle_in\("icebreaker:/.test(channelSource), false)
  assert.equal(/icebreaker_(revision|sequence|client_message_id)|server_sequence|answer_state|vote_state|selection_state/i.test(serverSource), false)
})
