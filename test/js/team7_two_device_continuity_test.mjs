import assert from "node:assert/strict"
import test from "node:test"
import {
  decryptSyncWithKey,
  encryptSyncBundle,
  encryptSyncWithKey,
  mergeSyncRecords,
  syncableRecords,
  tombstoneFor,
  unlockSync
} from "../../priv/static/assets/encrypted_sync.mjs"
import {atomicReplaceRecords} from "../../priv/static/assets/local_data.mjs"

const t = (minute) => `2026-08-24T12:${String(minute).padStart(2, "0")}:00.000Z`

function isolatedDevice(seed = []) {
  let records = structuredClone(seed)
  return {
    get records() { return structuredClone(records) },
    adapter: {
      async run(operations) {
        let staged = structuredClone(records)
        for (const operation of operations) {
          if (operation.action === "clear") staged = []
          else if (operation.action === "put") {
            const index = staged.findIndex(({id}) => id === operation.record.id)
            if (index >= 0) staged[index] = structuredClone(operation.record)
            else staged.push(structuredClone(operation.record))
          } else {
            throw new Error(`unknown_operation:${operation.action}`)
          }
        }
        records = staged
      }
    }
  }
}

async function replaceSyncedSubset(device, syncedRecords) {
  const local = device.records
  const selectedIds = new Set(syncableRecords(local).map(({id}) => id))
  const next = [...local.filter((record) => !selectedIds.has(record.id)), ...syncedRecords]
  await atomicReplaceRecords(next, device.adapter)
}

function approvedSeed() {
  return [
    {
      id: "conversation:kept-1",
      type: "local_conversation",
      value: {conversation_id: "kept-1", status: "kept", abstract_signature_seed: "sig-private"},
      updated_at: t(0)
    },
    {
      id: "message:kept-1:m1",
      type: "local_message",
      value: {conversation_id: "kept-1", content: "retained transcript"},
      updated_at: t(0)
    },
    {
      id: "summary:kept-1",
      type: "summary",
      value: {conversation_id: "kept-1", text: "private summary"},
      updated_at: t(0)
    },
    {
      id: "memory:m1",
      type: "memory",
      value: {text: "private memory"},
      updated_at: t(0)
    },
    {
      id: "relationship:r1",
      type: "relationship",
      value: {relationship_id: "r1", private_label: "Quiet Comet", status: "ACTIVE"},
      updated_at: t(0)
    },
    {
      id: "settings:auto-sync",
      type: "settings",
      value: {enabled: true},
      updated_at: t(0)
    }
  ]
}

function forbiddenSeed() {
  return [
    {
      id: "conversation:active-1",
      type: "local_conversation",
      value: {conversation_id: "active-1", status: "temporary", connection_state: "connected"},
      updated_at: t(0)
    },
    {
      id: "message:active-1:m1",
      type: "local_message",
      value: {conversation_id: "active-1", content: "active delivery state"},
      updated_at: t(0)
    },
    {id: "voice:kept-1:v1", type: "local_voice_note", value: {conversation_id: "kept-1", blob: "raw voice"}, updated_at: t(0)},
    {id: "queue:q1", type: "queue_state", value: {position: 1}, updated_at: t(0)},
    {id: "report:r1", type: "report", value: {reason: "private report"}, updated_at: t(0)},
    {id: "safety-review:s1", type: "safety_review", value: {status: "OPEN"}, updated_at: t(0)},
    {id: "boundary-block:b1", type: "boundary_block", value: {active: true}, updated_at: t(0)},
    {id: "safety-event:e1", type: "safety_event", value: {kind: "BLOCK"}, updated_at: t(0)},
    {id: "oauth:o1", type: "oauth_identity", value: {email: "private@example.com", provider_subject: "google-subject", access_token: "oauth-secret"}, updated_at: t(0)},
    {id: "call-media:c1", type: "voice_call_media", value: {raw_audio: "call bytes"}, updated_at: t(0)},
    {id: "analytics:a1", type: "analytics_record", value: {memory_text: "private memory"}, updated_at: t(0)},
    {id: "learning:l1", type: "learning_record", value: {summary_text: "private summary"}, updated_at: t(0)}
  ]
}

function byId(records, id) {
  return records.find((record) => record.id === id)
}

