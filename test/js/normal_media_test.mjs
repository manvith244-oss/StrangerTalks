import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import {
  NORMAL_MEDIA_TYPES,
  compareTimelineKeys,
  dedupeNormalMedia,
  genericTimelineKey,
  normalMediaDraftMatchesRuntime,
  normalMediaKind,
  normalMediaLabel,
  normalMediaTimelineKey,
  normalizeMediaType,
  validNormalMediaFile
} from "../../priv/static/assets/normal_media.mjs"

const runtimeSource = readFileSync(
  new URL("../../priv/static/assets/normal_media_runtime.mjs", import.meta.url),
  "utf8"
)
const controllerSource = readFileSync(
  new URL("../../lib/strangertalks_new_web/controllers/normal_media_controller.ex", import.meta.url),
  "utf8"
)
const storeSource = readFileSync(
  new URL("../../lib/strangertalks_new/conversation_lifecycle/normal_media_store.ex", import.meta.url),
  "utf8"
)

test("normal media MIME allowlist is bounded and separates photo from video", () => {
  assert.equal(normalMediaKind("image/jpeg"), "photo")
  assert.equal(normalMediaKind("image/png"), "photo")
  assert.equal(normalMediaKind("image/webp"), "photo")
  assert.equal(normalMediaKind("video/mp4"), "video")
  assert.equal(normalMediaKind("image/svg+xml"), null)
  assert.equal(normalMediaKind("text/html"), null)
  assert.equal(normalizeMediaType("IMAGE/JPEG; charset=binary"), "image/jpeg")
  assert.deepEqual(Object.keys(NORMAL_MEDIA_TYPES).sort(), ["image/jpeg", "image/png", "image/webp", "video/mp4"].sort())
})

test("client preflight enforces exact size boundaries without replacing server validation", () => {
  assert.equal(validNormalMediaFile(new Blob([new Uint8Array(1_048_576)], {type: "image/jpeg"})), true)
  assert.equal(validNormalMediaFile(new Blob([new Uint8Array(1_048_577)], {type: "image/jpeg"})), false)
  assert.equal(validNormalMediaFile(new Blob([new Uint8Array(5_242_880)], {type: "video/mp4"})), true)
  assert.equal(validNormalMediaFile(new Blob([new Uint8Array(5_242_881)], {type: "video/mp4"})), false)
  assert.equal(validNormalMediaFile(new Blob([], {type: "image/png"})), false)
  assert.equal(validNormalMediaFile(new Blob([new Uint8Array(10)], {type: "image/svg+xml"})), false)
})

test("draft authority is bound to its origin Conversation", () => {
  const draft = {originConversationId: "conversation-a"}
  assert.equal(normalMediaDraftMatchesRuntime(draft, "conversation-a"), true)
  assert.equal(normalMediaDraftMatchesRuntime(draft, "conversation-b"), false)
  assert.equal(normalMediaDraftMatchesRuntime(null, "conversation-a"), false)
})

test("media accepted then text accepted converges media before text", () => {
  const media = normalMediaTimelineKey({anchor_sequence: 0, anchor_ordinal: 1})
  const text = genericTimelineKey(1)
  assert.ok(compareTimelineKeys(media, text) < 0)
})

test("text accepted then media accepted converges text before media", () => {
  const text = genericTimelineKey(1)
  const media = normalMediaTimelineKey({anchor_sequence: 1, anchor_ordinal: 1})
  assert.ok(compareTimelineKeys(text, media) < 0)
})

test("media1 → text → media2 has one deterministic canonical order", () => {
  const items = [
    {id: "media2", key: normalMediaTimelineKey({anchor_sequence: 1, anchor_ordinal: 1})},
    {id: "text", key: genericTimelineKey(1)},
    {id: "media1", key: normalMediaTimelineKey({anchor_sequence: 0, anchor_ordinal: 1})}
  ]
  items.sort((a, b) => compareTimelineKeys(a.key, b.key))
  assert.deepEqual(items.map(({id}) => id), ["media1", "text", "media2"])
})

test("dedupe retains one logical media item and its original canonical anchor", () => {
  const items = dedupeNormalMedia([
    {client_message_id: "m2", anchor_sequence: 1, anchor_ordinal: 1, kind: "video"},
    {client_message_id: "m1", anchor_sequence: 0, anchor_ordinal: 1, kind: "photo"},
    {client_message_id: "m1", anchor_sequence: 0, anchor_ordinal: 1, kind: "photo", idempotent: true}
  ])
  assert.deepEqual(items.map((item) => item.client_message_id), ["m1", "m2"])
})

