import fs from "node:fs"
import path from "node:path"
import {execFileSync} from "node:child_process"
import {randomUUID, createHash} from "node:crypto"
import {createRequire} from "node:module"

const require = createRequire(path.join(process.cwd(), "package.json"))
const {chromium} = require("playwright")

const BASE = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const EVIDENCE_DIR = process.env.WT05_EVIDENCE_DIR
const PROFILE_DIR = process.env.WT05_PROFILE_DIR
const NEG_PROFILE_DIR = process.env.WT05_NEG_PROFILE_DIR
const JSONL = path.join(EVIDENCE_DIR, "same-account-rebind.jsonl")
const WAIT = 20_000
const MEMORY_ID = "memory:wt05-same-account-rebind"
const MARKER = "WT05 same-account rebind continuity marker"
const PASS = `wt05-${randomUUID()}-${randomUUID()}`
const KEY_DB = "strangertalks-sync-key-v1"
const KEY_STORE = "keys"

fs.mkdirSync(EVIDENCE_DIR, {recursive: true})
fs.rmSync(PROFILE_DIR, {recursive: true, force: true})
fs.rmSync(NEG_PROFILE_DIR, {recursive: true, force: true})

const invalid = []
let context = null
let page = null
let oldContinuity = null
let oldParticipant = null
let newParticipant = null
let envelopeHash = null
let memoryHash = hashString(MARKER)
let sameReconnect = null
let restartObservation = null
let unrelatedContinuity = null

function hashString(value) {
  return createHash("sha256").update(String(value)).digest("hex")
}

function emit(record) {
  const line = JSON.stringify({...record, observed_at: new Date().toISOString()})
  console.log(line)
  fs.appendFileSync(JSONL, line + "\n")
}

function sanitizeError(error) {
  return {
    name: error?.name || "Error",
    message: String(error?.message || error),
    stack: String(error?.stack || "").split("\n").slice(0, 8)
  }
}

async function phase(name, fn) {
  console.log(`${name}_BEGIN`)
  try {
    const result = await fn()
    emit({phase: name, status: "complete", result})
    return result
  } catch (error) {
    const result = {phase: name, status: "invalid", error: sanitizeError(error)}
    invalid.push(result)
    emit(result)
    if (page && !page.isClosed()) {
      await page.screenshot({path: path.join(EVIDENCE_DIR, `${name.toLowerCase()}.png`), fullPage: true}).catch(() => {})
    }
    return null
  } finally {
    console.log(`${name}_END`)
  }
}

function profileProcesses(profile) {
  const output = execFileSync("ps", ["-eo", "pid=,args="], {encoding: "utf8"})
  return output.split("\n")
    .map(line => line.trim())
    .filter(Boolean)
    .filter(line => line.includes(profile))
    .filter(line => /\b(chrome|chromium)\b/i.test(line))
    .map(line => Number(line.match(/^(\d+)/)?.[1] || 0))
    .filter(Boolean)
}

async function waitNoProcesses(profile, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  let procs = profileProcesses(profile)
  while (Date.now() < deadline && procs.length) {
    await new Promise(resolve => setTimeout(resolve, 200))
    procs = profileProcesses(profile)
  }
  return procs
}

async function launch(profile) {
  const ctx = await chromium.launchPersistentContext(profile, {
    headless: true,
    viewport: {width: 1280, height: 800}
  })

  await ctx.addInitScript(({keyStore}) => {
    globalThis.__wt05KeyEvents = []

    if (!IDBObjectStore.prototype.__wt05GetWrapped) {
      const originalGet = IDBObjectStore.prototype.get
      Object.defineProperty(IDBObjectStore.prototype, "__wt05GetWrapped", {value: true})
      IDBObjectStore.prototype.get = function(key) {
        const watched = this?.name === keyStore
        const request = Reflect.apply(originalGet, this, arguments)
        if (watched) {
          const rawKey = typeof key === "string" ? key : String(key)
          request.addEventListener("success", () => {
            const value = request.result
            globalThis.__wt05KeyEvents.push({
              operation: "get",
              slot: rawKey,
              returned: Boolean(value),
              crypto_key: typeof CryptoKey !== "undefined" && value instanceof CryptoKey,
              algorithm: value?.algorithm?.name || null,
              extractable: typeof value?.extractable === "boolean" ? value.extractable : null,
              usages: Array.isArray(value?.usages) ? [...value.usages] : []
            })
          })
        }
        return request
      }
    }

    if (!IDBObjectStore.prototype.__wt05PutWrapped) {
      const originalPut = IDBObjectStore.prototype.put
      Object.defineProperty(IDBObjectStore.prototype, "__wt05PutWrapped", {value: true})
      IDBObjectStore.prototype.put = function(value, key) {
        if (this?.name === keyStore) {
          const rawKey = typeof key === "string" ? key : String(key)
          globalThis.__wt05KeyEvents.push({
            operation: "put",
            slot: rawKey,
            crypto_key: typeof CryptoKey !== "undefined" && value instanceof CryptoKey,
            algorithm: value?.algorithm?.name || null,
            extractable: typeof value?.extractable === "boolean" ? value.extractable : null,
            usages: Array.isArray(value?.usages) ? [...value.usages] : []
          })
        }
        return Reflect.apply(originalPut, this, arguments)
      }
    }
  }, {keyStore: KEY_STORE})

  const p = ctx.pages()[0] || await ctx.newPage()
  p.on("pageerror", error => emit({kind: "pageerror", error: sanitizeError(error)}))
  p.on("console", message => {
    if (message.type() === "error") emit({kind: "console_error", text: message.text()})
  })
  return {context: ctx, page: p}
}

