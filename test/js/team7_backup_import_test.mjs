import assert from "node:assert/strict"
import test from "node:test"
import {decryptBackup, encryptBackup, mergeRecords, validEnvelope} from "../../priv/static/assets/local_data.mjs"

const time = "2026-08-24T00:00:00.000Z"

function encode(bytes) {
  let binary = ""
  bytes.forEach((byte) => { binary += String.fromCharCode(byte) })
  return btoa(binary)
}

async function rawEnvelope(records, passphrase = "backup-passphrase") {
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const material = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(passphrase),
    "PBKDF2",
    false,
    ["deriveKey"]
  )
  const key = await crypto.subtle.deriveKey(
    {name: "PBKDF2", hash: "SHA-256", salt, iterations: 210000},
    material,
    {name: "AES-GCM", length: 256},
    false,
    ["encrypt"]
  )
  const plaintext = new TextEncoder().encode(JSON.stringify({records}))
  const ciphertext = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, plaintext)
  return {
    version: 2,
    kdf: "PBKDF2-SHA256",
    iterations: 210000,
    cipher: "AES-GCM",
    salt: encode(salt),
    iv: encode(iv),
    ciphertext: encode(new Uint8Array(ciphertext))
  }
}

function memory(id = "memory:1", updated_at = time) {
  return {id, type: "memory", value: {text: "mine"}, updated_at}
}

test("backup decryption rejects unknown and safety-owned record types before import", async () => {
  for (const type of ["future_category", "safety_review", "boundary_block", "safety_event", "report"]) {
    const envelope = await rawEnvelope([{id: `${type}:1`, type, value: {private: true}, updated_at: time}])
    await assert.rejects(() => decryptBackup(envelope, "backup-passphrase"), /invalid_backup/)
  }
})

test("backup validates the complete payload including the final record before accepted restore", async () => {
  const validPrefix = [memory("memory:1"), memory("memory:2"), memory("memory:3")]
  const finalInvalid = {id: "", type: "memory", value: {text: "late invalid"}, updated_at: time}
  const envelope = await rawEnvelope([...validPrefix, finalInvalid])

  await assert.rejects(() => decryptBackup(envelope, "backup-passphrase"), /invalid_backup/)
})

test("backup rejects duplicate IDs, malformed IDs, malformed timestamps and malformed tombstones", async () => {
  const invalidPayloads = [
    [memory("memory:dup"), memory("memory:dup")],
    [memory("   ")],
    [memory(`memory:${"x".repeat(300)}`)],
    [memory("memory:bad-time", "not-a-time")],
    [{
      id: "memory:deleted",
      type: "sync_tombstone",
      category: "tombstones",
      value: {previous_type: "memory"},
      updated_at: time,
      deleted_at: time
    }],
    [{
      id: "memory:deleted",
      type: "sync_tombstone",
      category: "not-tombstones",
      value: {previous_type: "memory", previous_category: "memories"},
      updated_at: time,
      deleted_at: time
    }]
  ]

  for (const records of invalidPayloads) {
    const envelope = await rawEnvelope(records)
    await assert.rejects(() => decryptBackup(envelope, "backup-passphrase"), /invalid_backup/)
  }
})

