const SYNC_KIND = "strangertalks_encrypted_sync"
const SYNC_VERSION = 1
const ITERATIONS = 210000
const KEY_DB = "strangertalks-sync-key-v1"
const KEY_STORE = "keys"
export const SYNC_CATEGORIES = Object.freeze(["kept_conversations", "kept_messages", "summaries", "memories", "bonds", "bond_nicknames", "abstract_signature_seeds", "accessibility_settings", "privacy_settings", "user_preferences", "tombstones"])
export const SYNC_SETTINGS_KEYS = Object.freeze(["settings:privacy", "settings:auto-sync"])
const ALLOWED_CATEGORIES = new Set(SYNC_CATEGORIES)
const MAX_ID_LENGTH = 256
const MAX_RECORD_BYTES = 256 * 1024
const MAX_DEPTH = 6
const FUTURE_SKEW_MS = 24 * 60 * 60 * 1000
const FORBIDDEN_KEYS = new Set(["__proto__", "constructor", "prototype", "token", "authorization", "csrf_token", "session_token", "participant_token", "access_token", "refresh_token", "id_token"])

export function syncableRecords(records) {
  const kept = new Set(records.filter((record) => record.type === "local_conversation" && ["kept", "summary_only"].includes(record.value?.status)).map((record) => record.value.conversation_id))
  return records.filter((record) => {
    if (!categoryFor(record)) return false
    if (record.type === "local_message") return kept.has(record.value?.conversation_id)
    if (record.type === "local_conversation") return kept.has(record.value?.conversation_id)
    return true
  }).map((record) => ({...record, category: categoryFor(record), deleted_at: record.deleted_at || null}))
}

export function validateSyncRecords(records, validationNow = Date.now()) {
  if (!Array.isArray(records)) return false
  const ids = new Set()
  return records.every((record) => {
    if (!plainObject(record) || !onlyKeys(record, ["id", "type", "category", "value", "updated_at", "deleted_at"])) return false
    if (typeof record.id !== "string" || !record.id.trim() || record.id.length > MAX_ID_LENGTH) return false
    if (!ALLOWED_CATEGORIES.has(record.category) || categoryFor(record) !== record.category) return false
    const key = `${record.category}:${record.id}`
    if (ids.has(key)) return false
    ids.add(key)
    if (!validTime(record.updated_at, validationNow) || (record.deleted_at !== null && record.deleted_at !== undefined && !validTime(record.deleted_at, validationNow))) return false
    if (!safeValue(record.value, 0) || new TextEncoder().encode(JSON.stringify(record)).byteLength > MAX_RECORD_BYTES) return false
    return validCategoryShape(record)
  })
}

export async function mergeSyncRecords(local, remote, {restoreTombstones = false, validationNow = Date.now(), cryptoApi = crypto} = {}) {
  if (!validateSyncRecords(local, validationNow) || !validateSyncRecords(remote, validationNow)) throw new Error("invalid_sync_records")
  const merged = new Map(local.map((record) => [record.id, record]))
  for (const candidate of remote) {
    const existing = merged.get(candidate.id)
    if (!existing) { merged.set(candidate.id, candidate); continue }
    const existingDeleted = Boolean(existing.deleted_at)
    const candidateDeleted = Boolean(candidate.deleted_at)
    if (!restoreTombstones && existingDeleted !== candidateDeleted) {
      merged.set(candidate.id, existingDeleted ? existing : candidate)
      continue
    }
    const candidateTime = Date.parse(candidate.updated_at)
    const existingTime = Date.parse(existing.updated_at)
    if (candidateTime > existingTime) merged.set(candidate.id, candidate)
    else if (candidateTime === existingTime) merged.set(candidate.id, await deterministicWinner(existing, candidate, cryptoApi))
  }
  return [...merged.values()]
}

