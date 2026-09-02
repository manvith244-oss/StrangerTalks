import assert from "node:assert/strict"
import test from "node:test"

import {
  cleanupConversationRecoveryRecords,
  cleanupParticipantBoundRecords,
  createCanonicalReadiness,
  createFutureLanguageState,
  createMemoryIndexedDB,
  createResilientIndexedDB,
  findPendingTerminalRetention,
  safeStorageGet,
  safeStorageRemove,
  safeStorageSet,
  validLiveRecord
} from "../../priv/static/assets/f11_persistence_runtime.mjs"

const now = "2026-08-27T06:30:00.000Z"
const participantA = "11111111-1111-4111-8111-111111111111"
const conversationA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const conversationB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const relationshipA = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

function record(id, type, value, updated_at = now) {
  return {id, type, value, updated_at}
}

function temporaryConversation(id, connection_state = "connected") {
  return record(`conversation:${id}`, "local_conversation", {
    conversation_id: id,
    door_type: "EXPLORE",
    display_door: "Advice",
    abstract_signature_seed: "sig-test",
    status: "temporary",
    connection_state,
    started_at: now,
    ended_at: connection_state === "ended" ? now : null,
    summary_id: null
  })
}

function keptConversation(id) {
  return record(`conversation:${id}`, "local_conversation", {
    conversation_id: id,
    door_type: "EXPLORE",
    display_door: "Advice",
    abstract_signature_seed: "sig-test",
    status: "kept",
    connection_state: "ended",
    started_at: now,
    ended_at: now,
    summary_id: null
  })
}

test("STORAGE-01/02 safe localStorage helpers fail closed without throwing", () => {
  const throwing = {
    getItem() { throw new Error("blocked") },
    setItem() { throw new Error("blocked") },
    removeItem() { throw new Error("blocked") }
  }
  assert.equal(safeStorageGet(throwing, "x", "fallback"), "fallback")
  assert.equal(safeStorageSet(throwing, "x", "y"), false)
  assert.equal(safeStorageRemove(throwing, "x"), false)
})

test("CORRUPT-01 validates participant identity before bootstrap use", () => {
  assert.equal(validLiveRecord(record("strangertalks.identity.v1", "identity", {participant_id: participantA, token: "token"})), true)
  assert.equal(validLiveRecord(record("strangertalks.identity.v1", "identity", {participant_id: participantA})), false)
  assert.equal(validLiveRecord(record("strangertalks.identity.v1", "identity", {participant_id: "not-a-uuid", token: "token"})), false)
  assert.equal(validLiveRecord({...record("strangertalks.identity.v1", "identity", {participant_id: participantA, token: "token"}), schema_version: 99}), false)
})

test("CORRUPT-02 rejects malformed Conversation recovery state", () => {
  assert.equal(validLiveRecord(temporaryConversation(conversationA)), true)
  assert.equal(validLiveRecord({...temporaryConversation(conversationA), value: {...temporaryConversation(conversationA).value, status: "ACTIVE"}}), false)
  assert.equal(validLiveRecord({...temporaryConversation(conversationA), value: {...temporaryConversation(conversationA).value, conversation_id: "wrong"}}), false)
})

test("CORRUPT-03 validates sync cursor binding and cursor shape", () => {
  const valid = record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-1", last_applied_sequence: 4})
  assert.equal(validLiveRecord(valid), true)
  assert.equal(validLiveRecord({...valid, id: `sync_cursor:${conversationB}`}), false)
  assert.equal(validLiveRecord({...valid, value: {...valid.value, last_applied_sequence: -1}}), false)
})

test("CORRUPT-04 validates known Settings and Bond reconnect shapes", () => {
  assert.equal(validLiveRecord(record("settings:privacy", "settings", {reduced_motion: true})), true)
  assert.equal(validLiveRecord(record("settings:privacy", "settings", {reduced_motion: "yes"})), false)
  assert.equal(validLiveRecord(record(`bond-reconnect:${relationshipA}`, "bond_reconnect_state", {relationship_id: relationshipA, status: "idle"})), true)
  assert.equal(validLiveRecord(record(`bond-reconnect:${relationshipA}`, "bond_reconnect_state", {relationship_id: relationshipA, status: "nonsense"})), false)
})

test("CLEANUP-01 removes only Conversation recovery data and preserves retained product data", () => {
  const records = [
    temporaryConversation(conversationA),
    record(`message:${conversationA}:m1`, "local_message", {conversation_id: conversationA, client_message_id: "m1", message_id: "m1", type: "text", content: "temporary", mine: true, delivery_status: "delivered", sent_at: now}),
    record(`voice:${conversationA}:v1`, "local_voice_note", {conversation_id: conversationA, voice_note_id: "v1", blob: new Blob(["voice"]), mine: true, delivery_status: "delivered", sent_at: now, sequence: 1, duration_ms: 1000, byte_size: 5, media_type: "audio/webm"}),
    record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 3}),
    record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "pending", ended_at: now}),
    record(`summary:${conversationA}`, "summary", {conversation_id: conversationA, text: "keep summary"}),
    record("memory:1", "memory", {text: "keep memory", conversation_id: conversationA}),
    record(`relationship:${relationshipA}`, "relationship", {relationship_id: relationshipA, status: "created", conversation_id: conversationA})
  ]
  const cleaned = cleanupConversationRecoveryRecords(records, conversationA)
  const ids = new Set(cleaned.map(({id}) => id))
  assert.equal(ids.has(`conversation:${conversationA}`), false)
  assert.equal(ids.has(`message:${conversationA}:m1`), false)
  assert.equal(ids.has(`voice:${conversationA}:v1`), false)
  assert.equal(ids.has(`sync_cursor:${conversationA}`), false)
  assert.equal(ids.has(`terminal_retention:${conversationA}`), false)
  assert.equal(ids.has(`summary:${conversationA}`), true)
  assert.equal(ids.has("memory:1"), true)
  assert.equal(ids.has(`relationship:${relationshipA}`), true)
})