test("backup rejects malformed retained payload shapes and broken record references", async () => {
  const malformed = [
    {id: "memory:bad-shape", type: "memory", value: {text: "looks valid", queue_attempt_id: "must-not-enter-retention"}, updated_at: time},
    {id: "memory:missing-text", type: "memory", value: {conversation_id: "c1"}, updated_at: time},
    {id: "summary:wrong-id", type: "summary", value: {conversation_id: "different-conversation", text: "summary"}, updated_at: time},
    {id: "conversation:wrong-id", type: "local_conversation", value: {conversation_id: "real-id", door_type: "EXPLORE", display_door: "Advice", abstract_signature_seed: "sig-1", status: "kept", connection_state: "ended", started_at: time, ended_at: time, summary_id: null}, updated_at: time},
    {id: "message:c1:wrong", type: "local_message", value: {conversation_id: "c1", client_message_id: "actual", message_id: "actual", type: "text", content: "bad ref", expressive: null, mine: true, delivery_status: "sent", sent_at: time, sequence: 1, content_revision: 0, peer_applied_content_revision: null, edited: false, availability: "available", unsent: false, reply_to_client_message_id: null, reply_author_relation: null, reply_snippet: null, reply_target_availability: null, self_reaction: null, peer_reaction: null, view_once_state: null, presentation_limit: 1, views_remaining: 1, views_consumed: 0, media_type: null, byte_size: null}, updated_at: time},
    {id: "relationship:wrong-id", type: "relationship", value: {relationship_id: "real-relationship", status: "created", conversation_id: "c1"}, updated_at: time},
    {id: "relationship:missing", type: "relationship", value: {status: "created", conversation_id: "c1"}, updated_at: time}
  ]

  for (const record of malformed) {
    const envelope = await rawEnvelope([record])
    await assert.rejects(() => decryptBackup(envelope, "backup-passphrase"), /invalid_backup/)
  }
})

test("backup envelope contract rejects unsupported version, iteration drift and malformed envelope", async () => {
  const envelope = await rawEnvelope([memory()])
  assert.equal(validEnvelope(envelope), true)
  assert.equal(validEnvelope({...envelope, version: 99}), false)
  assert.equal(validEnvelope({...envelope, iterations: 1}), false)
  assert.equal(validEnvelope({...envelope, salt: ""}), false)
  assert.equal(validEnvelope({...envelope, iv: ""}), false)
  assert.equal(validEnvelope({...envelope, ciphertext: ""}), false)

  await assert.rejects(() => decryptBackup({...envelope, version: 99}, "backup-passphrase"), /invalid_backup/)
})

test("backup crypto uses randomized salt and IV, hides plaintext, rejects wrong passphrase and tampering", async () => {
  const records = [memory()]
  const first = await encryptBackup(records, "correct horse battery staple")
  const second = await encryptBackup(records, "correct horse battery staple")

  assert.equal(first.kdf, "PBKDF2-SHA256")
  assert.equal(first.iterations, 210000)
  assert.equal(first.cipher, "AES-GCM")
  assert.notEqual(first.salt, second.salt)
  assert.notEqual(first.iv, second.iv)
  assert.equal(JSON.stringify(first).includes("mine"), false)
  assert.equal(JSON.stringify(first).includes("correct horse battery staple"), false)
  assert.deepEqual(await decryptBackup(first, "correct horse battery staple"), records)
  await assert.rejects(() => decryptBackup(first, "wrong passphrase"))

  const tampered = {...first, ciphertext: `${first.ciphertext.slice(0, -2)}AA`}
  await assert.rejects(() => decryptBackup(tampered, "correct horse battery staple"))
})

test("backup decryption still accepts approved retained local categories", async () => {
  const record = memory()
  assert.deepEqual(await decryptBackup(await rawEnvelope([record]), "backup-passphrase"), [record])
})

test("import merge cannot resurrect a tombstoned record with a later live timestamp", () => {
  const deleted = {
    id: "memory:1",
    type: "sync_tombstone",
    category: "tombstones",
    value: {previous_type: "memory", previous_category: "memories"},
    updated_at: "2026-08-24T00:01:00.000Z",
    deleted_at: "2026-08-24T00:01:00.000Z"
  }
  const staleLive = {
    id: "memory:1",
    type: "memory",
    value: {text: "stale device copy"},
    updated_at: "2026-08-24T00:02:00.000Z"
  }

  assert.deepEqual(mergeRecords([deleted], [staleLive]), [deleted])
  assert.deepEqual(mergeRecords([staleLive], [deleted]), [deleted])
  assert.deepEqual(mergeRecords([deleted], [staleLive], {restoreTombstones: true}), [staleLive])
})