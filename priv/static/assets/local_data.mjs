const DB_NAME = "strangertalks-local-v1"
const STORE = "records"
const BACKUP_VERSION = 2
const PREVIOUS_BACKUP_VERSION = 1
const APPROVED_VOICE_TYPES = new Set(["audio/webm", "audio/ogg", "audio/mp4"])

export function signatureSeedFor(conversationId) {
  let hash = 2166136261
  for (const character of conversationId) {
    hash ^= character.charCodeAt(0)
    hash = Math.imul(hash, 16777619)
  }
  return `sig-${(hash >>> 0).toString(16).padStart(8, "0")}`
}

export function temporaryConversation({conversation_id, door_type, display_door, started_at}) {
  return {
    id: `conversation:${conversation_id}`,
    type: "local_conversation",
    value: {
      conversation_id,
      door_type,
      display_door,
      abstract_signature_seed: signatureSeedFor(conversation_id),
      status: "temporary",
      connection_state: "connected",
      started_at,
      ended_at: null,
      summary_id: null
    },
    updated_at: started_at
  }
}

export function localMessage({conversation_id, message_id, content, mine, delivery_status, sent_at, sequence}) {
  return {
    id: `message:${conversation_id}:${message_id}`,
    type: "local_message",
    value: {conversation_id, message_id, content, mine, delivery_status, sent_at, sequence},
    updated_at: sent_at
  }
}

export function localVoiceNote({conversation_id, voice_note_id, blob, mine, delivery_status, sent_at, sequence, duration_ms, byte_size, media_type}) {
  return {id: `voice:${conversation_id}:${voice_note_id}`, type: "local_voice_note", value: {conversation_id, voice_note_id, blob, mine, delivery_status, sent_at, sequence, duration_ms, byte_size, media_type}, updated_at: sent_at}
}

export function chooseConversationRetention(records, conversationId, choice, {summaryText, now} = {}) {
  const timestamp = now || new Date().toISOString()
  const conversationIdKey = `conversation:${conversationId}`
  const conversation = records.find(({id}) => id === conversationIdKey)
  if (!conversation) throw new Error("conversation_not_found")
  if (!new Set(["kept", "summary_only", "faded"]).has(choice)) throw new Error("invalid_retention_choice")
  if (choice === "summary_only" && !summaryText?.trim()) throw new Error("summary_required")

  const summaryId = `summary:${conversationId}`
  let next = records.filter((record) => record.id !== conversationIdKey)
  if (choice !== "kept") next = next.filter((record) => !(new Set(["local_message", "local_voice_note"]).has(record.type) && record.value.conversation_id === conversationId))
  if (choice === "faded") next = next.filter(({id}) => id !== summaryId)
  if (choice === "summary_only") {
    next = next.filter(({id}) => id !== summaryId)
    next.push({id: summaryId, type: "summary", value: {conversation_id: conversationId, text: summaryText.trim()}, updated_at: timestamp})
  }
  next.push({...conversation, value: {...conversation.value, status: choice, connection_state: "ended", ended_at: conversation.value.ended_at || timestamp, summary_id: choice === "summary_only" ? summaryId : choice === "faded" ? null : conversation.value.summary_id}, updated_at: timestamp})
  return next
}

export function keptConversations(records) {
  return records.filter((record) => record.type === "local_conversation" && record.value.status === "kept")
}

export function activeConversations(records) {
  return records.filter((record) => record.type === "local_conversation" && record.value.status === "temporary" && ["connected", "reconnecting", "recovery"].includes(record.value.connection_state))
}

export function deleteKeptConversation(records, conversationId, {deleteSummary = false} = {}) {
  const summaryId = `summary:${conversationId}`
  return records.filter((record) => {
    if (record.id === `conversation:${conversationId}`) return false
    if (new Set(["local_message", "local_voice_note"]).has(record.type) && record.value.conversation_id === conversationId) return false
    if (deleteSummary && record.id === summaryId) return false
    return true
  })
}

export function deleteAllKeptConversations(records, {deleteSummaries = false} = {}) {
  const keptIds = new Set(keptConversations(records).map((record) => record.value.conversation_id))
  return records.filter((record) => {
    if (record.type === "local_conversation" && keptIds.has(record.value.conversation_id)) return false
    if (new Set(["local_message", "local_voice_note"]).has(record.type) && keptIds.has(record.value.conversation_id)) return false
    if (deleteSummaries && record.type === "summary" && keptIds.has(record.value.conversation_id)) return false
    return true
  })
}

export function mergeRecords(current, imported) {
  const merged = new Map(current.map((record) => [record.id, record]))
  for (const record of imported) {
    const existing = merged.get(record.id)
    if (!existing || Date.parse(record.updated_at) > Date.parse(existing.updated_at)) merged.set(record.id, record)
  }
  return [...merged.values()]
}

export function validEnvelope(envelope) {
  return [PREVIOUS_BACKUP_VERSION, BACKUP_VERSION].includes(envelope?.version) && envelope.kdf === "PBKDF2-SHA256" && envelope.cipher === "AES-GCM" &&
    typeof envelope.salt === "string" && typeof envelope.iv === "string" && typeof envelope.ciphertext === "string"
}