test("PARTICIPANT-01 removes participant-bound recovery while preserving retained browser data", () => {
  const records = [
    temporaryConversation(conversationA),
    keptConversation(conversationB),
    record(`message:${conversationA}:m-a`, "local_message", {conversation_id: conversationA, client_message_id: "m-a", message_id: "m-a", type: "text", content: "temporary", mine: true, delivery_status: "delivered", sent_at: now}),
    record(`message:${conversationB}:m-b`, "local_message", {conversation_id: conversationB, client_message_id: "m-b", message_id: "m-b", type: "text", content: "kept", mine: true, delivery_status: "delivered", sent_at: now}),
    record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 1}),
    record(`sync_cursor:${conversationB}`, "sync_cursor", {conversation_id: conversationB, epoch_id: "epoch-b", last_applied_sequence: 1}),
    record(`bond-reconnect:${relationshipA}`, "bond_reconnect_state", {relationship_id: relationshipA, status: "idle"}),
    record(`relationship:${relationshipA}`, "relationship", {relationship_id: relationshipA, status: "created", conversation_id: conversationB}),
    record("memory:1", "memory", {text: "remember"}),
    record("settings:privacy", "settings", {reduced_motion: true})
  ]
  const cleaned = cleanupParticipantBoundRecords(records)
  const ids = new Set(cleaned.map(({id}) => id))
  assert.equal(ids.has(`conversation:${conversationA}`), false)
  assert.equal(ids.has(`message:${conversationA}:m-a`), false)
  assert.equal(ids.has(`bond-reconnect:${relationshipA}`), false)
  assert.equal([...ids].some((id) => id.startsWith("sync_cursor:")), false)
  assert.equal(ids.has(`conversation:${conversationB}`), true)
  assert.equal(ids.has(`message:${conversationB}:m-b`), true)
  assert.equal(ids.has(`relationship:${relationshipA}`), true)
  assert.equal(ids.has("memory:1"), true)
  assert.equal(ids.has("settings:privacy"), true)
})

test("LANG-01 canonical current language never overwrites future/default preference", () => {
  const state = createFutureLanguageState("te")
  state.setCurrentCanonical("en")
  assert.equal(state.current(), "en")
  assert.equal(state.future(), "te")
  assert.equal(state.languageForNewAttempt("en"), "te")
})

test("LANG-02 changing future preference while QUEUED does not mutate current attempt", () => {
  const state = createFutureLanguageState("te")
  state.setCurrentCanonical("en")
  state.setFuture("hi")
  assert.equal(state.current(), "en")
  assert.equal(state.future(), "hi")
})

test("READINESS-01 canonical activity remains pending until a SessionReconciliation snapshot is accepted", () => {
  const readiness = createCanonicalReadiness()
  assert.equal(readiness.get().status, "CANONICAL_STATE_PENDING")
  readiness.accept({participant_id: participantA, canonical_state: "QUEUED", queue: {queue_attempt_id: "attempt-1", conversation_language: "en"}, conversation: null})
  assert.equal(readiness.get().status, "READY")
  assert.equal(readiness.get().canonical_state, "QUEUED")
})

test("F-BLK-006 pending terminal retention is distinguishable from completed retention", () => {
  const pendingRecords = [
    temporaryConversation(conversationA, "ended"),
    record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "pending", ended_at: now})
  ]
  assert.equal(findPendingTerminalRetention(pendingRecords)?.conversation_id, conversationA)
  assert.equal(findPendingTerminalRetention([keptConversation(conversationA)]), null)
})

test("STORAGE-03/04 unavailable IndexedDB falls back to an ephemeral local database", async () => {
  const throwingFactory = {open() { throw new Error("indexeddb unavailable") }}
  const resilient = createResilientIndexedDB(throwingFactory, createMemoryIndexedDB())
  const opened = resilient.open("strangertalks-local-v1", 1)
  const db = await new Promise((resolve, reject) => {
    opened.onupgradeneeded = () => opened.result.createObjectStore("records", {keyPath: "id"})
    opened.onerror = () => reject(opened.error)
    opened.onsuccess = () => resolve(opened.result)
  })
  const tx = db.transaction("records", "readwrite")
  const put = tx.objectStore("records").put(record("strangertalks.identity.v1", "identity", {participant_id: participantA, token: "online-token"}))
  await new Promise((resolve, reject) => { put.onsuccess = resolve; put.onerror = reject })
  const readTx = db.transaction("records", "readonly")
  const get = readTx.objectStore("records").get("strangertalks.identity.v1")
  const restored = await new Promise((resolve, reject) => { get.onsuccess = () => resolve(get.result); get.onerror = reject })
  assert.equal(restored.value.token, "online-token")
})

test("STORAGE-05 write request success is not exposed before transaction completion", async () => {
  const dbFactory = createMemoryIndexedDB()
  const opening = dbFactory.open("strangertalks-local-v1", 1)
  const db = await new Promise((resolve, reject) => {
    opening.onupgradeneeded = () => opening.result.createObjectStore("records", {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => resolve(opening.result)
  })
  const order = []
  const tx = db.transaction("records", "readwrite")
  tx.oncomplete = () => order.push("transaction-complete")
  const put = tx.objectStore("records").put(record("settings:privacy", "settings", {reduced_motion: true}))
  put.onsuccess = () => order.push("put-success")
  await new Promise((resolve) => setTimeout(resolve, 0))
  assert.deepEqual(order, ["put-success", "transaction-complete"])
  assert.equal(tx.__durablyCompletedBeforeRequestSuccess, true)
})