async function waitReady(p) {
  const response = await p.goto(BASE, {waitUntil: "domcontentloaded", timeout: WAIT})
  if (!response?.ok()) throw new Error(`root_http_${response?.status()}`)
  await p.waitForFunction(() => window.StrangerTalksF11?.getReadiness?.()?.status === "READY", null, {timeout: WAIT})
  await p.waitForFunction(async () => {
    const local = await import("/assets/local_data.mjs")
    return (await local.listRecords()).some(record => record.type === "identity" && record.value?.participant_id && record.value?.token)
  }, null, {timeout: WAIT})
}

async function settings(p) {
  await p.locator('#bottom-nav [data-go="settings"]').click()
  await p.locator('section[data-screen="settings"].active').waitFor({state: "visible", timeout: WAIT})
}

async function account(p) {
  return p.evaluate(async () => {
    const response = await fetch("/api/account/session", {credentials: "same-origin"})
    return response.json()
  })
}

async function identity(p) {
  return p.evaluate(async () => {
    const local = await import("/assets/local_data.mjs")
    const record = (await local.listRecords()).find(item => item.type === "identity")
    return {
      participant_id: record?.value?.participant_id || null,
      token_present: Boolean(record?.value?.token)
    }
  })
}

async function memory(p) {
  return p.evaluate(async ({id}) => {
    const local = await import("/assets/local_data.mjs")
    const record = (await local.listRecords()).find(item => item.id === id)
    return record ? {id: record.id, type: record.type, text: record.value?.text || null} : null
  }, {id: MEMORY_ID})
}

async function putDiagnosticMemory(p) {
  return p.evaluate(async ({id, marker}) => {
    const local = await import("/assets/local_data.mjs")
    const record = {id, type: "memory", schema_version: 1, value: {text: marker}, updated_at: new Date().toISOString()}
    await local.putRecord(record)
    return true
  }, {id: MEMORY_ID, marker: MARKER})
}

async function keySlots(p) {
  return p.evaluate(async ({dbName, storeName}) => {
    const dbs = typeof indexedDB.databases === "function" ? await indexedDB.databases() : []
    if (dbs.length && !dbs.some(db => db.name === dbName)) return []
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(dbName)
      request.onerror = () => reject(request.error)
      request.onsuccess = () => resolve(request.result)
    })
    if (!db.objectStoreNames.contains(storeName)) {
      db.close()
      return []
    }
    const [keys, values] = await Promise.all([
      new Promise((resolve, reject) => {
        const request = db.transaction(storeName, "readonly").objectStore(storeName).getAllKeys()
        request.onerror = () => reject(request.error)
        request.onsuccess = () => resolve(request.result)
      }),
      new Promise((resolve, reject) => {
        const request = db.transaction(storeName, "readonly").objectStore(storeName).getAll()
        request.onerror = () => reject(request.error)
        request.onsuccess = () => resolve(request.result)
      })
    ])
    db.close()
    return keys.map((key, index) => {
      const value = values[index]
      return {
        slot: String(key),
        crypto_key: typeof CryptoKey !== "undefined" && value instanceof CryptoKey,
        algorithm: value?.algorithm?.name || null,
        extractable: typeof value?.extractable === "boolean" ? value.extractable : null,
        usages: Array.isArray(value?.usages) ? [...value.usages] : []
      }
    })
  }, {dbName: KEY_DB, storeName: KEY_STORE})
}

