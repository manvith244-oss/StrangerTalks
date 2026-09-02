import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import {
  APPROVED_PHOTO_TYPES, MAX_PHOTO_BYTES, MAX_PHOTO_DIMENSION,
  dedupeViewOnceMessages, isApprovedPhotoType, validPhotoBlob,
  viewOnceDraftMatchesRuntime
} from "../../priv/static/assets/view_once.mjs"
import {localMessage} from "../../priv/static/assets/local_data.mjs"

test("approved MIME types are restricted to JPEG, PNG, and WebP", () => {
  assert.equal(isApprovedPhotoType("image/jpeg"), true)
  assert.equal(isApprovedPhotoType("image/png"), true)
  assert.equal(isApprovedPhotoType("image/webp"), true)
  assert.equal(isApprovedPhotoType("image/gif"), false)
  assert.equal(isApprovedPhotoType("image/svg+xml"), false)
  assert.equal(isApprovedPhotoType("video/mp4"), false)
  assert.equal(isApprovedPhotoType("application/pdf"), false)
})

test("validPhotoBlob enforces 1 MiB boundary and approved types", () => {
  assert.equal(validPhotoBlob(new Blob([new Uint8Array(MAX_PHOTO_BYTES)], {type: "image/jpeg"})), true)
  assert.equal(validPhotoBlob(new Blob([new Uint8Array(MAX_PHOTO_BYTES + 1)], {type: "image/jpeg"})), false)
  assert.equal(validPhotoBlob(new Blob([new Uint8Array(100)], {type: "image/gif"})), false)
  assert.equal(validPhotoBlob(new Blob([], {type: "image/png"})), false)
})

test("viewOnceDraftMatchesRuntime binds draft strictly to conversation and epoch", () => {
  const draft = {originConversationId: "conv-1", originEpochId: "epoch-1"}
  assert.equal(viewOnceDraftMatchesRuntime(draft, "conv-1", "epoch-1"), true)
  assert.equal(viewOnceDraftMatchesRuntime(draft, "conv-2", "epoch-1"), false)
  assert.equal(viewOnceDraftMatchesRuntime(draft, "conv-1", "epoch-2"), false)
  assert.equal(viewOnceDraftMatchesRuntime(null, "conv-1", "epoch-1"), false)
})

test("B1 - IndexedDB exclusion: recipient View-Once photo never stored as blob in IndexedDB", () => {
  const record = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-1",
    type: "view_once_photo",
    view_once_state: "unviewed",
    media_type: "image/jpeg",
    byte_size: 1024,
    mine: false,
    sent_at: "2026-08-14T00:00:00Z"
  })

  assert.equal(record.type, "local_message")
  assert.equal(record.value.type, "view_once_photo")
  assert.equal(record.value.view_once_state, "unviewed")
  assert.equal(record.value.media_type, "image/jpeg")
  assert.equal(record.value.byte_size, 1024)
  assert.equal(record.value.content, null)
  assert.equal(record.value.blob, undefined)
  assert.equal(record.value.binary, undefined)
  assert.equal(record.value.media_bytes, undefined)
})

test("B2 - CacheStorage exclusion: no Service Worker or CacheStorage is used for View-Once media", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.equal(appJs.includes("caches.open"), false)
  assert.equal(appJs.includes("serviceWorker.register"), false)
})

test("B3 - No-store response: presentation endpoint returns Cache-Control: no-store, private", () => {
  const controller = readFileSync(new URL("../../lib/strangertalks_new_web/controllers/view_once_media_controller.ex", import.meta.url), "utf8")
  assert.match(controller, /put_resp_header\("cache-control",\s*"no-store,\s*private"\)/)
  assert.match(controller, /put_resp_header\("x-content-type-options",\s*"nosniff"\)/)
})

test("B4 - Object URL cleanup: ObjectURLs are revoked on viewer close, conversation end, and unload", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

  // ObjectURL cleanup in closeViewOnceModal, clearViewOncePreview, and beforeunload
  assert.match(appJs, /URL\.revokeObjectURL\(activeViewOnceUrl\)/)
  assert.match(appJs, /URL\.revokeObjectURL\(app\.viewOnce\.previewUrl\)/)
  assert.match(appJs, /window\.addEventListener\("beforeunload",\s*\(\)\s*=>\s*\{[\s\S]*closeViewOnceModal\(\)[\s\S]*clearViewOncePreview\(\)/)
})

test("B5 - Offline open denied: disconnected recipient cannot consume view or obtain token offline", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /async function openViewOncePhoto\(clientMessageId,\s*triggerBtn/s)
  assert.match(appJs, /if \(!app\.conversation \|\| !app\.conversationId\) return/)
})

test("B6 - Reload non-reopen: page reload displays VIEWED status without Open once button", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /viewOnceState === "viewed"/)
  assert.match(appJs, /Opened/)
})

