import assert from "node:assert/strict"
import test from "node:test"
import {decryptSync, encryptSync, mergeSyncRecords, syncableRecords, tombstoneFor, validSyncEnvelope, validateSyncRecords} from "../../priv/static/assets/encrypted_sync.mjs"

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

test("only deliberately retained categories sync and voice data never does", () => {
  const temporary = {...kept, id: "conversation:2", value: {conversation_id: "2", status: "temporary"}}
  const voice = {id: "voice:1", type: "local_voice_note", value: {conversation_id: "1", blob: new Blob(["voice"])}, updated_at: time}
  const identity = {id: "identity", type: "identity", value: {token: "secret"}, updated_at: time}
  const records = syncableRecords([kept, message, temporary, voice, identity])
  assert.deepEqual(records.map(({id}) => id), ["conversation:1", "message:1"])
  assert.equal(JSON.stringify(records).includes("secret"), false)
})

test("unknown and malformed record types fail before mutation", () => {
  assert.equal(validateSyncRecords([{id: "bad", type: "future", value: {}, updated_at: time}]), false)
  assert.throws(() => mergeSyncRecords([], [{id: "bad", type: "future", updated_at: time}]), /invalid_sync_records/)
})

test("newest timestamp wins while tombstones block accidental restoration", () => {
  const old = {id: "memory:1", type: "memory", value: {text: "old"}, updated_at: time, deleted_at: null}
  const newer = {...old, value: {text: "new"}, updated_at: "2026-08-06T01:00:00Z"}
  assert.deepEqual(mergeSyncRecords([old], [newer]), [newer])
  const tombstone = tombstoneFor(newer, "2026-08-06T02:00:00Z")
  const restored = {...newer, updated_at: "2026-08-06T03:00:00Z"}
  assert.deepEqual(mergeSyncRecords([tombstone], [restored]), [tombstone])
  assert.deepEqual(mergeSyncRecords([tombstone], [restored], {restoreTombstones: true}), [restored])
})
