const LOCAL_DB_NAME = "strangertalks-local-v1"
const LOCAL_STORE = "records"
const LIVE_SCHEMA_VERSION = 1
const LANGUAGE_KEY = "strangertalks.conversation-language.v1"
const IDENTITY_KEY = "strangertalks.identity.v1"
const VALID_LANGUAGES = new Set(["en", "te", "hi"])
const TERMINAL_RETENTION_STATUSES = new Set(["kept", "summary_only", "faded"])
const CONNECTION_STATES = new Set(["connected", "reconnecting", "recovery", "ended"])
const RECONNECT_STATES = new Set(["idle", "waiting_for_mutual_availability", "matched", "unavailable"])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

const runtime = {
  installed: false,
  futureLanguage: null,
  languageWriteAuthorized: false,
  readiness: createCanonicalReadiness(),
  memoryIndexedDB: createMemoryIndexedDB(),
  nativeIndexedDB: null,
  resilientIndexedDB: null,
  participantChannel: null,
  lastVisibilityReconcileAt: 0
}

export function safeStorageGet(storage, key, fallback = null) {
  try {
    const value = storage?.getItem?.(key)
    return value === null || value === undefined ? fallback : value
  } catch (_error) {
    return fallback
  }
}

export function safeStorageSet(storage, key, value) {
  try {
    storage?.setItem?.(key, value)
    return true
  } catch (_error) {
    return false
  }
}

export function safeStorageRemove(storage, key) {
  try {
    storage?.removeItem?.(key)
    return true
  } catch (_error) {
    return false
  }
}

export function createFutureLanguageState(initialFuture = null) {
  let future = VALID_LANGUAGES.has(initialFuture) ? initialFuture : null
  let current = null
  return {
    future: () => future,
    current: () => current,
    setFuture(value) { future = VALID_LANGUAGES.has(value) ? value : null; return future },
    setCurrentCanonical(value) { current = VALID_LANGUAGES.has(value) ? value : null; return current },
    clearCurrent() { current = null },
    languageForNewAttempt(fallback = null) { return future || (VALID_LANGUAGES.has(fallback) ? fallback : null) }
  }
}

export function futureConversationLanguageForQueue(fallback = null) {
  return VALID_LANGUAGES.has(runtime.futureLanguage)
    ? runtime.futureLanguage
    : (VALID_LANGUAGES.has(fallback) ? fallback : null)
}

export function createCanonicalReadiness() {
  let state = Object.freeze({status: "CANONICAL_STATE_PENDING", canonical_state: null, snapshot: null, terminal_retention: null})
  const listeners = new Set()
  const publish = () => listeners.forEach((listener) => listener(state))
  return {
    get: () => state,
    pending() {
      state = Object.freeze({...state, status: "CANONICAL_STATE_PENDING", canonical_state: null, snapshot: null})
      publish()
      return state
    },
    accept(snapshot, terminalRetention = null) {
      const canonical = snapshot?.canonical_state
      if (!["AVAILABLE", "QUEUED", "CONVERSATION"].includes(canonical)) return state
      state = Object.freeze({status: "READY", canonical_state: canonical, snapshot, terminal_retention: terminalRetention || null})
      publish()
      return state
    },
    subscribe(listener) {
      if (typeof listener !== "function") return () => {}
      listeners.add(listener)
      listener(state)
      return () => listeners.delete(listener)
    }
  }
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0
}

function plainObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false
  const proto = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

function validEnvelope(record) {
  return plainObject(record) && nonEmptyString(record.id) && record.id.length <= 256 && nonEmptyString(record.type) &&
    nonEmptyString(record.updated_at) && Number.isFinite(Date.parse(record.updated_at)) &&
    (record.schema_version === undefined || record.schema_version === LIVE_SCHEMA_VERSION)
}

function validConversationRecord(record) {
  const value = record.value
  if (!plainObject(value) || !UUID_RE.test(value.conversation_id || "") || record.id !== `conversation:${value.conversation_id}`) return false
  if (!(value.status === "temporary" || value.status === "ended" || TERMINAL_RETENTION_STATUSES.has(value.status))) return false
  if (!CONNECTION_STATES.has(value.connection_state)) return false
  if (!nonEmptyString(value.started_at) || !Number.isFinite(Date.parse(value.started_at))) return false
  return value.ended_at === null || value.ended_at === undefined || (nonEmptyString(value.ended_at) && Number.isFinite(Date.parse(value.ended_at)))
}