async function keyEvents(p) {
  return p.evaluate(() => Array.isArray(globalThis.__wt05KeyEvents) ? globalThis.__wt05KeyEvents.map(event => ({...event})) : [])
}

function sanitizeKeyEvents(events, continuity) {
  const expected = `account:${continuity}`
  return events.map(event => ({
    operation: event.operation,
    requested_old_slot: event.slot === expected,
    slot_hash: hashString(event.slot),
    returned: event.returned ?? null,
    crypto_key: event.crypto_key ?? null,
    algorithm: event.algorithm ?? null,
    extractable: event.extractable ?? null,
    usages: event.usages || []
  }))
}

async function remoteSync(p) {
  return p.evaluate(async () => {
    const response = await fetch("/api/account/sync", {credentials: "same-origin", headers: {accept: "application/json"}})
    return {status: response.status, body: await response.json().catch(() => ({}))}
  })
}

function dialogAccepter(p, {passphrase = null} = {}) {
  const handler = async dialog => {
    if (dialog.type() === "prompt") await dialog.accept(passphrase || "")
    else await dialog.accept()
  }
  p.on("dialog", handler)
  return () => p.off("dialog", handler)
}

async function connect(p, selector, {acceptDialogs = false} = {}) {
  await settings(p)
  const remove = acceptDialogs ? dialogAccepter(p) : () => {}
  try {
    await p.locator(selector).click()
    await p.waitForFunction(() => window.app?.account?.connected === true, null, {timeout: WAIT})
    await p.waitForFunction(() => window.StrangerTalksF11?.getReadiness?.()?.status === "READY", null, {timeout: WAIT})
    await p.waitForFunction(() => location.search === "", null, {timeout: WAIT})
  } finally {
    remove()
  }
}

async function logout(p) {
  await settings(p)
  const remove = dialogAccepter(p)
  try {
    await p.locator("#account-logout").click()
    await p.waitForFunction(() => window.StrangerTalksF11?.getReadiness?.()?.status === "READY", null, {timeout: WAIT})
    await p.waitForFunction(() => window.app?.account?.connected === false, null, {timeout: WAIT})
  } finally {
    remove()
  }
}

await phase("WT05_3D_PRE_CONNECTED", async () => {
  const launched = await launch(PROFILE_DIR)
  context = launched.context
  page = launched.page
  await waitReady(page)

  await connect(page, "#account-link")
  const acc = await account(page)
  if (!acc.connected || !acc.continuity_id) throw new Error("disposable_account_not_connected")
  oldContinuity = acc.continuity_id

  const ident = await identity(page)
  oldParticipant = ident.participant_id
  if (!oldParticipant) throw new Error("old_participant_missing")

  await putDiagnosticMemory(page)
  if ((await memory(page))?.text !== MARKER) throw new Error("diagnostic_memory_missing")

  await settings(page)
  const remove = dialogAccepter(page, {passphrase: PASS})
  try {
    await page.locator("#sync-now").click()
    await page.waitForFunction(() => document.querySelector("#status")?.textContent?.includes("Encrypted Google sync created"), null, {timeout: WAIT})
  } finally {
    remove()
  }

  const slots = await keySlots(page)
  const oldSlot = slots.find(slot => slot.slot === `account:${oldContinuity}`)
  if (!oldSlot?.crypto_key || oldSlot.extractable !== false || oldSlot.algorithm !== "AES-GCM") throw new Error("old_key_slot_invalid")

  const remote = await remoteSync(page)
  if (remote.status !== 200 || remote.body?.status !== "ready" || !remote.body?.envelope) throw new Error("pre_delete_remote_sync_missing")
  envelopeHash = hashString(JSON.stringify(remote.body.envelope))

  await settings(page)
  const restoreDialogs = dialogAccepter(page)
  try {
    await page.locator("#sync-restore").click()
    await page.waitForFunction(() => document.querySelector("#status")?.textContent?.includes("Encrypted Google data was restored"), null, {timeout: WAIT})
  } finally {
    restoreDialogs()
  }

  if ((await memory(page))?.text !== MARKER) throw new Error("pre_delete_normal_restore_failed")

  return {
    disposable_account: true,
    old_participant_hash: hashString(oldParticipant),
    continuity_id_hash: hashString(oldContinuity),
    old_slot_hash: hashString(`account:${oldContinuity}`),
    key_present: true,
    key_non_extractable: oldSlot.extractable === false,
    key_algorithm: oldSlot.algorithm,
    key_usages: oldSlot.usages,
    pre_delete_envelope_hash: envelopeHash,
    pre_delete_decrypt: true,
    memory_marker_hash: memoryHash
  }
})

