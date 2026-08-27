import {
  cleanupConversationRecoveryRecords,
  cleanupParticipantBoundRecords,
  validLiveRecord
} from "./f11_persistence_runtime.mjs"

const LOCAL_DB_NAME = "strangertalks-local-v1"
const LOCAL_STORE = "records"
const IDENTITY_KEY = "strangertalks.identity.v1"
const TERMINAL_RETENTION_STATUSES = new Set(["kept", "summary_only", "faded"])

function cloneValue(value) {
  try { return typeof structuredClone === "function" ? structuredClone(value) : value } catch (_error) { return value }
}

function recordsMap(records) {
  return new Map((records || []).map((record) => [record.id, cloneValue(record)]))
}

function validRecords(records) {
  return (records || []).filter(validLiveRecord).map(cloneValue)
}

function failedOpenRequest(error) {
  const request = {result: null, error, onsuccess: null, onerror: null, onupgradeneeded: null}
  queueMicrotask(() => request.onerror?.({target: request}))
  return request
}

function normalizeCompletedRetention(records) {
  const next = new Map(records.map((record) => [record.id, record]))
  for (const record of next.values()) {
    if (record?.type !== "local_conversation" || !TERMINAL_RETENTION_STATUSES.has(record.value?.status)) continue
    const conversationId = record.value.conversation_id
    next.delete(`sync_cursor:${conversationId}`)
    next.delete(`terminal_retention:${conversationId}`)
  }
  return [...next.values()]
}

function openNativeDatabase(nativeFactory, name, version) {
  return new Promise((resolve, reject) => {
    let opening
    try { opening = nativeFactory?.open?.(name, version) } catch (error) { reject(error); return }
    if (!opening) { reject(new Error("indexeddb_unavailable")); return }
    opening.onupgradeneeded = () => {
      try { opening.result.createObjectStore(LOCAL_STORE, {keyPath: "id"}) } catch (_error) {}
    }
    opening.onerror = () => reject(opening.error || new Error("indexeddb_open_failed"))
    opening.onsuccess = () => resolve(opening.result)
  })
}

function readNativeRecords(database) {
  return new Promise((resolve, reject) => {
    let transaction
    try { transaction = database.transaction(LOCAL_STORE, "readonly") } catch (error) { reject(error); return }
    let result = []
    let settled = false
    const fail = (error) => {
      if (settled) return
      settled = true
      reject(error || transaction.error || new Error("indexeddb_read_failed"))
    }
    transaction.onerror = () => fail(transaction.error)
    transaction.onabort = () => fail(transaction.error || new Error("indexeddb_read_aborted"))
    transaction.oncomplete = () => {
      if (settled) return
      settled = true
      resolve(result)
    }
    let request
    try { request = transaction.objectStore(LOCAL_STORE).getAll() } catch (error) { fail(error); return }
    request.onerror = () => fail(request.error)
    request.onsuccess = () => { result = request.result || [] }
  })
}

function persistNativeSnapshot(state, records) {
  if (state.mode === "ephemeral" || !state.nativeDb) return Promise.resolve(false)
  return new Promise((resolve) => {
    let transaction
    try { transaction = state.nativeDb.transaction(LOCAL_STORE, "readwrite") } catch (error) {
      degrade(state, error)
      resolve(false)
      return
    }
    let settled = false
    const fail = (error) => {
      if (settled) return
      settled = true
      degrade(state, error || transaction.error || new Error("indexeddb_write_failed"))
      resolve(false)
    }
    transaction.onerror = () => fail(transaction.error)
    transaction.onabort = () => fail(transaction.error || new Error("indexeddb_write_aborted"))
    transaction.oncomplete = () => {
      if (settled) return
      settled = true
      state.mode = "durable"
      state.reason = null
      resolve(true)
    }
    try {
      const store = transaction.objectStore(LOCAL_STORE)
      const clear = store.clear()
      clear.onerror = () => fail(clear.error)
      for (const record of records) {
        const request = store.put(record)
        request.onerror = () => fail(request.error)
      }
    } catch (error) {
      fail(error)
    }
  })
}

function degrade(state, error) {
  state.mode = "ephemeral"
  state.reason = error?.message || "indexeddb_unavailable"
  try { state.nativeDb?.close?.() } catch (_error) {}
  state.nativeDb = null
}

async function hydrateState(state, nativeFactory, name, version) {
  try {
    state.nativeDb = await openNativeDatabase(nativeFactory, name, version)
    const raw = await readNativeRecords(state.nativeDb)
    const accepted = validRecords(raw)
    state.records = recordsMap(accepted)
    state.mode = "durable"
    state.reason = null
    if (accepted.length !== raw.length) await persistNativeSnapshot(state, accepted)
  } catch (error) {
    state.records = state.records || new Map()
    degrade(state, error)
  }
  state.hydrated = true
  return state
}

async function commitState(state, records) {
  const normalized = validRecords(normalizeCompletedRetention(records))
  state.records = recordsMap(normalized)
  const durable = await persistNativeSnapshot(state, normalized)
  return {records: normalized, durable}
}

function makeCanonicalDatabase(state) {
  return {
    name: LOCAL_DB_NAME,
    version: 1,
    close() {},
    createObjectStore() { return {} },
    transaction(storeName, mode = "readonly") {
      if ((Array.isArray(storeName) ? storeName[0] : storeName) !== LOCAL_STORE) throw new Error("NotFoundError")
      return makeCanonicalTransaction(state, mode)
    }
  }
}

