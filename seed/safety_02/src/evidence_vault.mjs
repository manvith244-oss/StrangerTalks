import {decode, encode, rfc8949EncodeOptions} from "cborg"

const DATABASE_VERSION = 1
const META_STORE = "meta"
const RECORD_STORE = "records"
const KEY_ID = "vault-key"

function vaultError(code, cause = undefined) {
  const error = new Error(code, cause ? {cause} : undefined)
  error.code = code
  return error
}

function requestResult(request, code = "indexeddb_error") {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(vaultError(code, request.error))
  })
}

function transactionDone(transaction, code = "indexeddb_transaction_error") {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onabort = () => reject(vaultError(code, transaction.error))
    transaction.onerror = () => reject(vaultError(code, transaction.error))
  })
}

function openDatabase(indexedDB, dbName) {
  return new Promise((resolve, reject) => {
    let request
    try {
      request = indexedDB.open(dbName, DATABASE_VERSION)
    } catch (error) {
      reject(vaultError("indexeddb_unavailable", error))
      return
    }
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(META_STORE)) db.createObjectStore(META_STORE, {keyPath: "id"})
      if (!db.objectStoreNames.contains(RECORD_STORE)) db.createObjectStore(RECORD_STORE, {keyPath: "id"})
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(vaultError("indexeddb_open_failed", request.error))
  })
}

function deleteDatabase(indexedDB, dbName) {
  return new Promise((resolve, reject) => {
    let request
    try {
      request = indexedDB.deleteDatabase(dbName)
    } catch (error) {
      reject(vaultError("indexeddb_delete_failed", error))
      return
    }
    request.onsuccess = () => resolve()
    request.onerror = () => reject(vaultError("indexeddb_delete_failed", request.error))
    request.onblocked = () => reject(vaultError("indexeddb_delete_blocked"))
  })
}

function validAesKey(value) {
  return Boolean(value && typeof value === "object" && value.type === "secret" && value.algorithm?.name === "AES-GCM" &&
    Array.isArray(value.usages) && value.usages.includes("encrypt") && value.usages.includes("decrypt") && value.extractable === false)
}

async function loadOrCreateKey(db) {
  let tx = db.transaction(META_STORE, "readonly")
  let record = await requestResult(tx.objectStore(META_STORE).get(KEY_ID))
  await transactionDone(tx)
  if (record?.key && validAesKey(record.key)) return record.key
  if (record) throw vaultError("invalid_vault_key")

  const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, false, ["encrypt", "decrypt"])
  tx = db.transaction(META_STORE, "readwrite")
  tx.objectStore(META_STORE).put({id: KEY_ID, algorithm: "AES-GCM-256", key})
  await transactionDone(tx)
  return key
}

function strictDecode(bytes) {
  try {
    return decode(bytes, {strict: true, allowIndefinite: false, allowNaN: false, allowInfinity: false, useMaps: false})
  } catch (error) {
    throw vaultError("evidence_decode_failed", error)
  }
}

export class EvidenceVault {
  static async open({indexedDB, dbName, privateMode = false}) {
    if (!indexedDB?.open || !indexedDB?.deleteDatabase || typeof dbName !== "string" || dbName.length === 0) {
      throw vaultError("invalid_vault_configuration")
    }
    const db = await openDatabase(indexedDB, dbName)
    const key = await loadOrCreateKey(db)
    return new EvidenceVault({indexedDB, dbName, db, key, privateMode})
  }

  constructor({indexedDB, dbName, db, key, privateMode}) {
    this.indexedDB = indexedDB
    this.dbName = dbName
    this.db = db
    this.key = key
    this.privateMode = privateMode === true
    this.closed = false
  }

  ensureOpen() {
    if (this.closed || !this.db) throw vaultError("vault_closed")
  }

  async putEvidence(id, value) {
    this.ensureOpen()
    if (typeof id !== "string" || id.length === 0) throw vaultError("invalid_evidence_id")
    const plaintext = encode(value, rfc8949EncodeOptions)
    const iv = crypto.getRandomValues(new Uint8Array(12))
    const ciphertext = new Uint8Array(await crypto.subtle.encrypt({name: "AES-GCM", iv}, this.key, plaintext))
    const tx = this.db.transaction(RECORD_STORE, "readwrite")
    tx.objectStore(RECORD_STORE).put({id, version: 1, algorithm: "AES-GCM-256", iv, ciphertext})
    await transactionDone(tx)
  }

  async getEvidence(id) {
    this.ensureOpen()
    if (typeof id !== "string" || id.length === 0) throw vaultError("invalid_evidence_id")
    const tx = this.db.transaction(RECORD_STORE, "readonly")
    const record = await requestResult(tx.objectStore(RECORD_STORE).get(id))
    await transactionDone(tx)
    if (!record) return null
    if (record.version !== 1 || record.algorithm !== "AES-GCM-256" || !(record.iv instanceof Uint8Array) || !(record.ciphertext instanceof Uint8Array)) {
      throw vaultError("invalid_evidence_record")
    }
    try {
      const plaintext = new Uint8Array(await crypto.subtle.decrypt({name: "AES-GCM", iv: record.iv}, this.key, record.ciphertext))
      return strictDecode(plaintext)
    } catch (error) {
      if (error?.code === "evidence_decode_failed") throw error
      throw vaultError("evidence_decrypt_failed", error)
    }
  }

  async listEvidence() {
    this.ensureOpen()
    const tx = this.db.transaction(RECORD_STORE, "readonly")
    const records = await requestResult(tx.objectStore(RECORD_STORE).getAll())
    await transactionDone(tx)
    const result = []
    for (const record of records) result.push({id: record.id, value: await this.getEvidence(record.id)})
    return result
  }

  async debugRawRecord(id) {
    this.ensureOpen()
    const tx = this.db.transaction(RECORD_STORE, "readonly")
    const record = await requestResult(tx.objectStore(RECORD_STORE).get(id))
    await transactionDone(tx)
    return record ?? null
  }

  async close() {
    if (this.closed) return
    this.db?.close()
    this.db = null
    this.closed = true
    if (this.privateMode) await deleteDatabase(this.indexedDB, this.dbName)
    this.key = null
  }

  async destroyDatabase() {
    if (!this.closed) {
      this.db?.close()
      this.db = null
      this.closed = true
    }
    this.key = null
    await deleteDatabase(this.indexedDB, this.dbName)
  }
}