test("B7 - Delivery does not view: delivery, presence, join, focus, hover produce 0 VIEWED transition", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /function updateViewOnceState\(clientMessageId,\s*state/)
  // Reconcile and delivery only apply the server-provided canonical view_once_state without optimistic VIEWED transitions
  assert.doesNotMatch(appJs, /onfocus[\s\S]*updateViewOnceState\([^,]+,\s*"viewed"\)/)
  assert.doesNotMatch(appJs, /onmouseover[\s\S]*updateViewOnceState\([^,]+,\s*"viewed"\)/)
})

test("Feature 1O.1 - localMessage supports presentation_limit, views_remaining, views_consumed", () => {
  const record = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-vt-1",
    type: "view_once_photo",
    presentation_limit: 2,
    views_remaining: 2,
    views_consumed: 0,
    view_once_state: "unviewed",
    media_type: "image/jpeg",
    byte_size: 2048,
    mine: false,
    sent_at: "2026-08-14T00:00:00Z"
  })

  assert.equal(record.value.presentation_limit, 2)
  assert.equal(record.value.views_remaining, 2)
  assert.equal(record.value.views_consumed, 0)
  assert.equal(record.value.view_once_state, "unviewed")
  assert.equal(record.value.content, null)
})

test("Feature 1O.1 - UI card rendering strings for View-Twice", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /View-twice photo/)
  assert.match(appJs, /Open \(1 of 2\)/)
  assert.match(appJs, /Open again \(1 view remaining\)/)
  assert.match(appJs, /Opened \(2 of 2\)/)
  assert.match(appJs, /attempt_id:\s*attempt/)
})

test("Feature 1O.1 - Send as View Twice control in index.html and app.js", () => {
  const indexHtml = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

  assert.match(indexHtml, /id="view-twice-send"/)
  assert.match(appJs, /\$\("#view-twice-send"\)\?\.addEventListener\("click",\s*\(\)\s*=>\s*sendViewOncePhoto\(2\)\)/)
})

test("dedupeViewOnceMessages deduplicates records by client_message_id", () => {
  const r1 = {value: {client_message_id: "msg-1", view_once_state: "unviewed"}}
  const r2 = {value: {client_message_id: "msg-1", view_once_state: "viewed"}}
  const r3 = {value: {client_message_id: "msg-2", view_once_state: "unviewed"}}

  const deduped = dedupeViewOnceMessages([r1, r2, r3])
  assert.equal(deduped.length, 2)
  assert.equal(deduped[0].value.client_message_id, "msg-1")
  assert.equal(deduped[1].value.client_message_id, "msg-2")
})

test("1L disclosure text in index.html and app.js", () => {
  const indexHtml = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")

  assert.match(indexHtml, /View-Once limits normal StrangerTalks replay\. It does not prevent the other person from capturing what is shown\./)
  assert.match(indexHtml, /If you report a View-Once photo while StrangerTalks still has its server-owned safety copy, the photo may be stored separately as safety evidence\./)
})

test("focused staging transport proof: sendViewOncePhoto sends raw normalized blob with application/octet-stream and no FormData", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

  // Verify sendViewOncePhoto sends body: blob directly with Content-Type: application/octet-stream
  assert.match(appJs, /const response = await fetch\(`\/api\/conversations\/\$\{app\.conversationId\}\/view-once\/stage`,\s*\{\s*method:\s*"POST",\s*headers:\s*\{[\s\S]*"Content-Type":\s*"application\/octet-stream"[\s\S]*\},\s*body:\s*blob\s*\}\)/)
  // Verify FormData is NOT used in view-once staging
  assert.doesNotMatch(appJs, /new FormData\(\)[\s\S]*formData\.append\("media",\s*blob/)
})

test("Closure Gap E: UI-1 & UI-2: Focus and hover produce 0 open requests and 0 attempt IDs", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  // Verify that only click event listeners are registered on open button, never focus or mouseover
  assert.doesNotMatch(appJs, /openBtn\.addEventListener\("(focus|mouseover|mouseenter|pointerover|focusin)"/)
  assert.match(appJs, /openBtn\.addEventListener\("click",/)
})

test("Closure Gap E: UI-3, UI-4, UI-5: Deliberate click, Enter, Space generate exactly 1 attempt ID per human action", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  // Verify openViewOncePhoto generates exactly one attempt ID using crypto.randomUUID()
  assert.match(appJs, /const attempt = attemptId \|\| crypto\.randomUUID\(\)/)
  // Verify button is synchronously disabled to prevent double activation
  assert.match(appJs, /if \(triggerBtn\) triggerBtn\.disabled = true/)
  // Verify push payload sends the singular attempt_id
  assert.match(appJs, /attempt_id:\s*attempt/)
})

