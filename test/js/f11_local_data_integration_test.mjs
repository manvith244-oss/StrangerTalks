import assert from "node:assert/strict"
import test from "node:test"

import {
  chooseConversationRetention,
  deleteRecord,
  getRecord,
  listRecords,
  putRecord,
  replaceRecords
} from "../../priv/static/assets/local_data.mjs"
import {createMemoryIndexedDB} from "../../priv/static/assets/f11_persistence_runtime.mjs"
import {createCanonicalIndexedDB, installCanonicalIndexedDB} from "../../priv/static/assets/f11_local_store.mjs"

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

async function withIndexedDB(factory, run) {
  const previous = globalThis.indexedDB
  globalThis.indexedDB = factory
  try { return await run() } finally {
    if (previous === undefined) delete globalThis.indexedDB
    else globalThis.indexedDB = previous
  }
}

async function withCanonicalIndexedDB(run) {
  const native = createMemoryIndexedDB()
  const canonical = createCanonicalIndexedDB(native)
  return withIndexedDB(canonical, () => run(native, canonical))
}

async function rawPut(native, item) {
  const opening = native.open("strangertalks-local-v1", 1)
  const db = await new Promise((resolve, reject) => {
    opening.onupgradeneeded = () => opening.result.createObjectStore("records", {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => resolve(opening.result)
  })
  const tx = db.transaction("records", "readwrite")
  const request = tx.objectStore("records").put(item)
  await new Promise((resolve, reject) => { request.onsuccess = resolve; request.onerror = reject })
}

test("LOCAL-00 bootstrap installer installs the canonical store once before local_data consumers", () => {
  const native = createMemoryIndexedDB()
  const target = {indexedDB: native}
  const installed = installCanonicalIndexedDB(target)
  assert.equal(target.indexedDB, installed)
  assert.equal(installed.__f11Canonical, true)
  assert.equal(installCanonicalIndexedDB(target), installed)
})

test("LOCAL-01 canonical IndexedDB boundary exists and is the app-facing factory", async () => {
  await withCanonicalIndexedDB(async (_native, canonical) => {
    assert.equal(canonical.__f11Canonical, true)
    assert.equal(globalThis.indexedDB, canonical)
    assert.equal(canonical.storageStatus().mode, "pending")
    await listRecords()
    assert.equal(canonical.storageStatus().mode, "durable")
  })
})

test("CLEANUP-02/LOCAL-10 retention completion removes cursor and pending-terminal recovery records", async () => {
  await withCanonicalIndexedDB(async () => {
    const records = [
      conversation(),
      record(`message:${conversationA}:m1`, "local_message", {conversation_id: conversationA, client_message_id: "m1", message_id: "m1", type: "text", content: "keep", mine: true, delivery_status: "delivered", sent_at: now}),
      record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 2}),
      record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "pending", ended_at: now})
    ]
    await replaceRecords(records)
    await replaceRecords(chooseConversationRetention(await listRecords(), conversationA, "kept", {now}))
    const kept = await listRecords()
    assert.equal(kept.some(({id}) => id === `sync_cursor:${conversationA}`), false)
    assert.equal(kept.some(({id}) => id === `terminal_retention:${conversationA}`), false)
    assert.equal(kept.some(({id}) => id === `message:${conversationA}:m1`), true)
  })
})

test("LOCAL-02 malformed saved identity is discarded by real getRecord", async () => {
  await withCanonicalIndexedDB(async (native) => {
    await rawPut(native, record("strangertalks.identity.v1", "identity", {participant_id: participantA}))
    assert.equal(await getRecord("strangertalks.identity.v1"), null)
  })
})

test("LOCAL-03/04 read hydration rejects malformed recovery families instead of trusting them", async () => {
  await withCanonicalIndexedDB(async (native) => {
    const malformed = [
      {...conversation(), value: {...conversation().value, conversation_id: "not-a-uuid"}},
      record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: -1}),
      record("settings:privacy", "settings", {reduced_motion: "yes"}),
      record(`bond-reconnect:${relationshipA}`, "bond_reconnect_state", {relationship_id: relationshipA, status: "nonsense"}),
      record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "completed", ended_at: now})
    ]
    for (const item of malformed) await rawPut(native, item)

    for (const item of malformed) assert.equal(await getRecord(item.id), null)
    assert.deepEqual(await listRecords(), [])
  })
})

