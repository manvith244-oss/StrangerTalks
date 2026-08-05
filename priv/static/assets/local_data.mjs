const DB_NAME = "strangertalks-local-v1"
const STORE = "records"
const BACKUP_VERSION = 1

export function mergeRecords(current, imported) {
  const merged = new Map(current.map((record) => [record.id, record]))
  for (const record of imported) {
    const existing = merged.get(record.id)
    if (!existing || Date.parse(record.updated_at) > Date.parse(existing.updated_at)) merged.set(record.id, record)
  }
  return [...merged.values()]
}

export function validEnvelope(envelope) {
  return envelope?.version === BACKUP_VERSION && envelope.kdf === "PBKDF2-SHA256" && envelope.cipher === "AES-GCM" &&
    typeof envelope.salt === "string" && typeof envelope.iv === "string" && typeof envelope.ciphertext === "string"
}

export async function encryptBackup(records, passphrase) {
  if (!passphrase) throw new Error("passphrase_required")
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const key = await deriveKey(passphrase, salt, ["encrypt"])
  const plaintext = new TextEncoder().encode(JSON.stringify({records}))
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
  if (!Array.isArray(payload.records) || payload.records.some((record) => !validRecord(record))) throw new Error("invalid_backup")
  return payload.records
}

export async function getRecord(id) { return request("readonly", (store) => store.get(id)) }
export async function listRecords() { return request("readonly", (store) => store.getAll()) }
export async function putRecord(record) { if (!validRecord(record)) throw new Error("invalid_record"); return request("readwrite", (store) => store.put(record)) }
export async function deleteRecord(id) { return request("readwrite", (store) => store.delete(id)) }
export async function clearRecords() { return request("readwrite", (store) => store.clear()) }
export async function importRecords(imported) { const merged = mergeRecords(await listRecords(), imported); await clearRecords(); for (const record of merged) await putRecord(record); return merged }

function validRecord(record) { return record && typeof record.id === "string" && typeof record.type === "string" && !Number.isNaN(Date.parse(record.updated_at)) }
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