test("Device A -> Device B -> Device A continuity uses the real encrypted-sync and restore primitives", async () => {
  const deviceA = isolatedDevice([...approvedSeed(), ...forbiddenSeed()])
  const deviceB = isolatedDevice()
  const passphrase = "team7-provider-independent-continuity"

  // DEVICE A -> R1. Only the canonical allowlist may leave the device.
  const r1Records = syncableRecords(deviceA.records)
  assert.deepEqual(
    r1Records.map(({id}) => id).sort(),
    [
      "conversation:kept-1",
      "memory:m1",
      "message:kept-1:m1",
      "relationship:r1",
      "settings:auto-sync",
      "summary:kept-1"
    ].sort()
  )

  const forbiddenIds = new Set(forbiddenSeed().map(({id}) => id))
  assert.equal(r1Records.some(({id}) => forbiddenIds.has(id)), false)

  const {envelope: r1, syncKey: keyA} = await encryptSyncBundle(r1Records, passphrase, 1)
  const serializedR1 = JSON.stringify(r1)
  for (const plaintext of [
    "retained transcript",
    "private summary",
    "private memory",
    "Quiet Comet",
    "private@example.com",
    "google-subject",
    "oauth-secret",
    "raw voice",
    "private report"
  ]) {
    assert.equal(serializedR1.includes(plaintext), false, `${plaintext} is not plaintext in R1`)
  }

  // DEVICE B deliberately unlocks and restores R1 using the actual atomic restore primitive.
  const unlockedB = await unlockSync(r1, passphrase)
  await atomicReplaceRecords(unlockedB.records, deviceB.adapter)
  assert.deepEqual(deviceB.records, r1Records)

  // B legitimately updates an allowed retained Memory and produces R2 with the shared key.
  const bR2Records = deviceB.records.map((record) =>
    record.id === "memory:m1"
      ? {...record, value: {...record.value, text: "memory updated on B"}, updated_at: t(2)}
      : record
  )
  await replaceSyncedSubset(deviceB, bR2Records)
  const r2 = await encryptSyncWithKey(syncableRecords(deviceB.records), unlockedB.syncKey, r1, 2)

  // DEVICE A receives/decrypts R2 and uses the same selected-subset merge contract as the client.
  const remoteR2 = await decryptSyncWithKey(r2, keyA)
  const mergedA = await mergeSyncRecords(syncableRecords(deviceA.records), remoteR2)
  await replaceSyncedSubset(deviceA, mergedA)
  assert.equal(byId(deviceA.records, "memory:m1").value.text, "memory updated on B")
  assert.equal(forbiddenSeed().every(({id}) => byId(deviceA.records, id)), true, "non-sync local state was not silently deleted")

  // A deletes Memory and independently updates the summary, then produces R3.
  const selectedA = syncableRecords(deviceA.records)
  const liveMemoryA = byId(selectedA, "memory:m1")
  const tombstone = tombstoneFor(liveMemoryA, t(3))
  const aR3Records = selectedA
    .filter(({id}) => id !== "memory:m1")
    .map((record) =>
      record.id === "summary:kept-1"
        ? {...record, value: {...record.value, text: "summary updated on A"}, updated_at: t(4)}
        : record
    )
    .concat(tombstone)
  await replaceSyncedSubset(deviceA, aR3Records)
  const r3 = await encryptSyncWithKey(syncableRecords(deviceA.records), keyA, r2, 3)

  // B is stale: it edits the deleted Memory with an even newer timestamp and also
  // performs an unrelated legitimate Bond/private-metadata update.
  const staleB = syncableRecords(deviceB.records).map((record) => {
    if (record.id === "memory:m1") {
      return {...record, value: {...record.value, text: "stale B resurrection attempt"}, updated_at: t(8)}
    }
    if (record.id === "relationship:r1") {
      return {...record, value: {...record.value, private_label: "Quiet Nova"}, updated_at: t(7)}
    }
    return record
  })

  const remoteR3 = await decryptSyncWithKey(r3, unlockedB.syncKey)
  const convergedB = await mergeSyncRecords(staleB, remoteR3)
  await replaceSyncedSubset(deviceB, convergedB)

  const memoryWinner = byId(deviceB.records, "memory:m1")
  assert.equal(memoryWinner.type, "sync_tombstone")
  assert.equal(memoryWinner.deleted_at, t(3))
  assert.equal(byId(deviceB.records, "relationship:r1").value.private_label, "Quiet Nova")
  assert.equal(byId(deviceB.records, "summary:kept-1").value.text, "summary updated on A")

  // B's converged R4 contains the tombstone and unrelated legitimate update.
  const bR4 = await encryptSyncWithKey(syncableRecords(deviceB.records), unlockedB.syncKey, r3, 4)
  const remoteR4 = await decryptSyncWithKey(bR4, keyA)
  const selectedAAfterR3 = syncableRecords(deviceA.records)
  const convergedA = await mergeSyncRecords(selectedAAfterR3, remoteR4)
  await replaceSyncedSubset(deviceA, convergedA)

  assert.equal(byId(deviceA.records, "memory:m1").type, "sync_tombstone")
  assert.equal(byId(deviceA.records, "relationship:r1").value.private_label, "Quiet Nova")
  assert.equal(syncableRecords(deviceA.records).some(({id}) => forbiddenIds.has(id)), false)
  assert.equal(forbiddenSeed().every(({id}) => byId(deviceA.records, id)), true, "excluded local categories stayed local")
})