if (!invalid.length) {
  await phase("WT05_3D_DELETE_ALL", async () => {
    await settings(page)
    const remove = dialogAccepter(page)
    try {
      await page.locator("#delete-all").click()
      await page.waitForFunction(expected => document.querySelector("#status")?.textContent?.trim() === expected,
        "All prior local data was deleted. A new anonymous identity was created.", {timeout: WAIT})
    } finally {
      remove()
    }

    const ident = await identity(page)
    newParticipant = ident.participant_id
    const oldMemory = await memory(page)
    const slots = await keySlots(page)
    const oldSlot = slots.find(slot => slot.slot === `account:${oldContinuity}`)

    if (!newParticipant || newParticipant === oldParticipant) throw new Error("identity_not_rotated")
    if (oldMemory) throw new Error("old_memory_not_removed")
    if (!oldSlot?.crypto_key) throw new Error("predecessor_divergence_old_key_missing")

    const acc = await account(page)
    return {
      product_action: "#delete-all",
      succeeded: true,
      old_primary_memory_removed: true,
      anonymous_identity_rotated: true,
      old_participant_hash: hashString(oldParticipant),
      new_participant_hash: hashString(newParticipant),
      connected_session_after_delete: Boolean(acc.connected),
      old_continuity_key_remains: true,
      product_message: await page.locator("#status").textContent()
    }
  })
}

if (!invalid.length) {
  await phase("WT05_3D_ANONYMOUS_CONTROL", async () => {
    await logout(page)
    const acc = await account(page)
    const ident = await identity(page)
    const events = sanitizeKeyEvents(await keyEvents(page), oldContinuity)
    const restored = await memory(page)

    if (acc.connected) throw new Error("anonymous_control_account_still_connected")
    if (ident.participant_id !== newParticipant) throw new Error("anonymous_control_identity_changed")

    return {
      old_continuity_id_exposed: acc.continuity_id === oldContinuity,
      old_key_requested: events.some(event => event.operation === "get" && event.requested_old_slot),
      old_memory_restored: Boolean(restored),
      participant_hash: hashString(ident.participant_id),
      key_events: events
    }
  })
}

if (!invalid.length) {
  await phase("WT05_3D_SAME_ACCOUNT_RECONNECT", async () => {
    await connect(page, "#account-login", {acceptDialogs: true})
    const acc = await account(page)
    const events = sanitizeKeyEvents(await keyEvents(page), oldContinuity)
    const restored = await memory(page)
    const slots = await keySlots(page)
    const oldSlot = slots.find(slot => slot.slot === `account:${oldContinuity}`)
    const replacementPut = events.some(event => event.operation === "put" && event.requested_old_slot)
    const remote = await remoteSync(page)
    const reconnectEnvelopeHash = remote.body?.envelope ? hashString(JSON.stringify(remote.body.envelope)) : null
    const oldMaterialDiscovered = remote.status === 200 && remote.body?.status === "ready" && reconnectEnvelopeHash === envelopeHash
    const productRequestedOldKey = events.some(event => event.operation === "get" && event.requested_old_slot)
    const oldKeyReturned = events.some(event => event.operation === "get" && event.requested_old_slot && event.returned && event.crypto_key)

    sameReconnect = {
      normal_product_flow: true,
      same_account: Boolean(acc.connected),
      pre_delete_continuity_id_restored: acc.continuity_id === oldContinuity,
      observed_continuity_id_hash: acc.continuity_id ? hashString(acc.continuity_id) : null,
      product_requested_key: productRequestedOldKey,
      requested_slot_equals_old_continuity_id: productRequestedOldKey,
      old_crypto_key_returned: oldKeyReturned,
      manual_diagnostic_injection: false,
      replacement_key_generated: replacementPut,
      old_encrypted_material_discovered: oldMaterialDiscovered,
      reconnect_envelope_hash: reconnectEnvelopeHash,
      old_key_used: productRequestedOldKey && oldKeyReturned && restored?.text === MARKER,
      decrypt_succeeded: restored?.text === MARKER,
      exact_pre_delete_memory_restored: restored?.text === MARKER,
      old_key_slot_still_present: Boolean(oldSlot?.crypto_key),
      key_events: events
    }

    return sameReconnect
  })
}