function validMessageRecord(record) {
  const value = record.value
  const messageId = value?.client_message_id || value?.message_id
  return plainObject(value) && UUID_RE.test(value.conversation_id || "") && nonEmptyString(messageId) &&
    record.id === `message:${value.conversation_id}:${messageId}` && nonEmptyString(value.type) &&
    nonEmptyString(value.sent_at) && Number.isFinite(Date.parse(value.sent_at))
}

function validVoiceRecord(record) {
  const value = record.value
  return plainObject(value) && UUID_RE.test(value.conversation_id || "") && nonEmptyString(value.voice_note_id) &&
    record.id === `voice:${value.conversation_id}:${value.voice_note_id}` && nonEmptyString(value.sent_at) &&
    Number.isFinite(Date.parse(value.sent_at))
}

function validCursorRecord(record) {
  const value = record.value
  return plainObject(value) && UUID_RE.test(value.conversation_id || "") && record.id === `sync_cursor:${value.conversation_id}` &&
    nonEmptyString(value.epoch_id) && Number.isInteger(value.last_applied_sequence) && value.last_applied_sequence >= 0
}

function validSettingsRecord(record) {
  const value = record.value
  if (!plainObject(value)) return false
  if (record.id === "settings:privacy") return typeof value.reduced_motion === "boolean"
  if (record.id === "settings:auto-sync") return typeof value.enabled === "boolean"
  if (record.id === "settings:voice-warning:v1") return value.voice_warning_version === 1
  return true
}

function validReconnectRecord(record) {
  const value = record.value
  if (!plainObject(value) || !UUID_RE.test(value.relationship_id || "") || record.id !== `bond-reconnect:${value.relationship_id}` || !RECONNECT_STATES.has(value.status)) return false
  if (value.status === "waiting_for_mutual_availability") return nonEmptyString(value.door_type) && nonEmptyString(value.expires_at) && Number.isFinite(Date.parse(value.expires_at))
  if (value.status === "matched") return UUID_RE.test(value.conversation_id || "")
  return true
}

function validTerminalRetentionRecord(record) {
  const value = record.value
  return plainObject(value) && UUID_RE.test(value.conversation_id || "") && record.id === `terminal_retention:${value.conversation_id}` &&
    value.status === "pending" && nonEmptyString(value.ended_at) && Number.isFinite(Date.parse(value.ended_at))
}

export function validLiveRecord(record) {
  if (!validEnvelope(record)) return false
  if (record.type === "identity") {
    return record.id === IDENTITY_KEY && plainObject(record.value) && UUID_RE.test(record.value.participant_id || "") && nonEmptyString(record.value.token)
  }
  if (record.type === "local_conversation") return validConversationRecord(record)
  if (record.type === "local_message") return validMessageRecord(record)
  if (record.type === "local_voice_note") return validVoiceRecord(record)
  if (record.type === "sync_cursor") return validCursorRecord(record)
  if (record.type === "settings") return validSettingsRecord(record)
  if (record.type === "bond_reconnect_state") return validReconnectRecord(record)
  if (record.type === "terminal_retention_state") return validTerminalRetentionRecord(record)
  if (["summary", "memory", "relationship", "sync_tombstone"].includes(record.type)) return plainObject(record.value)
  return plainObject(record.value)
}

function conversationIdForRecoveryRecord(record) {
  if (record?.type === "local_conversation") return record.value?.conversation_id || null
  if (["local_message", "local_voice_note", "sync_cursor", "terminal_retention_state"].includes(record?.type)) return record.value?.conversation_id || null
  return null
}

