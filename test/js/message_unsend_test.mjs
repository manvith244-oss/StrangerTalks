import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {
  localMessage,
  mergeMessageContent,
  sanitizeMessageReference
} from "../../priv/static/assets/local_data.mjs"

const html = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const app = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const css = readFileSync(new URL("../../priv/static/assets/app.css", import.meta.url), "utf8")

function availableRecord(overrides = {}) {
  return localMessage({
    conversation_id: "conversation-1",
    client_message_id: "message-1",
    content: "current text",
    mine: true,
    delivery_status: "delivered",
    sent_at: "2026-08-11T00:00:00Z",
    sequence: 7,
    content_revision: 2,
    self_reaction: {emoji: "❤️", revision: 1},
    peer_reaction: {emoji: "😂", revision: 1},
    ...overrides
  })
}

test("UNSENT terminal merge sanitizes the same logical IndexedDB record", () => {
  const record = availableRecord()
  const result = mergeMessageContent(record, {
    client_message_id: "message-1",
    content_revision: 2,
    availability: "unsent",
    unsent: true,
    delivery_status: "delivered"
  })

  assert.equal(result.status, "unsent_applied")
  assert.equal(result.record.id, record.id)
  assert.equal(result.record.value.sequence, 7)
  assert.equal(result.record.value.content, null)
  assert.equal(result.record.value.availability, "unsent")
  assert.equal(result.record.value.unsent, true)
  assert.equal(result.record.value.self_reaction, null)
  assert.equal(result.record.value.peer_reaction, null)
  assert.equal(result.record.value.edited, false)
  assert.equal("safety_snapshot" in result.record.value, false)
  assert.equal("history" in result.record.value, false)
})

test("UNSENT terminal precedence rejects delayed Edit and duplicate available projections", () => {
  const terminal = mergeMessageContent(availableRecord(), {
    client_message_id: "message-1",
    content_revision: 2,
    availability: "unsent",
    unsent: true,
    delivery_status: "delivered"
  }).record

  for (const incoming of [
    {client_message_id: "message-1", content_revision: 2, content: "same revision stale", delivery_status: "delivered"},
    {client_message_id: "message-1", content_revision: 3, content: "later edit must not resurrect", delivery_status: "delivered"}
  ]) {
    const result = mergeMessageContent(terminal, incoming)
    assert.equal(result.status, "ignored_terminal")
    assert.equal(result.record.value.content, null)
    assert.equal(result.record.value.availability, "unsent")
  }
})

test("an older delayed tombstone cannot defeat a newer canonical Edit", () => {
  const record = availableRecord({content: "revision three", content_revision: 3})
  const result = mergeMessageContent(record, {
    client_message_id: "message-1",
    content_revision: 2,
    availability: "unsent",
    unsent: true
  })

  assert.equal(result.status, "ignored_older")
  assert.equal(result.record.value.content, "revision three")
  assert.equal(result.record.value.availability, "available")
})

test("Reply reference sanitization preserves body and target identity across retained and pruned states", () => {
  const reply = availableRecord({
    client_message_id: "reply-1",
    content: "reply body survives",
    reply_to_client_message_id: "message-1",
    reply_snippet: "old target text"
  })

  const retained = sanitizeMessageReference(reply, "message-1", "unsent")
  assert.equal(retained.value.content, "reply body survives")
  assert.equal(retained.value.reply_to_client_message_id, "message-1")
  assert.equal(retained.value.reply_snippet, "Unsent message")

  const absent = sanitizeMessageReference(retained, "message-1", "unavailable")
  assert.equal(absent.value.reply_snippet, "Message unavailable")
  assert.equal(absent.value.reply_target_availability, "unavailable")
  assert.equal(absent.value.content, "reply body survives")
})

test("confirmation and accessibility source lock exact truthful Unsend copy and deliberate actions", () => {
  for (const copy of [
    "Unsend this message?",
    "It will no longer be available in this StrangerTalks Conversation. The other person may already have seen, copied, or saved it.",
    "StrangerTalks may temporarily keep a safety copy while this Conversation is active so the message can still be reported. If it is reported, that safety evidence can remain separately.",
    "Unsend",
    "Cancel"
  ]) assert.ok(html.includes(copy), `missing frozen Unsend copy: ${copy}`)

  assert.match(html, /id="unsend-confirmation-dialog"[^>]*role="dialog"[^>]*aria-modal="true"/)
  assert.match(app, /event\.key === "Escape"[\s\S]*closeMessageUnsend\(\)/)
  assert.match(app, /push\(app\.conversation, "message:unsend"/)
  assert.match(css, /\.unsend-confirmation-dialog/)
  assert.doesNotMatch(`${html}\n${app}`, /delete everywhere|erase forever|remove all copies|gone from their device|never delivered/i)
})

test("browser synchronization and action source lock terminal, absence, media-negative, and report-authority boundaries", () => {
  assert.match(app, /message:unsent"[\s\S]*applyCanonicalMessageUnsent/)
  assert.match(app, /status !== "sequence_inconsistent"[\s\S]*current_message_revisions[\s\S]*removeLocalOnlyCanonicalMessages/)
  assert.match(app, /sanitizeLocalReplyReferences\(messageId, "unavailable"\)/)
  assert.match(app, /terminalUnsent[\s\S]*message-actions-bar/)
  assert.match(app, /message\.type !== "expressive"[\s\S]*installUnsendAction/)
  assert.doesNotMatch(app, /voice_note:unsend|expressive:unsend/)
  assert.match(app, /target_client_message_id = app\.reportTargetMessageId/)
  assert.match(app, /evidence: app\.reportTargetMessageId \? null/)
  assert.doesNotMatch(app, /safety_snapshot/)
})

test("narrow 1L amendment locks the approved safety disclosure and existing no-expiry truth", () => {
  const approved = "An unsent text message may be kept temporarily inside the active Conversation for safety reporting. If that unsent message is reported while the safety copy is still available, the specific message text may be stored with the report."
  assert.ok(app.includes(approved))
  assert.ok(app.includes("Stored report and safety-review records currently have no automatic expiry or cleanup."))
  assert.match(app, /reportTargetMessageId \? null/)
})