if (!invalid.length) {
  await phase("WT05_3D_BROWSER_RESTART", async () => {
    const before = profileProcesses(PROFILE_DIR)
    await context.close()
    const afterClose = await waitNoProcesses(PROFILE_DIR)
    if (!before.length || afterClose.length) throw new Error("full_browser_restart_not_proven")

    const relaunched = await launch(PROFILE_DIR)
    context = relaunched.context
    page = relaunched.page
    await waitReady(page)

    const acc = await account(page)
    const eventsBeforeRestore = sanitizeKeyEvents(await keyEvents(page), oldContinuity)
    const beforeRestoreMemory = await memory(page)

    await settings(page)
    const remove = dialogAccepter(page)
    try {
      await page.locator("#sync-restore").click()
      await page.waitForFunction(() => document.querySelector("#status")?.textContent?.includes("Encrypted Google data was restored"), null, {timeout: WAIT})
    } finally {
      remove()
    }

    const afterRestoreMemory = await memory(page)
    restartObservation = {
      full_chromium_restart: true,
      same_continuity_restored: acc.continuity_id === oldContinuity,
      old_key_automatically_loaded: eventsBeforeRestore.some(event => event.operation === "get" && event.requested_old_slot && event.returned && event.crypto_key),
      memory_present_before_explicit_restore: beforeRestoreMemory?.text === MARKER,
      decrypt_restore_persists: afterRestoreMemory?.text === MARKER,
      key_events_before_explicit_restore: eventsBeforeRestore
    }
    return restartObservation
  })
}

if (!invalid.length) {
  await phase("WT05_3D_NEGATIVE_CONTROL", async () => {
    const negative = await launch(NEG_PROFILE_DIR)
    const negContext = negative.context
    const negPage = negative.page
    await waitReady(negPage)
    await connect(negPage, "#account-link")
    const acc = await account(negPage)
    if (!acc.connected || !acc.continuity_id) throw new Error("negative_account_not_connected")
    unrelatedContinuity = acc.continuity_id
    if (unrelatedContinuity === oldContinuity) throw new Error("negative_control_continuity_not_distinct")

    const resolved = await page.evaluate(async ({continuityId}) => {
      const sync = await import("/assets/encrypted_sync.mjs")
      return Boolean(await sync.loadSyncKey(continuityId))
    }, {continuityId: unrelatedContinuity})

    await negContext.close()

    return {
      unrelated_continuity_id_hash: hashString(unrelatedContinuity),
      distinct_from_old: true,
      old_key_resolved: resolved
    }
  })
}

const critical = []
const important = []
let verdict = "BLOCKED — OTHER"

if (!invalid.length && sameReconnect) {
  if (!sameReconnect.pre_delete_continuity_id_restored) {
    verdict = "SAME_ACCOUNT_DOES_NOT_REESTABLISH_OLD_CONTINUITY_ID"
  } else if (!sameReconnect.product_requested_key || !sameReconnect.old_crypto_key_returned) {
    verdict = "SAME_CONTINUITY_REESTABLISHED_BUT_OLD_KEY_NOT_AUTOMATICALLY_LOADED"
  } else if (sameReconnect.decrypt_succeeded && sameReconnect.exact_pre_delete_memory_restored) {
    verdict = "PRODUCT_CONTINUITY_BRIDGE_EXISTS_AFTER_IDENTITY_RESET"
    critical.push("Same-account reconnect reclaims surviving pre-delete cryptographic authority and restores pre-delete Memory through the normal product path.")
  } else {
    verdict = "AUTOMATIC_CRYPTOGRAPHIC_REBIND_EXISTS_BUT_PRODUCT_RESTORE_NOT_PROVEN"
    important.push("Same-account reconnect automatically loads the surviving old key, but normal product restore was not proven complete.")
  }
}

const summary = {
  experiment_valid: invalid.length === 0,
  invalid_failures: invalid,
  boundary_verdict: verdict,
  same_account_reconnect: sameReconnect,
  browser_restart: restartObservation,
  memory_marker_hash: memoryHash,
  pre_delete_envelope_hash: envelopeHash,
  manual_key_injection: false,
  raw_key_material_emitted: false,
  credentials_emitted: false,
  findings: {critical, important, minor: []}
}

emit({phase: "WT05_3D_SUMMARY", status: invalid.length ? "invalid" : "complete", result: summary})

await context?.close().catch(() => {})
if (invalid.length) process.exitCode = 1