export function cleanupConversationRecoveryRecords(records, conversationId) {
  const conversation = records.find((record) =>
    record?.type === "local_conversation" && record.value?.conversation_id === conversationId
  )
  const retainedStatus = conversation?.value?.status

  return records.filter((record) => {
    const sameConversation = conversationIdForRecoveryRecord(record) === conversationId
    if (!sameConversation) return true

    if (["sync_cursor", "terminal_retention_state"].includes(record.type)) return false

    if (TERMINAL_RETENTION_STATUSES.has(retainedStatus)) {
      if (record.type === "local_conversation") return true
      if (retainedStatus === "kept" && ["local_message", "local_voice_note"].includes(record.type)) return true
      if (["local_message", "local_voice_note"].includes(record.type)) return false
      return true
    }

    return !["local_conversation", "local_message", "local_voice_note"].includes(record.type)
  })
}

export function cleanupParticipantBoundRecords(records) {
  const retainedConversations = new Set(records.filter((record) =>
    record?.type === "local_conversation" && TERMINAL_RETENTION_STATUSES.has(record.value?.status)
  ).map((record) => record.value.conversation_id))

  return records.filter((record) => {
    if (record?.type === "bond_reconnect_state" || record?.type === "sync_cursor" || record?.type === "terminal_retention_state") return false
    const conversationId = conversationIdForRecoveryRecord(record)
    if (!conversationId) return true
    if (record.type === "local_conversation") return retainedConversations.has(conversationId)
    if (["local_message", "local_voice_note"].includes(record.type)) return retainedConversations.has(conversationId)
    return true
  })
}

export function findPendingTerminalRetention(records) {
  const marker = records.find((record) => record?.type === "terminal_retention_state" && validTerminalRetentionRecord(record))
  if (!marker) return null
  const conversation = records.find((record) => record?.id === `conversation:${marker.value.conversation_id}`)
  if (!conversation || conversation.type !== "local_conversation" || conversation.value?.status !== "temporary" || conversation.value?.connection_state !== "ended") return null
  return {...marker.value}
}

function cloneValue(value) {
  try { return typeof structuredClone === "function" ? structuredClone(value) : value } catch (_error) { return value }
}

function asyncRequest(executor) {
  const request = {result: undefined, error: null, onsuccess: null, onerror: null}
  queueMicrotask(() => {
    try {
      request.result = executor()
      request.onsuccess?.({target: request})
    } catch (error) {
      request.error = error
      request.onerror?.({target: request})
    }
  })
  return request
}

export function createMemoryIndexedDB() {
  const databases = new Map()

  function open(name, version = 1) {
    const request = {result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null}
    queueMicrotask(() => {
      try {
        let state = databases.get(name)
        const isNew = !state
        if (!state) {
          state = {version, stores: new Map()}
          databases.set(name, state)
        }
        const database = {
          name,
          version: state.version,
          close() {},
          createObjectStore(storeName, options = {}) {
            if (!state.stores.has(storeName)) state.stores.set(storeName, {keyPath: options.keyPath || null, records: new Map()})
            return {}
          },
          transaction(storeName, mode = "readonly") {
            const names = Array.isArray(storeName) ? storeName : [storeName]
            const storeState = state.stores.get(names[0])
            if (!storeState) throw new Error("NotFoundError")
            const transaction = {
              mode,
              oncomplete: null,
              onerror: null,
              onabort: null,
              error: null,
              __durablyCompletedBeforeRequestSuccess: false,
              abort() { transaction.error = new Error("AbortError"); transaction.onabort?.({target: transaction}) },
              objectStore() {
                const operation = (kind, key, value) => {
                  const req = {result: undefined, error: null, onsuccess: null, onerror: null}
                  queueMicrotask(() => {
                    try {
                      if (kind === "get") req.result = cloneValue(storeState.records.get(key))
                      if (kind === "getAll") req.result = [...storeState.records.values()].map(cloneValue)
                      if (kind === "put") {
                        const recordKey = storeState.keyPath ? value?.[storeState.keyPath] : key
                        if (recordKey === undefined || recordKey === null) throw new Error("DataError")
                        storeState.records.set(recordKey, cloneValue(value))
                        req.result = recordKey
                      }
                      if (kind === "delete") storeState.records.delete(key)
                      if (kind === "clear") storeState.records.clear()
                      if (mode === "readwrite") transaction.__durablyCompletedBeforeRequestSuccess = true
                      req.onsuccess?.({target: req})
                      queueMicrotask(() => transaction.oncomplete?.({target: transaction}))
                    } catch (error) {
                      req.error = error
                      transaction.error = error
                      req.onerror?.({target: req})
                      transaction.onerror?.({target: transaction})
                    }
                  })
                  return req
                }
                return {
                  get: (key) => operation("get", key),
                  getAll: () => operation("getAll"),
                  put: (value, key) => operation("put", key, value),
                  delete: (key) => operation("delete", key),
                  clear: () => operation("clear")
                }
              }
            }
            return transaction
          }
        }
        request.result = database
        if (isNew) request.onupgradeneeded?.({target: request})
        request.onsuccess?.({target: request})
      } catch (error) {
        request.error = error
        request.onerror?.({target: request})
      }
    })
    return request
  }

  return {open}
}

