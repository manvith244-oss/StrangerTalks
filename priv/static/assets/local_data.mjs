const DB_NAME = "strangertalks-local-v1"
const STORE = "records"
const BACKUP_VERSION = 2
const PREVIOUS_BACKUP_VERSION = 1
const BACKUP_ITERATIONS = 210000
const MAX_RECORD_ID_LENGTH = 256
const APPROVED_VOICE_TYPES = new Set(["audio/webm", "audio/ogg", "audio/mp4"])
const TERMINAL_RETENTION_STATUSES = new Set(["kept", "summary_only", "faded"])
const BACKUP_RECORD_TYPES = new Set(["identity", "settings", "local_conversation", "local_message", "local_voice_note", "sync_cursor", "summary", "memory", "relationship", "sync_tombstone"])
const BACKUP_TOMBSTONE_CATEGORIES = new Set(["kept_conversations", "kept_messages", "summaries", "memories", "bonds", "bond_nicknames", "abstract_signature_seeds", "accessibility_settings", "privacy_settings", "user_preferences", "tombstones"])
const BACKUP_CONVERSATION_KEYS = ["conversation_id", "door_type", "display_door", "abstract_signature_seed", "status", "connection_state", "started_at", "ended_at", "summary_id"]
const BACKUP_MESSAGE_KEYS = ["conversation_id", "client_message_id", "message_id", "type", "content", "expressive", "mine", "delivery_status", "sent_at", "sequence", "content_revision", "peer_applied_content_revision", "edited", "availability", "unsent", "reply_to_client_message_id", "reply_author_relation", "reply_snippet", "reply_target_availability", "self_reaction", "peer_reaction", "view_once_state", "presentation_limit", "views_remaining", "views_consumed", "media_type", "byte_size"]
const BACKUP_RELATIONSHIP_KEYS = ["relationship_id", "status", "conversation_id", "abstract_signature_seed", "origin_door_type", "origin_door_label", "formed_at", "private_nickname", "private_label"]

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

const LEGACY_R0_MAP = Object.freeze({
  heart: "❤️",
  laugh: "😂",
  cry: "😭",
  thumbs_up: "👍️",
  eyes: "👀",
  hug: "🫂"
})

export function normalizeReactionSlot(slot) {
  if (!slot) return null
  const val = slot.emoji || slot.code || slot.reaction || null
  const emoji = (val && LEGACY_R0_MAP[val]) ? LEGACY_R0_MAP[val] : val
  const revision = Number.isInteger(slot.revision) ? slot.revision : 0
  if (!emoji && revision === 0) return null
  return {emoji, revision}
}

export function localMessage({conversation_id, client_message_id, message_id, type = "text", content, expressive, mine, delivery_status, sent_at, sequence, content_revision = 0, peer_applied_content_revision = null, edited = false, availability = "available", unsent = false, reply_to_client_message_id, reply_author_relation, reply_snippet, reply_target_availability, self_reaction, peer_reaction, view_once_state, presentation_limit, views_remaining, views_consumed, media_type, byte_size}) {
  const id_val = client_message_id || message_id
  const norm_status = delivery_status === "sent_to_server" ? "sent" : delivery_status
  const terminalUnsent = availability === "unsent" || unsent === true
  const limitVal = Number.isInteger(presentation_limit) ? presentation_limit : (type === "view_twice_photo" || type === "view_twice_video" ? 2 : 1)
  const remainingVal = Number.isInteger(views_remaining) ? views_remaining : (view_once_state === "viewed" ? 0 : (view_once_state === "viewed_once" ? 1 : limitVal))
  const consumedVal = Number.isInteger(views_consumed) ? views_consumed : (view_once_state === "viewed" ? limitVal : (view_once_state === "viewed_once" ? 1 : 0))
  return {
    id: `message:${conversation_id}:${id_val}`,
    type: "local_message",
    value: {
      conversation_id,
      client_message_id: id_val,
      message_id: id_val,
      type,
      content: terminalUnsent ? null : (content !== undefined ? content : null),
      expressive: expressive || null,
      mine,
      delivery_status: norm_status,
      sent_at,
      sequence,
      content_revision: Number.isInteger(content_revision) && content_revision >= 0 ? content_revision : 0,
      peer_applied_content_revision: Number.isInteger(peer_applied_content_revision) && peer_applied_content_revision >= 0 ? peer_applied_content_revision : null,
      edited: terminalUnsent ? false : (edited === true || (Number.isInteger(content_revision) && content_revision > 0)),
      availability: terminalUnsent ? "unsent" : "available",
      unsent: terminalUnsent,
      reply_to_client_message_id: reply_to_client_message_id || null,
      reply_author_relation: reply_author_relation || null,
      reply_snippet: reply_snippet || null,
      reply_target_availability: reply_target_availability || null,
      self_reaction: terminalUnsent ? null : normalizeReactionSlot(self_reaction),
      peer_reaction: terminalUnsent ? null : normalizeReactionSlot(peer_reaction),
      view_once_state: view_once_state || (type === "view_once_photo" || type === "view_twice_photo" || type === "view_once_video" || type === "view_twice_video" ? "unviewed" : null),
      presentation_limit: limitVal,
      views_remaining: remainingVal,
      views_consumed: consumedVal,
      media_type: media_type || null,
      byte_size: Number.isInteger(byte_size) ? byte_size : null
    },
    updated_at: sent_at
  }
}