test("LOCAL-05 putRecord resolves only after the native readwrite transaction completes", async () => {
  const events = []
  const native = {
    open() {
      const opening = {result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null}
      queueMicrotask(() => {
        const records = new Map()
        const db = {
          close() {},
          createObjectStore() {},
          transaction(_name, mode) {
            const tx = {oncomplete: null, onerror: null, onabort: null, error: null}
            const store = {
              getAll() {
                const request = {result: [...records.values()], error: null, onsuccess: null, onerror: null}
                queueMicrotask(() => { request.onsuccess?.({target: request}); tx.oncomplete?.({target: tx}) })
                return request
              },
              clear() {
                const request = {result: undefined, error: null, onsuccess: null, onerror: null}
                queueMicrotask(() => { records.clear(); request.onsuccess?.({target: request}) })
                return request
              },
              put(value) {
                const request = {result: value.id, error: null, onsuccess: null, onerror: null}
                queueMicrotask(() => {
                  records.set(value.id, value)
                  events.push("native-operation-success")
                  request.onsuccess?.({target: request})
                  if (mode === "readwrite") setTimeout(() => { events.push("native-transaction-complete"); tx.oncomplete?.({target: tx}) }, 5)
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
  const canonical = createCanonicalIndexedDB(native)
  await withIndexedDB(canonical, async () => {
    await listRecords()
    events.length = 0
    let resolved = false
    const write = putRecord(record("settings:privacy", "settings", {reduced_motion: true})).then(() => { resolved = true; events.push("promise-resolved") })
    await new Promise((resolve) => setTimeout(resolve, 1))
    assert.equal(resolved, false)
    await write
    assert.equal(events.at(-1), "promise-resolved")
    assert.ok(events.indexOf("native-transaction-complete") < events.indexOf("promise-resolved"))
    assert.equal(canonical.storageStatus().mode, "durable")
  })
})

test("LOCAL-06 native open failure degrades to explicit ephemeral storage", async () => {
  const canonical = createCanonicalIndexedDB({open() { throw new Error("indexeddb blocked") }})
  await withIndexedDB(canonical, async () => {
    await putRecord(record("strangertalks.identity.v1", "identity", {participant_id: participantA, token: "online-token"}))
    assert.equal((await getRecord("strangertalks.identity.v1")).value.token, "online-token")
    assert.equal(canonical.storageStatus().mode, "ephemeral")
    assert.equal(canonical.storageStatus().durable, false)
  })
})

test("LOCAL-07 native write failure keeps usable ephemeral state without false durability", async () => {
  const native = {
    open() {
      const opening = {result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null}
      queueMicrotask(() => {
        const db = {
          close() {},
          createObjectStore() {},
          transaction(_name, mode) {
            if (mode === "readwrite") throw new Error("writes blocked")
            const tx = {oncomplete: null, onerror: null, onabort: null, error: null}
            tx.objectStore = () => ({
              getAll() {
                const request = {result: [], error: null, onsuccess: null, onerror: null}
                queueMicrotask(() => { request.onsuccess?.({target: request}); tx.oncomplete?.({target: tx}) })
                return request
              }
            })
            return tx
          }
        }
        opening.result = db
        opening.onsuccess?.({target: opening})
      })
      return opening
    }
  }
  const canonical = createCanonicalIndexedDB(native)
  await withIndexedDB(canonical, async () => {
    await listRecords()
    await putRecord(record("settings:privacy", "settings", {reduced_motion: true}))
    assert.equal((await getRecord("settings:privacy")).value.reduced_motion, true)
    assert.equal(canonical.storageStatus().mode, "ephemeral")
    assert.equal(canonical.storageStatus().durable, false)
  })
})

test("LOCAL-08 participant replacement invalidates old recovery-only records", async () => {
  await withCanonicalIndexedDB(async () => {
    await putRecord(record("strangertalks.identity.v1", "identity", {participant_id: participantA, token: "token"}))
    await putRecord(conversation("temporary", "connected"))
    await putRecord(record(`message:${conversationA}:m1`, "local_message", {conversation_id: conversationA, client_message_id: "m1", message_id: "m1", type: "text", content: "temporary", mine: true, delivery_status: "delivered", sent_at: now}))
    await putRecord(record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 1}))
    await putRecord(record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "pending", ended_at: now}))
    await putRecord(record(`bond-reconnect:${relationshipA}`, "bond_reconnect_state", {relationship_id: relationshipA, status: "idle"}))
    await putRecord(record("memory:keep", "memory", {text: "browser retained"}))
    await putRecord(record(`relationship:${relationshipA}`, "relationship", {relationship_id: relationshipA, status: "created", conversation_id: conversationA}))

    await deleteRecord("strangertalks.identity.v1")
    const ids = new Set((await listRecords()).map(({id}) => id))
    assert.equal(ids.has("strangertalks.identity.v1"), false)
    assert.equal(ids.has(`conversation:${conversationA}`), false)
    assert.equal(ids.has(`message:${conversationA}:m1`), false)
    assert.equal(ids.has(`sync_cursor:${conversationA}`), false)
    assert.equal(ids.has(`terminal_retention:${conversationA}`), false)
    assert.equal(ids.has(`bond-reconnect:${relationshipA}`), false)
    assert.equal(ids.has("memory:keep"), true)
    assert.equal(ids.has(`relationship:${relationshipA}`), true)
  })
})

test("LOCAL-09 one Conversation cleanup removes recovery-only state and preserves retained product data", async () => {
  await withCanonicalIndexedDB(async (_native, canonical) => {
    await replaceRecords([
      conversation("temporary", "connected"),
      record(`message:${conversationA}:m1`, "local_message", {conversation_id: conversationA, client_message_id: "m1", message_id: "m1", type: "text", content: "temporary", mine: true, delivery_status: "delivered", sent_at: now}),
      record(`voice:${conversationA}:v1`, "local_voice_note", {conversation_id: conversationA, voice_note_id: "v1", blob: new Blob(["voice"]), mine: true, delivery_status: "delivered", sent_at: now, sequence: 1, duration_ms: 1000, byte_size: 5, media_type: "audio/webm"}),
      record(`sync_cursor:${conversationA}`, "sync_cursor", {conversation_id: conversationA, epoch_id: "epoch-a", last_applied_sequence: 1}),
      record(`terminal_retention:${conversationA}`, "terminal_retention_state", {conversation_id: conversationA, status: "pending", ended_at: now}),
      record(`summary:${conversationA}`, "summary", {conversation_id: conversationA, text: "retain summary"}),
      record("memory:keep", "memory", {text: "retain memory", conversation_id: conversationA}),
      record(`relationship:${relationshipA}`, "relationship", {relationship_id: relationshipA, status: "created", conversation_id: conversationA})
    ])

    await canonical.cleanupConversationRecovery(conversationA)
    const ids = new Set((await listRecords()).map(({id}) => id))
    assert.equal(ids.has(`conversation:${conversationA}`), false)
    assert.equal(ids.has(`message:${conversationA}:m1`), false)
    assert.equal(ids.has(`voice:${conversationA}:v1`), false)
    assert.equal(ids.has(`sync_cursor:${conversationA}`), false)
    assert.equal(ids.has(`terminal_retention:${conversationA}`), false)
    assert.equal(ids.has(`summary:${conversationA}`), true)
    assert.equal(ids.has("memory:keep"), true)
    assert.equal(ids.has(`relationship:${relationshipA}`), true)
  })
})

test("LOCAL-11 overlapping readwrite transactions preserve both writes durably", async () => {
  await withCanonicalIndexedDB(async (native) => {
    await listRecords()
    await Promise.all([
      putRecord(record("settings:privacy", "settings", {reduced_motion: true})),
      putRecord(record("settings:auto-sync", "settings", {enabled: true}))
    ])

    const currentIds = new Set((await listRecords()).map(({id}) => id))
    assert.equal(currentIds.has("settings:privacy"), true)
    assert.equal(currentIds.has("settings:auto-sync"), true)

    const reopened = createCanonicalIndexedDB(native)
    await withIndexedDB(reopened, async () => {
      const durableIds = new Set((await listRecords()).map(({id}) => id))
      assert.equal(durableIds.has("settings:privacy"), true)
      assert.equal(durableIds.has("settings:auto-sync"), true)
    })
  })
})