function bridgeOpenRequest(primaryRequest, fallbackFactory, name, version) {
  const bridge = {result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null}
  let settled = false
  const useFallback = () => {
    if (settled) return
    const fallback = fallbackFactory.open(name, version)
    fallback.onupgradeneeded = () => {
      bridge.result = fallback.result
      bridge.onupgradeneeded?.({target: bridge})
    }
    fallback.onsuccess = () => {
      settled = true
      bridge.result = fallback.result
      bridge.onsuccess?.({target: bridge})
    }
    fallback.onerror = () => {
      settled = true
      bridge.error = fallback.error
      bridge.onerror?.({target: bridge})
    }
  }
  primaryRequest.onupgradeneeded = () => {
    bridge.result = primaryRequest.result
    bridge.onupgradeneeded?.({target: bridge})
  }
  primaryRequest.onsuccess = () => {
    if (settled) return
    settled = true
    bridge.result = primaryRequest.result
    bridge.onsuccess?.({target: bridge})
  }
  primaryRequest.onerror = useFallback
  return bridge
}

export function createResilientIndexedDB(nativeFactory, memoryFactory = createMemoryIndexedDB()) {
  return {
    open(name, version) {
      if (name !== LOCAL_DB_NAME) return nativeFactory.open(name, version)
      try {
        return bridgeOpenRequest(nativeFactory.open(name, version), memoryFactory, name, version)
      } catch (_error) {
        return memoryFactory.open(name, version)
      }
    }
  }
}

function dispatchReadiness(state) {
  if (typeof document !== "undefined") document.documentElement.dataset.canonicalActivityReady = state.status === "READY" ? "true" : "false"
  if (typeof globalThis.dispatchEvent === "function" && typeof CustomEvent === "function") {
    globalThis.dispatchEvent(new CustomEvent("strangertalks:canonical-readiness", {detail: state}))
  }
}

async function listLocalRecords() {
  return new Promise((resolve) => {
    try {
      const opening = globalThis.indexedDB?.open?.(LOCAL_DB_NAME, 1)
      if (!opening) return resolve([])
      opening.onupgradeneeded = () => opening.result.createObjectStore(LOCAL_STORE, {keyPath: "id"})
      opening.onerror = () => resolve([])
      opening.onsuccess = () => {
        let transaction
        try { transaction = opening.result.transaction(LOCAL_STORE, "readonly") } catch (_error) { opening.result.close?.(); return resolve([]) }
        const request = transaction.objectStore(LOCAL_STORE).getAll()
        request.onerror = () => resolve([])
        request.onsuccess = () => resolve((request.result || []).filter(validLiveRecord))
        transaction.oncomplete = () => opening.result.close?.()
      }
    } catch (_error) { resolve([]) }
  })
}

async function replaceLocalRecords(records) {
  return new Promise((resolve) => {
    try {
      const opening = globalThis.indexedDB?.open?.(LOCAL_DB_NAME, 1)
      if (!opening) return resolve(false)
      opening.onupgradeneeded = () => opening.result.createObjectStore(LOCAL_STORE, {keyPath: "id"})
      opening.onerror = () => resolve(false)
      opening.onsuccess = () => {
        let transaction
        try { transaction = opening.result.transaction(LOCAL_STORE, "readwrite") } catch (_error) { opening.result.close?.(); return resolve(false) }
        const store = transaction.objectStore(LOCAL_STORE)
        store.clear()
        records.forEach((record) => store.put(record))
        transaction.oncomplete = () => { opening.result.close?.(); resolve(true) }
        transaction.onerror = () => resolve(false)
        transaction.onabort = () => resolve(false)
      }
    } catch (_error) { resolve(false) }
  })
}