export function tombstoneFor(record, deletedAt = new Date().toISOString()) {
  return {id: record.id, type: "sync_tombstone", category: "tombstones", value: {previous_type: record.type, previous_category: record.category || categoryFor(record)}, updated_at: deletedAt, deleted_at: deletedAt}
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

export async function storeSyncKey(key, accountContinuityId, indexedDb = indexedDB) { if (!accountContinuityId) throw new Error("account_continuity_required"); return keyRequest(indexedDb, "readwrite", (store) => store.put(key, `account:${accountContinuityId}`)) }
export async function loadSyncKey(accountContinuityId, indexedDb = indexedDB) { if (!accountContinuityId) return null; return keyRequest(indexedDb, "readonly", (store) => store.get(`account:${accountContinuityId}`)) }

async function deriveWrappingKey(passphrase, salt, usages, cryptoApi) { const material = await cryptoApi.subtle.importKey("raw", new TextEncoder().encode(passphrase), "PBKDF2", false, ["deriveKey"]); return cryptoApi.subtle.deriveKey({name: "PBKDF2", hash: "SHA-256", salt, iterations: ITERATIONS}, material, {name: "AES-GCM", length: 256}, false, usages) }
function validTime(value, validationNow = Date.now()) { const parsed = typeof value === "string" ? Date.parse(value) : NaN; return Number.isFinite(parsed) && parsed <= validationNow + FUTURE_SKEW_MS }
function categoryFor(record) {
  if (record?.type === "local_conversation" && ["kept", "summary_only"].includes(record.value?.status)) return "kept_conversations"
  if (record?.type === "local_message") return "kept_messages"
  if (record?.type === "summary") return "summaries"
  if (record?.type === "memory") return "memories"
  if (record?.type === "relationship") return "bonds"
  if (record?.type === "settings" && record.id === "settings:privacy") return "accessibility_settings"
  if (record?.type === "settings" && record.id === "settings:auto-sync") return "user_preferences"
  if (record?.type === "sync_tombstone") return "tombstones"
  return null
}
function validCategoryShape(record) {
  if (record.category === "tombstones") return onlyKeys(record.value, ["previous_type", "previous_category"]) && typeof record.value.previous_type === "string" && ALLOWED_CATEGORIES.has(record.value.previous_category)
  if (record.category === "accessibility_settings") return record.id === "settings:privacy" && onlyKeys(record.value, ["reduced_motion"]) && typeof record.value.reduced_motion === "boolean"
  if (record.category === "user_preferences") return record.id === "settings:auto-sync" && onlyKeys(record.value, ["enabled"]) && typeof record.value.enabled === "boolean"
  if (record.category === "privacy_settings") return false
  return plainObject(record.value)
}
function safeValue(value, depth) {
  if (depth > MAX_DEPTH || typeof value === "function" || typeof value === "symbol" || typeof value === "bigint") return false
  if (typeof value === "number") return Number.isFinite(value)
  if (value === null || ["string", "boolean"].includes(typeof value)) return true
  if (Array.isArray(value)) return value.every((item) => safeValue(item, depth + 1))
  if (!plainObject(value)) return false
  return Object.keys(value).every((key) => !FORBIDDEN_KEYS.has(key.toLowerCase()) && safeValue(value[key], depth + 1))
}
function plainObject(value) { if (!value || typeof value !== "object" || Array.isArray(value)) return false; const prototype = Object.getPrototypeOf(value); return prototype === Object.prototype || prototype === null }
function onlyKeys(value, allowed) { return plainObject(value) && Object.keys(value).every((key) => allowed.includes(key)) }
async function deterministicWinner(first, second, cryptoApi) {
  if (Boolean(first.deleted_at) !== Boolean(second.deleted_at)) return first.deleted_at ? first : second
  const [firstHash, secondHash] = await Promise.all([canonicalHash(first, cryptoApi), canonicalHash(second, cryptoApi)])
  return firstHash >= secondHash ? first : second
}
async function canonicalHash(value, cryptoApi) { const bytes = new TextEncoder().encode(canonicalJson(value)); return encode(new Uint8Array(await cryptoApi.subtle.digest("SHA-256", bytes))) }
function canonicalJson(value) { if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`; if (plainObject(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`; return JSON.stringify(value) }
function encode(bytes) { let binary = ""; bytes.forEach((byte) => { binary += String.fromCharCode(byte) }); return btoa(binary) }
function decode(value) { const binary = atob(value); return Uint8Array.from(binary, (char) => char.charCodeAt(0)) }
function keyRequest(indexedDb, mode, action) { return new Promise((resolve, reject) => { const opening = indexedDb.open(KEY_DB, 1); opening.onupgradeneeded = () => opening.result.createObjectStore(KEY_STORE); opening.onerror = () => reject(opening.error); opening.onsuccess = () => { const transaction = opening.result.transaction(KEY_STORE, mode); const request = action(transaction.objectStore(KEY_STORE)); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); transaction.oncomplete = () => opening.result.close() } }) }