test("server ordering comes from the live Conversation sequence boundary, not clocks or polling", () => {
  assert.match(controllerSource, /ConversationServer\.inspect_state\(conversation_id\)/)
  assert.match(controllerSource, /next_sequence - 1/)
  assert.match(storeSource, /anchor_sequence/)
  assert.match(storeSource, /anchor_ordinal/)
  assert.match(runtimeSource, /compareTimelineKeys/)
  assert.doesNotMatch(runtimeSource, /Date\.now\(\)/)
  assert.doesNotMatch(runtimeSource, /insertBefore\(/)
})

test("normal mode is explicitly labeled separately from limited-open modes", () => {
  assert.equal(normalMediaLabel("photo"), "Photo")
  assert.equal(normalMediaLabel("video"), "Video")
  assert.match(runtimeSource, /Photo \/ Video/)
  assert.match(runtimeSource, /View Once and View Twice use separate limited-open modes/)
  assert.match(runtimeSource, /Send normally/)
})

test("cancel and replacement revoke obsolete preview object URLs", () => {
  assert.match(runtimeSource, /function clearPreview/)
  assert.match(runtimeSource, /revokeUrl\(state\.previewUrl\)/)
  assert.match(runtimeSource, /if \(file\) selectFile\(file\)/)
  assert.match(runtimeSource, /clearPreview\(\{hide: false\}\)/)
})

test("lost acknowledgement is described as ambiguous and retry reuses stable client media identity", () => {
  assert.match(runtimeSource, /clientMessageId: crypto\.randomUUID\(\)/)
  assert.match(runtimeSource, /draft\.clientMessageId/)
  assert.match(runtimeSource, /Send not confirmed\. It may have been accepted/)
  assert.match(runtimeSource, /Retry send/)
  assert.doesNotMatch(runtimeSource, /Nothing was delivered/)
})

test("authoritative HTTP rejection is distinct from ambiguous transport failure", () => {
  assert.match(runtimeSource, /Send rejected\. The server did not accept this media/)
  assert.match(runtimeSource, /if \(!response\.ok\)/)
  assert.match(runtimeSource, /catch \(_error\)/)
})

test("sender does not display Sent until authoritative HTTP success", () => {
  const uploadIndex = runtimeSource.indexOf("const response = await fetch(")
  const sentIndex = runtimeSource.indexOf('status.textContent = "Sent"')
  assert.ok(uploadIndex >= 0)
  assert.ok(sentIndex > uploadIndex)
})

test("late callbacks are inert after Conversation authority changes", () => {
  assert.match(runtimeSource, /stillCurrent\.conversationId !== draft\.originConversationId/)
  assert.match(runtimeSource, /normalMediaDraftMatchesRuntime\(draft, runtime\.conversationId\)/)
  assert.match(runtimeSource, /transitionConversation\(null\)/)
})

test("normal photos and videos are repeatable rather than counter-gated", () => {
  assert.match(runtimeSource, /Open photo/)
  assert.match(runtimeSource, /video\.controls = true/)
  assert.doesNotMatch(runtimeSource, /viewsRemaining|presentationLimit|already_consumed/)
  assert.doesNotMatch(controllerSource, /presentation_token|consume_presentation/)
})

test("media bytes use authenticated no-store endpoints and never expose original filename", () => {
  assert.match(runtimeSource, /authorization: `Bearer \$\{runtime\.token\}`/)
  assert.match(runtimeSource, /cache: "no-store"/)
  assert.doesNotMatch(runtimeSource, /file\.name/)
  assert.match(controllerSource, /put_resp_header\("cache-control", "no-store, private"\)/)
  assert.match(controllerSource, /put_resp_header\("x-content-type-options", "nosniff"\)/)
  assert.match(controllerSource, /put_resp_header\("content-disposition", "inline"\)/)
})

test("normal media does not create automatic report evidence or persistent local media records", () => {
  assert.doesNotMatch(runtimeSource, /putRecord|localMessage|localVoiceNote/)
  assert.doesNotMatch(controllerSource, /Reports|capture_report_evidence|safety_media/)
})

test("normal binary media exposes no Edit action", () => {
  assert.doesNotMatch(runtimeSource, /Edit Photo|Edit Video|message:edit/)
})