async function persistTerminalRetentionPending(conversationId) {
  const records = await listLocalRecords()
  const conversation = records.find((record) => record.id === `conversation:${conversationId}`)
  if (!conversation || conversation.value?.status !== "temporary") return
  const timestamp = new Date().toISOString()
  const updatedConversation = {...conversation, value: {...conversation.value, connection_state: "ended", ended_at: conversation.value.ended_at || timestamp}, updated_at: timestamp}
  const marker = {id: `terminal_retention:${conversationId}`, type: "terminal_retention_state", schema_version: LIVE_SCHEMA_VERSION, value: {conversation_id: conversationId, status: "pending", ended_at: timestamp}, updated_at: timestamp}
  const next = records.filter((record) => ![updatedConversation.id, marker.id].includes(record.id))
  next.push(updatedConversation, marker)
  await replaceLocalRecords(next)
}

async function cleanupCanonicalObsoleteRecovery(snapshot) {
  const records = await listLocalRecords()
  if (!records.length) return null
  const pendingTerminal = findPendingTerminalRetention(records)
  const canonicalConversationId = snapshot?.canonical_state === "CONVERSATION" ? snapshot.conversation?.conversation_id : null
  let next = records
  for (const conversation of records.filter((record) => record.type === "local_conversation" && record.value?.status === "temporary")) {
    const id = conversation.value.conversation_id
    if (pendingTerminal?.conversation_id === id) continue
    if (canonicalConversationId === id) continue
    next = cleanupConversationRecoveryRecords(next, id)
  }
  if (next.length !== records.length) await replaceLocalRecords(next)
  return pendingTerminal
}

async function onCanonicalSnapshot(snapshot) {
  const pendingTerminal = await cleanupCanonicalObsoleteRecovery(snapshot)
  const next = runtime.readiness.accept(snapshot, pendingTerminal)
  dispatchReadiness(next)
  return next
}

function setReadinessPending() {
  const next = runtime.readiness.pending()
  dispatchReadiness(next)
  return next
}

function patchParticipantChannel(channel) {
  if (!channel || channel.__f11ParticipantPatched) return channel
  channel.__f11ParticipantPatched = true
  runtime.participantChannel = channel
  const originalJoin = channel.join.bind(channel)
  const originalPush = channel.push.bind(channel)
  channel.join = function(timeout) {
    setReadinessPending()
    const result = originalJoin(timeout)
    result.receive("ok", (response) => { onCanonicalSnapshot(response?.snapshot).catch(() => {}) })
    return result
  }
  channel.push = function(event, payload, timeout) {
    const result = originalPush(event, payload, timeout)
    if (event === "session:reconcile") {
      setReadinessPending()
      result.receive("ok", (response) => { onCanonicalSnapshot(response?.snapshot).catch(() => {}) })
    }
    return result
  }
  return channel
}

function patchConversationChannel(channel, conversationId) {
  if (!channel || channel.__f11ConversationPatched) return channel
  channel.__f11ConversationPatched = true
  channel.on("conversation:ended", () => { persistTerminalRetentionPending(conversationId).catch(() => {}) })
  const originalJoin = channel.join.bind(channel)
  channel.join = function(timeout) {
    const result = originalJoin(timeout)
    result.receive("error", () => {
      listLocalRecords().then((records) => replaceLocalRecords(cleanupConversationRecoveryRecords(records, conversationId))).catch(() => {})
    })
    return result
  }
  return channel
}

function patchSocketChannels(SocketClass) {
  if (!SocketClass?.prototype || SocketClass.prototype.__f11ChannelPatched) return
  SocketClass.prototype.__f11ChannelPatched = true
  const originalChannel = SocketClass.prototype.channel
  SocketClass.prototype.channel = function(topic, params) {
    const channel = originalChannel.call(this, topic, params)
    if (typeof topic === "string" && topic.startsWith("participant:")) return patchParticipantChannel(channel)
    if (typeof topic === "string" && topic.startsWith("conversation:")) return patchConversationChannel(channel, topic.slice("conversation:".length))
    return channel
  }
}