export function mergeMessageContent(record, incoming, updatedAt = new Date().toISOString()) {
  if (!record || record.type !== "local_message" || record.value?.type !== "text") return {status: "invalid", record}
  const messageId = record.value.client_message_id || record.value.message_id
  const incomingId = incoming?.client_message_id || incoming?.message_id
  const incomingRevision = incoming?.content_revision
  const incomingUnsent = incoming?.availability === "unsent" || incoming?.unsent === true
  const currentUnsent = record.value.availability === "unsent" || record.value.unsent === true
  if (!messageId || incomingId !== messageId || !Number.isInteger(incomingRevision) || incomingRevision < 0 || (!incomingUnsent && typeof incoming.content !== "string")) {
    return {status: "invalid", record}
  }

  const currentRevision = Number.isInteger(record.value.content_revision) ? record.value.content_revision : 0
  if (currentUnsent && !incomingUnsent) return {status: "ignored_terminal", record}
  if (incomingRevision < currentRevision) return {status: "ignored_older", record}
  if (!incomingUnsent && incomingRevision === currentRevision && incoming.content !== record.value.content) return {status: "equal_revision_conflict", record}

  const previousAppliedRevision = Number.isInteger(record.value.peer_applied_content_revision) ? record.value.peer_applied_content_revision : -1
  const incomingAppliedRevision = Number.isInteger(incoming.peer_applied_content_revision) ? incoming.peer_applied_content_revision : -1
  const appliedRevision = Math.max(previousAppliedRevision, incomingAppliedRevision)
  const currentDelivery = record.value.delivery_status === "sent_to_server" ? "sent" : record.value.delivery_status
  const incomingDelivery = incoming.delivery_status === "sent_to_server" ? "sent" : incoming.delivery_status
  const deliveryStatus = currentDelivery === "delivered" || incomingDelivery !== "delivered" ? currentDelivery : "delivered"
  const next = {
    ...record,
    value: {
      ...record.value,
      content: incomingUnsent ? null : incoming.content,
      content_revision: incomingRevision,
      peer_applied_content_revision: appliedRevision >= 0 ? appliedRevision : null,
      edited: incomingUnsent ? false : incomingRevision > 0,
      delivery_status: deliveryStatus,
      availability: incomingUnsent ? "unsent" : "available",
      unsent: incomingUnsent,
      reply_to_client_message_id: incoming.reply_to_client_message_id || record.value.reply_to_client_message_id || null,
      reply_author_relation: incoming.reply_author_relation || record.value.reply_author_relation || null,
      reply_snippet: incoming.reply_snippet || record.value.reply_snippet || null,
      self_reaction: incomingUnsent ? null : record.value.self_reaction,
      peer_reaction: incomingUnsent ? null : record.value.peer_reaction
    },
    updated_at: updatedAt
  }

  return {
    status: incomingUnsent && !currentUnsent ? "unsent_applied" : (incomingRevision === currentRevision ? "no_op" : "applied"),
    record: next
  }
}

export function sanitizeMessageReference(record, targetClientMessageId, reason, updatedAt = new Date().toISOString()) {
  if (!record || record.type !== "local_message" || record.value?.reply_to_client_message_id !== targetClientMessageId) return record
  const snippet = reason === "unsent" ? "Unsent message" : "Message unavailable"
  return {
    ...record,
    value: {
      ...record.value,
      reply_snippet: snippet,
      reply_target_availability: reason
    },
    updated_at: updatedAt
  }
}

