const SYNC_KIND = "strangertalks_encrypted_sync"
const SYNC_VERSION = 1
const ITERATIONS = 210000
const KEY_DB = "strangertalks-sync-key-v1"
const KEY_STORE = "keys"
const ALLOWED_TYPES = new Set(["local_conversation", "local_message", "summary", "memory", "relationship", "settings", "sync_tombstone"])

export function syncableRecords(records) {
  const kept = new Set(records.filter((record) => record.type === "local_conversation" && ["kept", "summary_only"].includes(record.value?.status)).map((record) => record.value.conversation_id))
  return records.filter((record) => {
    if (!ALLOWED_TYPES.has(record.type)) return false
    if (record.type === "local_message") return kept.has(record.value?.conversation_id)
    if (record.type === "local_conversation") return kept.has(record.value?.conversation_id)
    return true
  }).map((record) => ({...record, deleted_at: record.deleted_at || null}))
}

export function validateSyncRecords(records) {
  return Array.isArray(records) && records.every((record) => record && typeof record.id === "string" && ALLOWED_TYPES.has(record.type) && validTime(record.updated_at) && (record.deleted_at === null || record.deleted_at === undefined || validTime(record.deleted_at)))
}

export function mergeSyncRecords(local, remote, {restoreTombstones = false} = {}) {
  if (!validateSyncRecords(local) || !validateSyncRecords(remote)) throw new Error("invalid_sync_records")
  const merged = new Map(local.map((record) => [record.id, record]))
  for (const candidate of remote) {
    const existing = merged.get(candidate.id)
    if (!existing) { merged.set(candidate.id, candidate); continue }
    if (existing.deleted_at && !candidate.deleted_at && !restoreTombstones) continue
    if (Date.parse(candidate.updated_at) > Date.parse(existing.updated_at)) merged.set(candidate.id, candidate)
  }
  return [...merged.values()]
}

export function tombstoneFor(record, deletedAt = new Date().toISOString()) {
  return {id: record.id, type: "sync_tombstone", value: {previous_type: record.type}, updated_at: deletedAt, deleted_at: deletedAt}
}

export async function encryptSync(records, passphrase, revision = 0, cryptoApi = crypto) {
  return (await encryptSyncBundle(records, passphrase, revision, cryptoApi)).envelope
}

export async function encryptSyncBundle(records, passphrase, revision = 0, cryptoApi = crypto) {
  if (!passphrase || !validateSyncRecords(records)) throw new Error("invalid_sync_input")
  const createdAt = new Date().toISOString()
  const syncKey = await cryptoApi.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt", "decrypt"])
  const contentIv = cryptoApi.getRandomValues(new Uint8Array(12))
  const plaintext = new TextEncoder().encode(JSON.stringify({records}))
  const ciphertext = await cryptoApi.subtle.encrypt({name: "AES-GCM", iv: contentIv}, syncKey, plaintext)
  const rawSyncKey = new Uint8Array(await cryptoApi.subtle.exportKey("raw", syncKey))
  const salt = cryptoApi.getRandomValues(new Uint8Array(16))
  const wrapIv = cryptoApi.getRandomValues(new Uint8Array(12))
  const wrappingKey = await deriveWrappingKey(passphrase, salt, ["encrypt"], cryptoApi)
  const wrapped = await cryptoApi.subtle.encrypt({name: "AES-GCM", iv: wrapIv}, wrappingKey, rawSyncKey)
  const persistentKey = await cryptoApi.subtle.importKey("raw", rawSyncKey, {name: "AES-GCM"}, false, ["encrypt", "decrypt"])
  rawSyncKey.fill(0)
  return {syncKey: persistentKey, envelope: {kind: SYNC_KIND, version: SYNC_VERSION, revision, created_at: createdAt, updated_at: createdAt, key_wrap: {algorithm: "AES-GCM", hash: "SHA-256", iterations: ITERATIONS, salt: encode(salt), iv: encode(wrapIv), wrapped_sync_key: encode(new Uint8Array(wrapped))}, content: {algorithm: "AES-GCM", iv: encode(contentIv), ciphertext: encode(new Uint8Array(ciphertext))}}}
}

export async function decryptSync(envelope, passphrase, cryptoApi = crypto) {
  return (await unlockSync(envelope, passphrase, cryptoApi)).records
}