export async function encryptBackup(records, passphrase) {
  if (!passphrase) throw new Error("passphrase_required")
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const key = await deriveKey(passphrase, salt, ["encrypt"])
  const plaintext = new TextEncoder().encode(JSON.stringify({records: await serializeBackupRecords(records)}))
  const ciphertext = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, plaintext)
  return {version: BACKUP_VERSION, kdf: "PBKDF2-SHA256", iterations: 210000, cipher: "AES-GCM", salt: encode(salt), iv: encode(iv), ciphertext: encode(new Uint8Array(ciphertext))}
}

export async function decryptBackup(envelope, passphrase) {
  if (!validEnvelope(envelope) || !passphrase) throw new Error("invalid_backup")
  const salt = decode(envelope.salt)
  const iv = decode(envelope.iv)
  const key = await deriveKey(passphrase, salt, ["decrypt"])
  const plaintext = await crypto.subtle.decrypt({name: "AES-GCM", iv}, key, decode(envelope.ciphertext))
  const payload = JSON.parse(new TextDecoder().decode(plaintext))
  if (!Array.isArray(payload.records)) throw new Error("invalid_backup")
  const records = await deserializeBackupRecords(payload.records, envelope.version)
  if (records.some((record) => !validRecord(record))) throw new Error("invalid_backup")
  return records
}

export async function getRecord(id) { return request("readonly", (store) => store.get(id)) }
export async function listRecords() { return request("readonly", (store) => store.getAll()) }
export async function putRecord(record) { if (!validRecord(record)) throw new Error("invalid_record"); return request("readwrite", (store) => store.put(record)) }
export async function deleteRecord(id) { return request("readwrite", (store) => store.delete(id)) }
export async function clearRecords() { return request("readwrite", (store) => store.clear()) }
export async function importRecords(imported) { const merged = mergeRecords(await listRecords(), imported); await clearRecords(); for (const record of merged) await putRecord(record); return merged }
export async function replaceRecords(records) { await clearRecords(); for (const record of records) await putRecord(record); return records }

function validRecord(record) { return record && typeof record.id === "string" && typeof record.type === "string" && !Number.isNaN(Date.parse(record.updated_at)) }
async function serializeBackupRecords(records) {
  const keptIds = new Set(keptConversations(records).map(({value}) => value.conversation_id))
  const selected = records.filter((record) => record.type !== "bond_reconnect_state" && (record.type !== "local_voice_note" || keptIds.has(record.value.conversation_id)))
  return Promise.all(selected.map(async (record) => {
    if (record.type !== "local_voice_note") return record
    const bytes = await binaryBytes(record.value.blob)
    return {...record, value: {...record.value, blob: undefined, encoded_audio: {version: 1, media_type: record.value.media_type, byte_size: bytes.byteLength, base64: encode(bytes)}}}
  }))
}
async function binaryBytes(value) {
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  if (value?.arrayBuffer) return new Uint8Array(await value.arrayBuffer())
  throw new Error("invalid_backup")
}
async function deserializeBackupRecords(records, version) {
  if (version === PREVIOUS_BACKUP_VERSION) return records
  return Promise.all(records.map(async (record) => {
    if (record.type !== "local_voice_note") return record
    const audio = record.value?.encoded_audio
    if (audio?.version !== 1 || !APPROVED_VOICE_TYPES.has(audio.media_type) || !Number.isInteger(audio.byte_size) || audio.byte_size < 1 || audio.byte_size > 1_048_576 || typeof audio.base64 !== "string") throw new Error("invalid_backup")
    let bytes
    try { bytes = decode(audio.base64) } catch { throw new Error("invalid_backup") }
    if (bytes.byteLength !== audio.byte_size) throw new Error("invalid_backup")
    return {...record, value: {...record.value, encoded_audio: undefined, blob: new Blob([bytes], {type: audio.media_type})}}
  }))
}
async function deriveKey(passphrase, salt, usages) { const material = await crypto.subtle.importKey("raw", new TextEncoder().encode(passphrase), "PBKDF2", false, ["deriveKey"]); return crypto.subtle.deriveKey({name: "PBKDF2", hash: "SHA-256", salt, iterations: 210000}, material, {name: "AES-GCM", length: 256}, false, usages) }
function encode(bytes) { let binary = ""; bytes.forEach((byte) => { binary += String.fromCharCode(byte) }); return btoa(binary) }
function decode(value) { const binary = atob(value); return Uint8Array.from(binary, (char) => char.charCodeAt(0)) }

function request(mode, action) {
  return new Promise((resolve, reject) => {
    const opening = indexedDB.open(DB_NAME, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(STORE, {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => {
      const transaction = opening.result.transaction(STORE, mode)
      const operation = action(transaction.objectStore(STORE))
      operation.onsuccess = () => resolve(operation.result)
      operation.onerror = () => reject(operation.error)
      transaction.oncomplete = () => opening.result.close()
    }
  })
}
