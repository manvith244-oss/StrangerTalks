import assert from "node:assert/strict"
import test from "node:test"
import {decryptBackup, mergeRecords} from "../../priv/static/assets/local_data.mjs"

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

test("backup decryption rejects unknown and safety-owned record types before import", async () => {
  for (const type of ["future_category", "safety_review", "boundary_block", "report"]) {
    const envelope = await rawEnvelope([{id: `${type}:1`, type, value: {private: true}, updated_at: time}])
    await assert.rejects(() => decryptBackup(envelope, "backup-passphrase"), /invalid_backup/)
  }
})

test("backup decryption still accepts approved retained local categories", async () => {
  const memory = {id: "memory:1", type: "memory", value: {text: "mine"}, updated_at: time}
  assert.deepEqual(await decryptBackup(await rawEnvelope([memory]), "backup-passphrase"), [memory])
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
