import assert from "node:assert/strict"
import test from "node:test"

import {
  chooseConversationRetention,
  deleteRecord,
  getRecord,
  listRecords,
  putRecord
} from "../../priv/static/assets/local_data.mjs"
import {createMemoryIndexedDB} from "../../priv/static/assets/f11_persistence_runtime.mjs"

const now = "2026-08-27T06:45:00.000Z"
const participantA = "11111111-1111-4111-8111-111111111111"
const conversationA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const relationshipA = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

function record(id, type, value, updated_at = now) { return {id, type, value, updated_at} }

function conversation(status = "temporary", connection_state = "ended") {
  return record(`conversation:${conversationA}`, "local_conversation", {
    conversation_id: conversationA,
    door_type: "EXPLORE",
    display_door: "Advice",
    abstract_signature_seed: "sig-test",
    status,
    connection_state,
    started_at: now,
    ended_at: connection_state === "ended" ? now : null,
    summary_id: null
  })
}

async function withMemoryIndexedDB(run) {
  const previous = globalThis.indexedDB
  const memory = createMemoryIndexedDB()
  globalThis.indexedDB = memory
  try { return await run(memory) } finally {
    if (previous === undefined) delete globalThis.indexedDB
    else globalThis.indexedDB = previous
  }
}

async function rawPut(memory, item) {
  const opening = memory.open("strangertalks-local-v1", 1)
  const db = await new Promise((resolve, reject) => {
    opening.onupgradeneeded = () => opening.result.createObjectStore("records", {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => resolve(opening.result)
  })
  const tx = db.transaction("records", "readwrite")
  const request = tx.objectStore("records").put(item)
  await new Promise((resolve, reject) => { request.onsuccess = resolve; request.onerror = reject })
}

test("CLEANUP-02 retention completion removes cursor and pending-terminal recovery records", () => {
  const records = [
    conversation(),
    record(`message:${conversationA}:m1`, "local_message", {conversation_id: conversationA, client_message_id: "m1", message_id: "m1", type: "text", content: "keep", mine: true, delivery_status: "delivered", sent_at: now}),
    record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 2}),
    record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "pending", ended_at: now})
  ]
  const kept = chooseConversationRetention(records, conversationA, "kept", {now})
  assert.equal(kept.some(({id}) => id === `sync_cursor:${conversationA}`), false)
  assert.equal(kept.some(({id}) => id === `terminal_retention:${conversationA}`), false)
  assert.equal(kept.some(({id}) => id === `message:${conversationA}:m1`), true)
})

test("CORRUPT live get discards a malformed saved identity instead of trusting it", async () => {
  await withMemoryIndexedDB(async (memory) => {
    await rawPut(memory, record("strangertalks.identity.v1", "identity", {participant_id: participantA}))
    assert.equal(await getRecord("strangertalks.identity.v1"), null)
  })
})

test("STORAGE-05 putRecord resolves only after the readwrite transaction completes", async () => {
  const events = []
  const fake = {
    open() {
      const opening = {result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null}
      queueMicrotask(() => {
        const db = {
          close() {},
          createObjectStore() {},
          transaction() {
            const tx = {oncomplete: null, onerror: null, onabort: null, error: null}
            const store = {
              put(value) {
                const request = {result: value.id, error: null, onsuccess: null, onerror: null}
                queueMicrotask(() => {
                  events.push("operation-success")
                  request.onsuccess?.({target: request})
                  setTimeout(() => {
                    events.push("transaction-complete")
                    tx.oncomplete?.({target: tx})
                  }, 5)
                })
                return request
              }
            }
            tx.objectStore = () => store
            return tx
          }
        }
        opening.result = db
        opening.onsuccess?.({target: opening})
      })
      return opening
    }
  }
  const previous = globalThis.indexedDB
  globalThis.indexedDB = fake
  try {
    let resolved = false
    const write = putRecord(record("settings:privacy", "settings", {reduced_motion: true})).then(() => { resolved = true; events.push("promise-resolved") })
    await new Promise((resolve) => setTimeout(resolve, 1))
    assert.equal(resolved, false)
    await write
    assert.deepEqual(events, ["operation-success", "transaction-complete", "promise-resolved"])
  } finally {
    if (previous === undefined) delete globalThis.indexedDB
    else globalThis.indexedDB = previous
  }
})

test("PARTICIPANT-01 deleting a replaced identity also invalidates old participant recovery-only records", async () => {
  await withMemoryIndexedDB(async () => {
    await putRecord(record("strangertalks.identity.v1", "identity", {participant_id: participantA, token: "token"}))
    await putRecord(conversation("temporary", "connected"))
    await putRecord(record(`message:${conversationA}:m1`, "local_message", {conversation_id: conversationA, client_message_id: "m1", message_id: "m1", type: "text", content: "temporary", mine: true, delivery_status: "delivered", sent_at: now}))
    await putRecord(record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 1}))
    await putRecord(record(`bond-reconnect:${relationshipA}`, "bond_reconnect_state", {relationship_id: relationshipA, status: "idle"}))
    await putRecord(record("memory:keep", "memory", {text: "browser retained"}))

    await deleteRecord("strangertalks.identity.v1")
    const ids = new Set((await listRecords()).map(({id}) => id))
    assert.equal(ids.has("strangertalks.identity.v1"), false)
    assert.equal(ids.has(`conversation:${conversationA}`), false)
    assert.equal(ids.has(`message:${conversationA}:m1`), false)
    assert.equal(ids.has(`sync_cursor:${conversationA}`), false)
    assert.equal(ids.has(`bond-reconnect:${relationshipA}`), false)
    assert.equal(ids.has("memory:keep"), true)
  })
})
