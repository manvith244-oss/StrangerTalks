import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {localMessage, mergeMessageContent} from "../../priv/static/assets/local_data.mjs"

function record(overrides = {}) {
  return localMessage({
    conversation_id: "conversation-1",
    client_message_id: "message-1",
    type: "text",
    content: "before",
    mine: true,
    delivery_status: "delivered",
    sent_at: "2026-08-11T00:00:00.000Z",
    sequence: 7,
    content_revision: 0,
    ...overrides
  })
}

test("BROWSER-ARBITRATION higher revision updates the same local record in place", () => {
  const original = record()
  const merged = mergeMessageContent(original, {
    client_message_id: "message-1",
    content: "after",
    content_revision: 1,
    delivery_status: "sent"
  }, "2026-08-11T00:00:01.000Z")

  assert.equal(merged.status, "applied")
  assert.equal(merged.record.id, original.id)
  assert.equal(merged.record.value.client_message_id, "message-1")
  assert.equal(merged.record.value.sequence, 7)
  assert.equal(merged.record.value.content, "after")
  assert.equal(merged.record.value.content_revision, 1)
  assert.equal(merged.record.value.edited, true)
  assert.equal(merged.record.value.delivery_status, "delivered", "logical delivery never regresses")
  assert.equal(Object.hasOwn(merged.record.value, "revisions"), false)
  assert.equal(Object.hasOwn(merged.record.value, "old_text"), false)
})

test("BROWSER-ARBITRATION lower revisions are ignored and equal matching revisions are idempotent", () => {
  const current = record({content: "current", content_revision: 2, edited: true})
  const lower = mergeMessageContent(current, {client_message_id: "message-1", content: "old", content_revision: 1})
  const duplicate = mergeMessageContent(current, {client_message_id: "message-1", content: "current", content_revision: 2})

  assert.equal(lower.status, "ignored_older")
  assert.strictEqual(lower.record, current)
  assert.equal(duplicate.status, "no_op")
  assert.equal(duplicate.record.value.content, "current")
})

test("BROWSER-ARBITRATION equal revision with different content is a correctness conflict", () => {
  const current = record({content: "canonical", content_revision: 3, edited: true})
  const conflict = mergeMessageContent(current, {client_message_id: "message-1", content: "impossible", content_revision: 3})

  assert.equal(conflict.status, "equal_revision_conflict")
  assert.strictEqual(conflict.record, current)
  assert.equal(conflict.record.value.content, "canonical")
})

test("BROWSER-DELIVERY applied revision evidence is monotonic on the one message record", () => {
  const current = record({content: "edited", content_revision: 2, peer_applied_content_revision: 1, edited: true})
  const higher = mergeMessageContent(current, {
    client_message_id: "message-1",
    content: "edited",
    content_revision: 2,
    peer_applied_content_revision: 2
  })
  const lower = mergeMessageContent(higher.record, {
    client_message_id: "message-1",
    content: "edited",
    content_revision: 2,
    peer_applied_content_revision: 1
  })

  assert.equal(higher.record.value.peer_applied_content_revision, 2)
  assert.equal(lower.record.value.peer_applied_content_revision, 2)
})

test("BROWSER-UX edit sends only on explicit Save and preserves composer and Reply ownership", async () => {
  const source = await readFile(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  const editBlock = source.slice(source.indexOf("async function beginMessageEdit"), source.indexOf("async function acknowledgeContentRevision"))

  assert.match(editBlock, /form\.addEventListener\("submit"/)
  assert.match(editBlock, /event\.key === "Escape"/)
  assert.match(editBlock, /target_client_message_id: editing\.messageId/)
  assert.match(editBlock, /expected_content_revision: editing\.expectedRevision/)
  assert.match(editBlock, /content\n\s*}\)/)
  assert.doesNotMatch(editBlock, /message-input/)
  assert.doesNotMatch(editBlock, /replyState\s*=/)
  assert.doesNotMatch(editBlock, /typing:start/)
  assert.doesNotMatch(editBlock, /textarea\.addEventListener\("input",[^}]*push\(/)
})
