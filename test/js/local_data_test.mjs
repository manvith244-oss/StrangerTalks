import assert from "node:assert/strict"
import test from "node:test"
import {decryptBackup, encryptBackup, mergeRecords, validEnvelope} from "../../priv/static/assets/local_data.mjs"

test("encrypted backup round trips through a versioned PBKDF2/AES-GCM envelope", async () => {
  const records = [{id: "note:1", type: "memory", value: "private", updated_at: "2026-08-05T00:00:00Z"}]
  const envelope = await encryptBackup(records, "correct horse battery staple")
  assert.equal(validEnvelope(envelope), true)
  assert.deepEqual(await decryptBackup(envelope, "correct horse battery staple"), records)
  await assert.rejects(() => decryptBackup(envelope, "wrong passphrase"))
})

test("import merge uses stable IDs and keeps the newest updated_at", () => {
  const old = {id: "note:1", type: "memory", value: "old", updated_at: "2026-08-05T00:00:00Z"}
  const newer = {...old, value: "new", updated_at: "2026-08-05T01:00:00Z"}
  const other = {id: "note:2", type: "memory", value: "other", updated_at: "2026-08-05T00:00:00Z"}
  assert.deepEqual(mergeRecords([old], [newer, other]), [newer, other])
})

test("invalid backup versions and structures are rejected", () => {
  assert.equal(validEnvelope({version: 2}), false)
  assert.equal(validEnvelope({version: 1, kdf: "PBKDF2-SHA256", cipher: "AES-GCM"}), false)
})