export async function unlockSync(envelope, passphrase, cryptoApi = crypto) {
  if (!validSyncEnvelope(envelope) || !passphrase) throw new Error("invalid_sync_envelope")
  const wrappingKey = await deriveWrappingKey(passphrase, decode(envelope.key_wrap.salt), ["decrypt"], cryptoApi)
  const raw = new Uint8Array(await cryptoApi.subtle.decrypt({name: "AES-GCM", iv: decode(envelope.key_wrap.iv)}, wrappingKey, decode(envelope.key_wrap.wrapped_sync_key)))
  const syncKey = await cryptoApi.subtle.importKey("raw", raw, {name: "AES-GCM"}, false, ["encrypt", "decrypt"])
  raw.fill(0)
  const records = await decryptSyncWithKey(envelope, syncKey, cryptoApi)
  return {records, syncKey}
}

export async function decryptSyncWithKey(envelope, syncKey, cryptoApi = crypto) {
  if (!validSyncEnvelope(envelope) || !syncKey) throw new Error("invalid_sync_envelope")
  const plaintext = await cryptoApi.subtle.decrypt({name: "AES-GCM", iv: decode(envelope.content.iv)}, syncKey, decode(envelope.content.ciphertext))
  const payload = JSON.parse(new TextDecoder().decode(plaintext))
  if (!validateSyncRecords(payload.records)) throw new Error("invalid_sync_records")
  return payload.records
}

export async function encryptSyncWithKey(records, syncKey, previousEnvelope, revision, cryptoApi = crypto) {
  if (!validateSyncRecords(records) || !syncKey || !validSyncEnvelope(previousEnvelope)) throw new Error("invalid_sync_input")
  const iv = cryptoApi.getRandomValues(new Uint8Array(12))
  const plaintext = new TextEncoder().encode(JSON.stringify({records}))
  const ciphertext = await cryptoApi.subtle.encrypt({name: "AES-GCM", iv}, syncKey, plaintext)
  return {...previousEnvelope, revision, updated_at: new Date().toISOString(), content: {algorithm: "AES-GCM", iv: encode(iv), ciphertext: encode(new Uint8Array(ciphertext))}}
}

export function validSyncEnvelope(envelope) {
  return envelope?.kind === SYNC_KIND && envelope.version === SYNC_VERSION && Number.isInteger(envelope.revision) && envelope.revision >= 0 && envelope.key_wrap?.algorithm === "AES-GCM" && envelope.key_wrap?.hash === "SHA-256" && envelope.key_wrap?.iterations === ITERATIONS && envelope.content?.algorithm === "AES-GCM" && [envelope.key_wrap.salt, envelope.key_wrap.iv, envelope.key_wrap.wrapped_sync_key, envelope.content.iv, envelope.content.ciphertext].every((value) => typeof value === "string" && value.length > 0)
}

export async function supportsPersistentCryptoKey(indexedDb = indexedDB, cryptoApi = crypto) {
  try {
    const key = await cryptoApi.subtle.generateKey({name: "AES-GCM", length: 256}, false, ["encrypt", "decrypt"])
    await keyRequest(indexedDb, "readwrite", (store) => store.put(key, "probe"))
    const restored = await keyRequest(indexedDb, "readonly", (store) => store.get("probe"))
    await keyRequest(indexedDb, "readwrite", (store) => store.delete("probe"))
    return restored instanceof CryptoKey
  } catch { return false }
}

export async function storeSyncKey(key, indexedDb = indexedDB) { return keyRequest(indexedDb, "readwrite", (store) => store.put(key, "account")) }
export async function loadSyncKey(indexedDb = indexedDB) { return keyRequest(indexedDb, "readonly", (store) => store.get("account")) }

async function deriveWrappingKey(passphrase, salt, usages, cryptoApi) { const material = await cryptoApi.subtle.importKey("raw", new TextEncoder().encode(passphrase), "PBKDF2", false, ["deriveKey"]); return cryptoApi.subtle.deriveKey({name: "PBKDF2", hash: "SHA-256", salt, iterations: ITERATIONS}, material, {name: "AES-GCM", length: 256}, false, usages) }
function validTime(value) { return typeof value === "string" && !Number.isNaN(Date.parse(value)) }
function encode(bytes) { let binary = ""; bytes.forEach((byte) => { binary += String.fromCharCode(byte) }); return btoa(binary) }
function decode(value) { const binary = atob(value); return Uint8Array.from(binary, (char) => char.charCodeAt(0)) }
function keyRequest(indexedDb, mode, action) { return new Promise((resolve, reject) => { const opening = indexedDb.open(KEY_DB, 1); opening.onupgradeneeded = () => opening.result.createObjectStore(KEY_STORE); opening.onerror = () => reject(opening.error); opening.onsuccess = () => { const transaction = opening.result.transaction(KEY_STORE, mode); const request = action(transaction.objectStore(KEY_STORE)); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); transaction.oncomplete = () => opening.result.close() } }) }