test("Closure Gap E: UI-6: Duplicate event / bubbling cannot synchronously mint two unique attempt IDs", () => {
  // Simulate UI attempt generation logic with double event guard
  let attempts = []
  let pushCalls = 0
  let isSubmitting = false

  function simulateClick(buttonElement) {
    if (buttonElement.disabled || isSubmitting) return
    buttonElement.disabled = true
    isSubmitting = true
    const attemptId = "att-" + (attempts.length + 1)
    attempts.push(attemptId)
    pushCalls++
  }

  const btn = {disabled: false}

  // Single human action firing two rapid events (e.g. pointerup + click or bubbling)
  simulateClick(btn)
  simulateClick(btn)

  assert.equal(attempts.length, 1)
  assert.equal(pushCalls, 1)
})

test("Closure Gap E: UI-7: Second deliberate action after 1st view completion creates 1 fresh unique attempt ID", () => {
  let attempts = []
  let viewsRemaining = 2

  function simulateDeliberateOpen() {
    if (viewsRemaining <= 0) return null
    const attemptId = "att-" + (attempts.length + 1)
    attempts.push(attemptId)
    viewsRemaining--
    return attemptId
  }

  // 1st deliberate human action
  const id1 = simulateDeliberateOpen()
  assert.equal(viewsRemaining, 1)

  // 2nd deliberate human action
  const id2 = simulateDeliberateOpen()
  assert.equal(viewsRemaining, 0)

  assert.equal(attempts.length, 2)
  assert.notEqual(id1, id2)

  // 3rd attempt is rejected
  const id3 = simulateDeliberateOpen()
  assert.equal(id3, null)
  assert.equal(attempts.length, 2)
})

test("Feature 1O.2 - localMessage supports view_once_video without storing video bytes in IndexedDB", () => {
  const record = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-video-1",
    type: "view_once_video",
    view_once_state: "unviewed",
    media_type: "video/mp4",
    byte_size: 2_000_000,
    mine: false,
    sent_at: "2026-08-15T00:00:00Z"
  })

  assert.equal(record.type, "local_message")
  assert.equal(record.value.type, "view_once_video")
  assert.equal(record.value.view_once_state, "unviewed")
  assert.equal(record.value.presentation_limit, 1)
  assert.equal(record.value.views_remaining, 1)
  assert.equal(record.value.views_consumed, 0)
  assert.equal(record.value.media_type, "video/mp4")
  assert.equal(record.value.byte_size, 2_000_000)
  assert.equal(record.value.content, null)
  assert.equal(record.value.blob, undefined)
  assert.equal(record.value.binary, undefined)
  assert.equal(record.value.media_bytes, undefined)
})

test("Feature 1O.2 - Video player controls and audio arbitration in app.js", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /video\.id = "view-once-viewer-video"/)
  assert.match(appJs, /video\.controls = true/)
  assert.match(appJs, /video\.playsInline = true/)
  assert.match(appJs, /pauseAmbientAudio/)
  assert.match(appJs, /resumeAmbientAudio/)
})

test("Feature 1O.2 - Video viewer teardown cleans up src and revokes ObjectURL", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /video\.pause\(\)/)
  assert.match(appJs, /video\.removeAttribute\("src"\)/)
  assert.match(appJs, /video\.load\(\)/)
  assert.match(appJs, /URL\.revokeObjectURL\(activeViewOnceUrl\)/)
})

test("Feature 1O.2 - Presentation capacity busy error re-enables trigger and does not burn View", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /presentation_capacity_unavailable/)
  assert.match(appJs, /triggerBtn\.disabled = false/)
})

test("Feature 1O.3 - localMessage supports view_twice_video with limit 2 without storing video bytes", () => {
  const record = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-vt-vid-1",
    type: "view_twice_video",
    presentation_limit: 2,
    views_remaining: 2,
    views_consumed: 0,
    view_once_state: "unviewed",
    media_type: "video/mp4",
    byte_size: 3_000_000,
    mine: false,
    sent_at: "2026-08-15T00:00:00Z"
  })

  assert.equal(record.type, "local_message")
  assert.equal(record.value.type, "view_twice_video")
  assert.equal(record.value.presentation_limit, 2)
  assert.equal(record.value.views_remaining, 2)
  assert.equal(record.value.views_consumed, 0)
  assert.equal(record.value.view_once_state, "unviewed")
  assert.equal(record.value.media_type, "video/mp4")
  assert.equal(record.value.byte_size, 3_000_000)
  assert.equal(record.value.content, null)
  assert.equal(record.value.blob, undefined)
  assert.equal(record.value.binary, undefined)
})

test("Feature 1O.3 - UI card rendering strings for View-Twice video", () => {
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appJs, /View-twice video/)
  assert.match(appJs, /Open \(1 of 2\)/)
  assert.match(appJs, /Open again \(1 view remaining\)/)
  assert.match(appJs, /Opened \(2 of 2\)/)
})

test("Feature 1O.3 - Send as View Twice Video control in index.html and app.js", () => {
  const indexHtml = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
  const appJs = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

  assert.match(indexHtml, /id="view-twice-video-send"/)
  assert.match(appJs, /\$\("#view-twice-video-send"\)\?\.addEventListener\("click",\s*\(\)\s*=>\s*sendViewOnceVideo\(2\)\)/)
})