function makeCanonicalTransaction(state, mode) {
  let draft = mode === "readwrite" ? recordsMap([...state.records.values()]) : state.records
  let pending = 0
  let commitScheduled = false
  let commitStarted = false
  let aborted = false
  const deferredMutationSuccesses = []

  const transaction = {
    mode,
    error: null,
    oncomplete: null,
    onerror: null,
    onabort: null,
    __f11Durability: state.mode,
    abort() {
      if (aborted || commitStarted) return
      aborted = true
      transaction.error = transaction.error || new Error("AbortError")
      transaction.onabort?.({target: transaction})
    },
    objectStore() {
      return {
        get: (key) => operation("get", key),
        getAll: () => operation("getAll"),
        put: (value) => operation("put", value?.id, value),
        delete: (key) => operation("delete", key),
        clear: () => operation("clear")
      }
    }
  }

  function operation(kind, key, value) {
    const request = {result: undefined, error: null, onsuccess: null, onerror: null}
    pending += 1
    queueMicrotask(() => {
      if (aborted) { pending -= 1; scheduleCommit(); return }
      try {
        if (kind === "get") request.result = draft.has(key) ? cloneValue(draft.get(key)) : null
        if (kind === "getAll") request.result = [...draft.values()].map(cloneValue)
        if (kind === "put") {
          if (mode !== "readwrite") throw new Error("ReadOnlyError")
          if (!validLiveRecord(value)) throw new Error("invalid_record")
          draft.set(value.id, cloneValue(value))
          request.result = value.id
        }
        if (kind === "delete") {
          if (mode !== "readwrite") throw new Error("ReadOnlyError")
          draft.delete(key)
          if (key === IDENTITY_KEY) draft = recordsMap(cleanupParticipantBoundRecords([...draft.values()]))
        }
        if (kind === "clear") {
          if (mode !== "readwrite") throw new Error("ReadOnlyError")
          draft.clear()
        }

        pending -= 1
        if (["put", "delete", "clear"].includes(kind)) deferredMutationSuccesses.push(request)
        else request.onsuccess?.({target: request})
        scheduleCommit()
      } catch (error) {
        pending -= 1
        request.error = error
        transaction.error = error
        request.onerror?.({target: request})
        transaction.onerror?.({target: transaction})
        aborted = true
        transaction.onabort?.({target: transaction})
      }
    })
    return request
  }

  function scheduleCommit() {
    if (commitScheduled || commitStarted || aborted) return
    commitScheduled = true
    queueMicrotask(async () => {
      commitScheduled = false
      if (pending !== 0 || commitStarted || aborted) return
      commitStarted = true

      if (mode === "readonly") {
        transaction.__f11Durability = state.mode
        transaction.oncomplete?.({target: transaction})
        return
      }

      const result = await commitState(state, [...draft.values()])
      transaction.__f11Durability = result.durable ? "durable" : "ephemeral"

      // local_data.mjs resolves write promises from operation.onsuccess.
      // Fire transaction completion first so those promises cannot report
      // durability before the native transaction has completed.
      transaction.oncomplete?.({target: transaction})
      for (const request of deferredMutationSuccesses) request.onsuccess?.({target: request})
    })
  }

  return transaction
}

export function createCanonicalIndexedDB(nativeFactory) {
  const states = new Map()

  function localState(name, version) {
    let state = states.get(name)
    if (!state) {
      state = {name, version, hydrated: false, hydration: null, records: new Map(), nativeDb: null, mode: "pending", reason: null}
      state.hydration = hydrateState(state, nativeFactory, name, version)
      states.set(name, state)
    }
    return state
  }

  const factory = {
    __f11Canonical: true,
    open(name, version = 1) {
      if (name !== LOCAL_DB_NAME) {
        if (!nativeFactory?.open) return failedOpenRequest(new Error("indexeddb_unavailable"))
        try { return nativeFactory.open(name, version) } catch (error) { return failedOpenRequest(error) }
      }

      const request = {result: null, error: null, onsuccess: null, onerror: null, onupgradeneeded: null}
      const state = localState(name, version)
      state.hydration.then(() => {
        request.result = makeCanonicalDatabase(state)
        request.onsuccess?.({target: request})
      }).catch((error) => {
        request.error = error
        request.onerror?.({target: request})
      })
      return request
    },
    storageStatus() {
      const state = states.get(LOCAL_DB_NAME)
      const mode = state?.mode || "pending"
      return Object.freeze({mode, durable: mode === "durable", reason: state?.reason || null})
    },
    async cleanupConversationRecovery(conversationId) {
      const state = localState(LOCAL_DB_NAME, 1)
      await state.hydration
      const next = cleanupConversationRecoveryRecords([...state.records.values()], conversationId)
      return commitState(state, next)
    },
    async cleanupParticipantRecovery() {
      const state = localState(LOCAL_DB_NAME, 1)
      await state.hydration
      return commitState(state, cleanupParticipantBoundRecords([...state.records.values()]))
    },
    async refresh() {
      const state = localState(LOCAL_DB_NAME, 1)
      if (state.mode === "ephemeral" || !state.nativeDb) return [...state.records.values()].map(cloneValue)
      try {
        const raw = await readNativeRecords(state.nativeDb)
        const accepted = validRecords(raw)
        state.records = recordsMap(accepted)
        return accepted
      } catch (error) {
        degrade(state, error)
        return [...state.records.values()].map(cloneValue)
      }
    }
  }

  return factory
}