export async function mergeReactionRecord(id, slotKey, incomingSlot) {
  return new Promise((resolve, reject) => {
    const opening = indexedDB.open(DB_NAME, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(STORE, {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => {
      const database = opening.result
      const transaction = database.transaction(STORE, "readwrite")
      const store = transaction.objectStore(STORE)
      const getReq = store.get(id)

      getReq.onerror = () => reject(getReq.error)
      getReq.onsuccess = () => {
        const record = getReq.result
        if (!record || record.type !== "local_message") {
          resolve({record: null, winner: normalizeReactionSlot(incomingSlot)})
          return
        }

        const existingSlot = normalizeReactionSlot(record.value[slotKey]) || {emoji: null, revision: 0}
        const normalizedIncoming = normalizeReactionSlot(incomingSlot) || {emoji: null, revision: 0}

        const existingRev = existingSlot.revision
        const incomingRev = normalizedIncoming.revision

        let winner = existingSlot
        if (incomingRev > existingRev || (incomingRev === existingRev && normalizedIncoming.emoji === existingSlot.emoji)) {
          winner = {emoji: normalizedIncoming.emoji || null, revision: incomingRev}
          record.value[slotKey] = winner
          record.updated_at = new Date().toISOString()
          store.put(record)
        }

        resolve({record, winner})
      }

      transaction.oncomplete = () => database.close()
    }
  })
}

export function localVoiceNote({conversation_id, voice_note_id, blob, mine, delivery_status, sent_at, sequence, duration_ms, byte_size, media_type}) {
  return {id: `voice:${conversation_id}:${voice_note_id}`, type: "local_voice_note", value: {conversation_id, voice_note_id, blob, mine, delivery_status, sent_at, sequence, duration_ms, byte_size, media_type}, updated_at: sent_at}
}

export function conversationSyncCursor({conversation_id, epoch_id, last_applied_sequence, updated_at}) {
  return {
    id: `sync_cursor:${conversation_id}`,
    type: "sync_cursor",
    value: {conversation_id, epoch_id, last_applied_sequence: last_applied_sequence || 0},
    updated_at: updated_at || new Date().toISOString()
  }
}

export function chooseConversationRetention(records, conversationId, choice, {summaryText, now} = {}) {
  const timestamp = now || new Date().toISOString()
  const conversationIdKey = `conversation:${conversationId}`
  const conversation = records.find(({id}) => id === conversationIdKey)
  if (!conversation) throw new Error("conversation_not_found")
  if (conversation.value?.status !== "temporary") throw new Error("retention_already_decided")
  if (!TERMINAL_RETENTION_STATUSES.has(choice)) throw new Error("invalid_retention_choice")
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

export function preserveTerminalRetentionDecisions(current, incoming) {
  const next = new Map(incoming.map((record) => [record.id, record]))

  for (const conversation of current) {
    if (conversation.type !== "local_conversation" || !TERMINAL_RETENTION_STATUSES.has(conversation.value?.status)) continue
    const proposed = next.get(conversation.id)
    if (!proposed || proposed.type !== "local_conversation" || proposed.value?.status === conversation.value.status) continue

    const conversationId = conversation.value.conversation_id
    next.delete(conversation.id)
    next.delete(`summary:${conversationId}`)
    for (const [id, record] of next.entries()) {
      if (new Set(["local_message", "local_voice_note"]).has(record.type) && record.value?.conversation_id === conversationId) next.delete(id)
    }

    next.set(conversation.id, conversation)
    if (conversation.value.status === "kept") {
      for (const record of current) {
        if (new Set(["local_message", "local_voice_note"]).has(record.type) && record.value?.conversation_id === conversationId) next.set(record.id, record)
      }
      const summary = current.find(({id}) => id === `summary:${conversationId}`)
      if (summary) next.set(summary.id, summary)
    } else if (conversation.value.status === "summary_only") {
      const summary = current.find(({id}) => id === `summary:${conversationId}`)
      if (summary) next.set(summary.id, summary)
    }
  }

  for (const conversation of next.values()) {
    if (conversation.type !== "local_conversation") continue
    const conversationId = conversation.value?.conversation_id
    if (conversation.value?.status === "summary_only" || conversation.value?.status === "faded") {
      for (const [id, record] of next.entries()) {
        if (new Set(["local_message", "local_voice_note"]).has(record.type) && record.value?.conversation_id === conversationId) next.delete(id)
      }
    }
    if (conversation.value?.status === "faded") next.delete(`summary:${conversationId}`)
  }

  return [...next.values()]
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

export function mergeRecords(current, imported, {restoreTombstones = false} = {}) {
  const merged = new Map(current.map((record) => [record.id, record]))
  for (const record of imported) {
    const existing = merged.get(record.id)
    if (!existing) {
      merged.set(record.id, record)
      continue
    }
    const existingTombstone = existing.type === "sync_tombstone"
    const importedTombstone = record.type === "sync_tombstone"
    if (!restoreTombstones && existingTombstone !== importedTombstone) {
      merged.set(record.id, existingTombstone ? existing : record)
      continue
    }
    if (Date.parse(record.updated_at) > Date.parse(existing.updated_at)) merged.set(record.id, record)
  }
  return [...merged.values()]
}

export function validEnvelope(envelope) {
  return [PREVIOUS_BACKUP_VERSION, BACKUP_VERSION].includes(envelope?.version) &&
    envelope.kdf === "PBKDF2-SHA256" &&
    envelope.iterations === BACKUP_ITERATIONS &&
    envelope.cipher === "AES-GCM" &&
    [envelope.salt, envelope.iv, envelope.ciphertext].every((value) => typeof value === "string" && value.length > 0)
}

export async function encryptBackup(records, passphrase) {
  if (!passphrase) throw new Error("passphrase_required")
  const serializedRecords = await serializeBackupRecords(records)
  if (!validBackupRecords(serializedRecords)) throw new Error("invalid_backup")
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const key = await deriveKey(passphrase, salt, ["encrypt"])
  const plaintext = new TextEncoder().encode(JSON.stringify({records: serializedRecords}))
  const ciphertext = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, plaintext)
  return {version: BACKUP_VERSION, kdf: "PBKDF2-SHA256", iterations: BACKUP_ITERATIONS, cipher: "AES-GCM", salt: encode(salt), iv: encode(iv), ciphertext: encode(new Uint8Array(ciphertext))}
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
  if (!validBackupRecords(records)) throw new Error("invalid_backup")
  return records
}

export async function getRecord(id) { return request("readonly", (store) => store.get(id)) }
export async function listRecords() { return request("readonly", (store) => store.getAll()) }
export async function putRecord(record) { if (!validRecord(record)) throw new Error("invalid_record"); return request("readwrite", (store) => store.put(record)) }
export async function deleteRecord(id) { return request("readwrite", (store) => store.delete(id)) }
export async function clearRecords() { return request("readwrite", (store) => store.clear()) }
export async function importRecords(imported) {
  if (!validBackupRecords(imported)) throw new Error("invalid_record")
  const merged = mergeRecords(await listRecords(), imported)
  return replaceRecords(merged)
}
export async function replaceRecords(records, indexedDb = indexedDB) {
  if (!Array.isArray(records) || records.some((record) => !validRecord(record))) throw new Error("invalid_record")
  return guardedReplaceRecords(records, indexedDb)
}

export async function atomicReplaceRecords(records, adapter) {
  if (!Array.isArray(records) || records.some((record) => !validRecord(record))) throw new Error("invalid_record")
  return adapter.run([{action: "clear"}, ...records.map((record) => ({action: "put", record}))]).then(() => records)
}

function guardedReplaceRecords(records, indexedDb) {
  return new Promise((resolve, reject) => {
    const opening = indexedDb.open(DB_NAME, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(STORE, {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => {
      const database = opening.result
      const transaction = database.transaction(STORE, "readwrite")
      const store = transaction.objectStore(STORE)
      const currentRequest = store.getAll()
      let committed = null

      currentRequest.onerror = () => transaction.abort()
      currentRequest.onsuccess = () => {
        try {
          committed = preserveTerminalRetentionDecisions(currentRequest.result || [], records)
          store.clear()
          committed.forEach((record) => store.put(record))
        } catch (_error) {
          transaction.abort()
        }
      }
      transaction.oncomplete = () => { database.close(); resolve(committed || records) }
      transaction.onabort = () => { database.close(); reject(transaction.error || new Error("replace_aborted")) }
      transaction.onerror = () => {}
    }
  })
}

function indexedDbAdapter(indexedDb) {
  return {run: (operations) => new Promise((resolve, reject) => {
    const opening = indexedDb.open(DB_NAME, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(STORE, {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => {
      const database = opening.result
      const transaction = database.transaction(STORE, "readwrite")
      const store = transaction.objectStore(STORE)
      transaction.oncomplete = () => { database.close(); resolve() }
      transaction.onabort = () => { database.close(); reject(transaction.error || new Error("restore_aborted")) }
      transaction.onerror = () => {}
      try {
        operations.forEach((operation) => operation.action === "clear" ? store.clear() : store.put(operation.record))
      } catch (error) {
        transaction.abort()
        reject(error)
      }
    }
  })}
}

function validRecord(record) {
  return record &&
    typeof record.id === "string" &&
    record.id.trim().length > 0 &&
    record.id.length <= MAX_RECORD_ID_LENGTH &&
    typeof record.type === "string" &&
    record.type.trim().length > 0 &&
    !Number.isNaN(Date.parse(record.updated_at))
}

function validBackupRecords(records) {
  if (!Array.isArray(records)) return false
  const ids = new Set()
  return records.every((record) => {
    if (!validBackupRecord(record) || ids.has(record.id)) return false
    ids.add(record.id)
    return true
  })
}

function validBackupRecord(record) {
  if (!validRecord(record) || !BACKUP_RECORD_TYPES.has(record.type)) return false
  const value = record.value
  if (record.type === "sync_tombstone") {
    return record.category === "tombstones" &&
      typeof record.deleted_at === "string" &&
      !Number.isNaN(Date.parse(record.deleted_at)) &&
      onlyKeys(value, ["previous_type", "previous_category"]) &&
      nonEmptyString(value.previous_type) &&
      BACKUP_TOMBSTONE_CATEGORIES.has(value.previous_category)
  }
  if (record.type === "local_conversation") {
    return onlyKeys(value, BACKUP_CONVERSATION_KEYS) &&
      nonEmptyString(value.conversation_id) &&
      record.id === `conversation:${value.conversation_id}` &&
      TERMINAL_RETENTION_STATUSES.has(value.status) ||
      (onlyKeys(value, BACKUP_CONVERSATION_KEYS) && nonEmptyString(value.conversation_id) && record.id === `conversation:${value.conversation_id}` && value.status === "temporary")
  }
  if (record.type === "local_message") {
    const messageId = value?.client_message_id || value?.message_id
    return onlyKeys(value, BACKUP_MESSAGE_KEYS) &&
      nonEmptyString(value.conversation_id) &&
      nonEmptyString(messageId) &&
      record.id === `message:${value.conversation_id}:${messageId}` &&
      nonEmptyString(value.type) &&
      !Number.isNaN(Date.parse(value.sent_at))
  }
  if (record.type === "summary") {
    return onlyKeys(value, ["conversation_id", "text"]) &&
      nonEmptyString(value.conversation_id) &&
      record.id === `summary:${value.conversation_id}` &&
      typeof value.text === "string"
  }
  if (record.type === "memory") {
    return onlyKeys(value, ["text", "conversation_id"]) &&
      typeof value.text === "string" &&
      (value.conversation_id === undefined || value.conversation_id === null || typeof value.conversation_id === "string")
  }
  if (record.type === "relationship") {
    return onlyKeys(value, BACKUP_RELATIONSHIP_KEYS) &&
      nonEmptyString(value.relationship_id) &&
      record.id === `relationship:${value.relationship_id}` &&
      nonEmptyString(value.status) &&
      (value.conversation_id === undefined || value.conversation_id === null || typeof value.conversation_id === "string")
  }
  return plainObject(value)
}

function nonEmptyString(value) { return typeof value === "string" && value.trim().length > 0 }
function plainObject(value) { return Boolean(value) && typeof value === "object" && !Array.isArray(value) }
function onlyKeys(value, allowed) { return plainObject(value) && Object.keys(value).every((key) => allowed.includes(key)) }

async function serializeBackupRecords(records) {
  const keptIds = new Set(keptConversations(records).map(({value}) => value.conversation_id))
  const selected = records.filter((record) => BACKUP_RECORD_TYPES.has(record.type) && (record.type !== "local_voice_note" || keptIds.has(record.value.conversation_id)))
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
async function deriveKey(passphrase, salt, usages) { const material = await crypto.subtle.importKey("raw", new TextEncoder().encode(passphrase), "PBKDF2", false, ["deriveKey"]); return crypto.subtle.deriveKey({name: "PBKDF2", hash: "SHA-256", salt, iterations: BACKUP_ITERATIONS}, material, {name: "AES-GCM", length: 256}, false, usages) }
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
