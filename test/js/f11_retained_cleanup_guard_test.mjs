import assert from "node:assert/strict"
import test from "node:test"

import {cleanupConversationRecoveryRecords} from "../../priv/static/assets/f11_persistence_runtime.mjs"

const now = "2026-08-27T08:00:00.000Z"
const conversationId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

function record(id, type, value) { return {id, type, value, updated_at: now} }

function keptConversation() {
  return record(`conversation:${conversationId}`, "local_conversation", {
    conversation_id: conversationId,
    door_type: "EXPLORE",
    display_door: "Advice",
    abstract_signature_seed: "sig-kept",
    status: "kept",
    connection_state: "ended",
    started_at: now,
    ended_at: now,
    summary_id: null
  })
}

test("CLEANUP retained guard preserves Keep product data while removing recovery-only cursor/terminal marker", () => {
  const records = [
    keptConversation(),
    record(`message:${conversationId}:m1`, "local_message", {conversation_id: conversationId, client_message_id: "m1", message_id: "m1", type: "text", content: "kept", mine: true, delivery_status: "delivered", sent_at: now}),
    record(`voice:${conversationId}:v1`, "local_voice_note", {conversation_id: conversationId, voice_note_id: "v1", blob: new Blob(["voice"]), mine: true, delivery_status: "delivered", sent_at: now, sequence: 1, duration_ms: 1000, byte_size: 5, media_type: "audio/webm"}),
    record(`summary:${conversationId}`, "summary", {conversation_id: conversationId, text: "kept summary"}),
    record(`sync_cursor:${conversationId}`, "sync_cursor", {conversation_id: conversationId, epoch_id: "epoch-a", last_applied_sequence: 4}),
    record(`terminal_retention:${conversationId}`, "terminal_retention_state", {conversation_id: conversationId, status: "pending", ended_at: now})
  ]

  const cleaned = cleanupConversationRecoveryRecords(records, conversationId)
  const ids = new Set(cleaned.map(({id}) => id))

  assert.equal(ids.has(`conversation:${conversationId}`), true)
  assert.equal(ids.has(`message:${conversationId}:m1`), true)
  assert.equal(ids.has(`voice:${conversationId}:v1`), true)
  assert.equal(ids.has(`summary:${conversationId}`), true)
  assert.equal(ids.has(`sync_cursor:${conversationId}`), false)
  assert.equal(ids.has(`terminal_retention:${conversationId}`), false)
})
