import assert from "node:assert/strict"
import test from "node:test"
import {decryptSync, decryptSyncWithKey, encryptSync, encryptSyncBundle, encryptSyncWithKey, mergeSyncRecords, syncableRecords, tombstoneFor, unlockSync, validSyncEnvelope, validateSyncRecords} from "../../priv/static/assets/encrypted_sync.mjs"

const time = "2026-08-06T00:00:00Z"
const kept = {id: "conversation:1", type: "local_conversation", value: {conversation_id: "1", status: "kept"}, updated_at: time}
const message = {id: "message:1", type: "local_message", value: {conversation_id: "1", content: "kept"}, updated_at: time}

test("sync encryption round trips locally and exposes no plaintext", async () => {
  const records = syncableRecords([kept, message])
  const envelope = await encryptSync(records, "recovery words")
  assert.equal(validSyncEnvelope(envelope), true)
  assert.equal(JSON.stringify(envelope).includes("kept"), false)
  assert.deepEqual(await decryptSync(envelope, "recovery words"), records)
  await assert.rejects(() => decryptSync(envelope, "wrong words"))
})

test("an unlocked non-extractable key can update and reopen a later revision without retaining the passphrase", async () => {
  const records = syncableRecords([kept, message])
  const {envelope, syncKey} = await encryptSyncBundle(records, "recovery words")
  assert.equal(syncKey.extractable, false)
  const nextRecords = [...records, ...syncableRecords([{id: "memory:1", type: "memory", value: {text: "later"}, updated_at: time}])]
  const next = await encryptSyncWithKey(nextRecords, syncKey, envelope, 1)
  assert.deepEqual(await decryptSyncWithKey(next, syncKey), nextRecords)
  const unlocked = await unlockSync(next, "recovery words")
  assert.equal(unlocked.syncKey.extractable, false)
  assert.deepEqual(unlocked.records, nextRecords)
})

test("only deliberately retained categories sync and voice data never does", () => {
  const temporary = {...kept, id: "conversation:2", value: {conversation_id: "2", status: "temporary"}}
  const voice = {id: "voice:1", type: "local_voice_note", value: {conversation_id: "1", blob: new Blob(["voice"])}, updated_at: time}
  const identity = {id: "identity", type: "identity", value: {token: "secret"}, updated_at: time}
  const records = syncableRecords([kept, message, temporary, voice, identity])
  assert.deepEqual(records.map(({id}) => id), ["conversation:1", "message:1"])
  assert.equal(JSON.stringify(records).includes("secret"), false)
})

test("unknown and malformed record types fail before mutation", async () => {
  assert.equal(validateSyncRecords([{id: "bad", type: "future", value: {}, updated_at: time}]), false)
  await assert.rejects(() => mergeSyncRecords([], [{id: "bad", type: "future", updated_at: time}]), /invalid_sync_records/)
})

test("tombstones remain authoritative over later stale live copies unless restore is explicit", async () => {
  const [old] = syncableRecords([{id: "memory:1", type: "memory", value: {text: "old"}, updated_at: time}])
  const newer = {...old, value: {text: "new"}, updated_at: "2026-08-06T01:00:00Z"}
  assert.deepEqual(await mergeSyncRecords([old], [newer]), [newer])

  const tombstone = tombstoneFor(newer, "2026-08-06T02:00:00Z")
  const staleDeviceCopy = {...newer, updated_at: "2026-08-06T03:00:00Z"}
  assert.deepEqual(await mergeSyncRecords([tombstone], [staleDeviceCopy]), [tombstone])
  assert.deepEqual(await mergeSyncRecords([staleDeviceCopy], [tombstone]), [tombstone])
  assert.deepEqual(await mergeSyncRecords([tombstone], [staleDeviceCopy], {restoreTombstones: true}), [staleDeviceCopy])
})

test("strict sync validation rejects unknown settings, future dates, duplicate IDs and security fields", () => {
  const [memory] = syncableRecords([{id: "memory:1", type: "memory", value: {text: "safe"}, updated_at: time}])
  assert.equal(validateSyncRecords([memory], Date.parse(time)), true)
  assert.equal(validateSyncRecords([memory, memory], Date.parse(time)), false)
  assert.equal(validateSyncRecords([{...memory, updated_at: "2026-08-08T00:00:01Z"}], Date.parse(time)), false)
  assert.equal(validateSyncRecords([{...memory, value: {token: "forbidden"}}], Date.parse(time)), false)
  assert.equal(syncableRecords([{id: "settings:voice-warning:v1", type: "settings", value: {voice_warning_version: 1}, updated_at: time}]).length, 0)
})

test("equal timestamps use tombstone precedence and canonical SHA-256 tie breaking", async () => {
  const [first] = syncableRecords([{id: "memory:tie", type: "memory", value: {text: "a"}, updated_at: time}])
  const second = {...first, value: {text: "b"}}
  const forward = await mergeSyncRecords([first], [second], {validationNow: Date.parse(time)})
  const reverse = await mergeSyncRecords([second], [first], {validationNow: Date.parse(time)})
  assert.deepEqual(forward, reverse)
  assert.deepEqual(await mergeSyncRecords([first], [tombstoneFor(first, time)], {validationNow: Date.parse(time)}), [tombstoneFor(first, time)])
})