function installSafeLocalStorage() {
  if (typeof globalThis.localStorage === "undefined") return
  const storage = globalThis.localStorage
  runtime.futureLanguage = safeStorageGet(storage, LANGUAGE_KEY, null)
  if (!VALID_LANGUAGES.has(runtime.futureLanguage)) runtime.futureLanguage = null

  const proto = Object.getPrototypeOf(storage)
  if (!proto || proto.__f11SafeStoragePatched) return
  const originalGet = proto.getItem
  const originalSet = proto.setItem
  const originalRemove = proto.removeItem
  Object.defineProperty(proto, "__f11SafeStoragePatched", {value: true, configurable: true})
  proto.getItem = function(key) {
    if (key === LANGUAGE_KEY && VALID_LANGUAGES.has(runtime.futureLanguage)) return runtime.futureLanguage
    try { return originalGet.call(this, key) } catch (_error) { return key === LANGUAGE_KEY ? runtime.futureLanguage : null }
  }
  proto.setItem = function(key, value) {
    if (key === LANGUAGE_KEY) {
      if (!runtime.languageWriteAuthorized) return
      runtime.futureLanguage = VALID_LANGUAGES.has(String(value)) ? String(value) : null
    }
    try { return originalSet.call(this, key, value) } catch (_error) { return undefined }
  }
  proto.removeItem = function(key) {
    if (key === LANGUAGE_KEY) {
      if (!runtime.languageWriteAuthorized) return
      runtime.futureLanguage = null
    }
    try { return originalRemove.call(this, key) } catch (_error) { return undefined }
  }

  if (typeof document !== "undefined") {
    document.addEventListener("change", (event) => {
      if (event.target?.id !== "conversation-language") return
      runtime.languageWriteAuthorized = true
      queueMicrotask(() => { runtime.languageWriteAuthorized = false })
    }, true)
  }
}

function installResilientIndexedDB() {
  if (!globalThis.indexedDB || globalThis.indexedDB.__f11Resilient) return
  runtime.nativeIndexedDB = globalThis.indexedDB
  runtime.resilientIndexedDB = createResilientIndexedDB(runtime.nativeIndexedDB, runtime.memoryIndexedDB)
  Object.defineProperty(runtime.resilientIndexedDB, "__f11Resilient", {value: true})
  try { Object.defineProperty(globalThis, "indexedDB", {value: runtime.resilientIndexedDB, configurable: true}) } catch (_error) {}
}

function installVisibilityReconciliation() {
  if (typeof document === "undefined" || document.__f11VisibilityReconcileInstalled) return
  Object.defineProperty(document, "__f11VisibilityReconcileInstalled", {value: true})
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible" || !runtime.participantChannel) return
    const currentTime = Date.now()
    if (currentTime - runtime.lastVisibilityReconcileAt < 5_000) return
    runtime.lastVisibilityReconcileAt = currentTime
    try { runtime.participantChannel.push("session:reconcile", {}) } catch (_error) {}
  })
}

function exposeReadinessContract() {
  const api = {
    getReadiness: () => runtime.readiness.get(),
    subscribeReadiness: (listener) => runtime.readiness.subscribe(listener),
    getFutureConversationLanguage: () => runtime.futureLanguage,
    reconcileCanonicalActivity() {
      if (!runtime.participantChannel) return false
      try { runtime.participantChannel.push("session:reconcile", {}); return true } catch (_error) { return false }
    }
  }
  try { Object.defineProperty(globalThis, "StrangerTalksF11", {value: api, configurable: true}) } catch (_error) { globalThis.StrangerTalksF11 = api }
  dispatchReadiness(runtime.readiness.get())
}

export function installF11Runtime({SocketClass} = {}) {
  if (runtime.installed) return globalThis.StrangerTalksF11 || null
  runtime.installed = true
  installSafeLocalStorage()
  installResilientIndexedDB()
  patchSocketChannels(SocketClass)
  installVisibilityReconciliation()
  exposeReadinessContract()
  return globalThis.StrangerTalksF11
}
