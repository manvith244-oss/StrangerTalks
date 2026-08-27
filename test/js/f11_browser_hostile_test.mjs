import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT = 15_000
const SYNTHETIC_CONVERSATION = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const SYNTHETIC_RELATIONSHIP = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

async function session(browser, options = {}) {
  const context = await browser.newContext({viewport: {width: 1100, height: 760}})
  await context.addInitScript(() => {
    window.__f11Events = []
    addEventListener("strangertalks:canonical-readiness", ({detail = {}}) => window.__f11Events.push({status: detail.status, canonical_state: detail.canonical_state, terminal_retention: detail.terminal_retention || null}))
  })
  if (options.localStorageThrows) await context.addInitScript(() => {
    Storage.prototype.getItem = () => { throw new Error("localStorage blocked") }
    Storage.prototype.setItem = () => { throw new Error("localStorage blocked") }
    Storage.prototype.removeItem = () => { throw new Error("localStorage blocked") }
  })
  if (options.indexedDbThrows) await context.addInitScript(() => Object.defineProperty(window, "indexedDB", {configurable: true, value: {open() { throw new Error("IndexedDB blocked") }}}))
  const page = await context.newPage()
  const response = await page.goto(BASE, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok())
  await page.waitForFunction(() => Boolean(window.StrangerTalksF11), null, {timeout: WAIT})
  return {context, page}
}

async function ready(page, canonical) {
  await page.waitForFunction((expected) => {
    const state = window.StrangerTalksF11?.getReadiness?.()
    return state?.status === "READY" && state?.canonical_state === expected
  }, canonical, {timeout: WAIT})
  return page.evaluate(() => window.StrangerTalksF11.getReadiness())
}

async function language(page, value = "en") { await page.locator("#conversation-language").selectOption(value) }
async function queue(page) {
  await page.locator('button.door:has-text("Advice")').waitFor({state: "visible", timeout: WAIT})
  await page.locator('button.door:has-text("Advice")').click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: WAIT})
}
async function records(page) { return page.evaluate(async () => (await import("/assets/local_data.mjs")).listRecords()) }
async function conversationId(page) { return (await records(page)).find(r => r.type === "local_conversation" && r.value?.status === "temporary" && r.value?.connection_state !== "ended")?.value?.conversation_id || null }

async function pair(browser) {
  const a = await session(browser), b = await session(browser)
  await Promise.all([ready(a.page, "AVAILABLE"), ready(b.page, "AVAILABLE")])
  await Promise.all([language(a.page), language(b.page)])
  await queue(a.page)
  await b.page.locator('button.door:has-text("Advice")').click()
  await Promise.all([a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT}), b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})])
  return {a, b}
}

async function end(page) {
  const actions = page.locator("details.overflow")
  if ((await actions.getAttribute("open")) === null) await actions.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible", timeout: WAIT})
  await page.locator("#end-confirm").click()
  await page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT})
}
async function waitMarker(page, id) {
  await page.waitForFunction(async (conversationId) => (await (await import("/assets/local_data.mjs")).listRecords()).some(r => r.id === `terminal_retention:${conversationId}`), id, {timeout: WAIT})
}
async function retain(page, id, choice = "faded") {
  await page.evaluate(async ({id, choice}) => {
    const local = await import("/assets/local_data.mjs")
    await local.replaceRecords(local.chooseConversationRetention(await local.listRecords(), id, choice, {now: new Date().toISOString()}))
  }, {id, choice})
}
async function close(value) { await value?.context.close().catch(() => {}) }

for (const [name, options, storageMode] of [
  ["BROWSER-01 localStorage unavailable", {localStorageThrows: true}, null],
  ["BROWSER-02 IndexedDB unavailable", {indexedDbThrows: true}, "ephemeral"]
]) test(`${name} does not kill canonical online boot`, {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true}); let s
  try {
    s = await session(browser, options); await ready(s.page, "AVAILABLE")
    if (storageMode) {
      const status = await s.page.evaluate(() => indexedDB.storageStatus())
      assert.equal(status.mode, storageMode); assert.equal(status.durable, false)
    }
  } finally { await close(s); await browser.close().catch(() => {}) }
})

test("BROWSER-04 AVAILABLE readiness is pending before canonical reconciliation", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true}); let s
  try {
    s = await session(browser); await ready(s.page, "AVAILABLE")
    const events = await s.page.evaluate(() => window.__f11Events)
    assert.equal(events[0]?.status, "CANONICAL_STATE_PENDING")
    assert.equal(events.some(e => e.status === "READY" && e.canonical_state === "AVAILABLE"), true)
  } finally { await close(s); await browser.close().catch(() => {}) }
})

test("BROWSER-05/LANG final transport loss reconciles AVAILABLE without requeue and preserves future language", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true}); let s
  try {
    s = await session(browser); await ready(s.page, "AVAILABLE"); await language(s.page, "te"); await queue(s.page)
    const queued = await ready(s.page, "QUEUED")
    const staleQueueAttemptId = queued.snapshot.queue.queue_attempt_id
    assert.ok(staleQueueAttemptId)
    assert.equal(queued.snapshot.queue.conversation_language, "te")
    await s.page.evaluate(() => { const select = document.querySelector("#conversation-language"); select.value = "hi"; select.dispatchEvent(new Event("change", {bubbles: true})) })
    await s.page.reload({waitUntil: "domcontentloaded"})
    const state = await ready(s.page, "AVAILABLE")
    assert.equal(state.snapshot.queue, null)
    assert.notEqual(state.snapshot.queue?.queue_attempt_id, staleQueueAttemptId)
    assert.equal(await s.page.evaluate(() => window.StrangerTalksF11.getFutureConversationLanguage()), "hi")
    const afterFirstReconciliation = await s.page.evaluate(() => window.__f11Events.length)
    await s.page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")))
    await s.page.waitForFunction((n) => {
      const events = window.__f11Events || []
      return events.length >= n + 2 && events.slice(n).some(e => e.status === "CANONICAL_STATE_PENDING") && events.at(-1)?.status === "READY" && events.at(-1)?.canonical_state === "AVAILABLE"
    }, afterFirstReconciliation, {timeout: WAIT})
    const events = await s.page.evaluate(() => window.__f11Events)
    assert.equal(events[0]?.status, "CANONICAL_STATE_PENDING")
    assert.equal(events.some(e => e.status === "READY" && e.canonical_state === "AVAILABLE"), true)
    assert.equal(events.some(e => e.status === "READY" && e.canonical_state === "QUEUED"), false)
  } finally { await close(s); await browser.close().catch(() => {}) }
})

test("BROWSER-06 Conversation recovery stays pending until canonical CONVERSATION", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true}); let p
  try {
    p = await pair(browser); const id = await conversationId(p.a.page); assert.ok(id)
    await p.a.page.reload({waitUntil: "domcontentloaded"}); const state = await ready(p.a.page, "CONVERSATION")
    assert.equal(state.snapshot.conversation.conversation_id, id)
    const events = await p.a.page.evaluate(() => window.__f11Events)
    assert.equal(events[0]?.status, "CANONICAL_STATE_PENDING")
    assert.equal(events.some(e => e.status === "READY" && e.canonical_state === "AVAILABLE"), false)
  } finally { await close(p?.a); await close(p?.b); await browser.close().catch(() => {}) }
})

test("BROWSER-07/F-BLK-006 pending retention survives refresh without ACTIVE resurrection and cleans after choice", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true}); let p
  try {
    p = await pair(browser); const id = await conversationId(p.a.page); assert.ok(id)
    await end(p.a.page); await waitMarker(p.a.page, id); await p.a.page.reload({waitUntil: "domcontentloaded"})
    const state = await ready(p.a.page, "AVAILABLE")
    assert.equal(state.terminal_retention?.conversation_id, id)
    assert.equal(await p.a.page.locator('section[data-screen="conversation"].active').count(), 0)
    await retain(p.a.page, id, "faded")
    const after = await records(p.a.page)
    assert.equal(after.some(r => r.id === `sync_cursor:${id}` || r.id === `terminal_retention:${id}`), false)
    assert.equal(after.some(r => ["local_message", "local_voice_note"].includes(r.type) && r.value?.conversation_id === id), false)
  } finally { await close(p?.a); await close(p?.b); await browser.close().catch(() => {}) }
})

test("BROWSER-08 foreground return forces readiness back through pending reconciliation", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true}); let s
  try {
    s = await session(browser); await ready(s.page, "AVAILABLE"); const before = await s.page.evaluate(() => window.__f11Events.length)
    await s.page.bringToFront(); await s.page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")))
    await s.page.waitForFunction((n) => { const e = window.__f11Events || []; return e.length >= n + 2 && e.slice(n).some(x => x.status === "CANONICAL_STATE_PENDING") && e.at(-1)?.status === "READY" }, before, {timeout: WAIT})
  } finally { await close(s); await browser.close().catch(() => {}) }
})

test("BROWSER-09 participant replacement clears participant-bound recovery and preserves retained browser data", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true}); let s
  try {
    s = await session(browser); const first = await ready(s.page, "AVAILABLE"); const original = first.snapshot.participant_id
    await s.page.evaluate(async ({cid, rid}) => {
      const l = await import("/assets/local_data.mjs"), now = new Date().toISOString()
      await l.putRecord({id:`conversation:${cid}`,type:"local_conversation",value:{conversation_id:cid,door_type:"EXPLORE",display_door:"Advice",abstract_signature_seed:"sig",status:"temporary",connection_state:"connected",started_at:now,ended_at:null,summary_id:null},updated_at:now})
      await l.putRecord({id:`sync_cursor:${cid}`,type:"sync_cursor",value:{conversation_id:cid,epoch_id:"e",last_applied_sequence:1},updated_at:now})
      await l.putRecord({id:`bond-reconnect:${rid}`,type:"bond_reconnect_state",value:{relationship_id:rid,status:"idle"},updated_at:now})
      await l.putRecord({id:"memory:f11-browser",type:"memory",value:{text:"keep"},updated_at:now})
      await l.putRecord({id:`relationship:${rid}`,type:"relationship",value:{relationship_id:rid,status:"created",conversation_id:cid},updated_at:now})
      await l.deleteRecord("strangertalks.identity.v1")
    }, {cid:SYNTHETIC_CONVERSATION,rid:SYNTHETIC_RELATIONSHIP})
    const cleaned = await records(s.page)
    assert.equal(cleaned.some(r => ["local_conversation","sync_cursor","bond_reconnect_state"].includes(r.type)), false)
    assert.equal(cleaned.some(r => r.id === "memory:f11-browser"), true); assert.equal(cleaned.some(r => r.type === "relationship"), true)
    await s.page.reload({waitUntil:"domcontentloaded"}); const replacement = await ready(s.page,"AVAILABLE"); assert.notEqual(replacement.snapshot.participant_id, original)
  } finally { await close(s); await browser.close().catch(() => {}) }
})

test("BROWSER-10/11 repeated A-to-B lifecycles leave no stale recovery contamination", {timeout: 150_000}, async () => {
  const browser = await chromium.launch({headless: true}); let a; const peers = [], ended = []
  try {
    a = await session(browser); await ready(a.page,"AVAILABLE"); await language(a.page)
    for (let cycle=0; cycle<2; cycle++) {
      const b = await session(browser); peers.push(b); await ready(b.page,"AVAILABLE"); await language(b.page); await queue(a.page); await b.page.locator('button.door:has-text("Advice")').click()
      await Promise.all([a.page.locator('section[data-screen="conversation"].active').waitFor({state:"visible",timeout:WAIT}),b.page.locator('section[data-screen="conversation"].active').waitFor({state:"visible",timeout:WAIT})])
      const id = await conversationId(a.page); assert.ok(id); ended.push(id); await end(a.page); await waitMarker(a.page,id); await retain(a.page,id,"faded"); await a.page.reload({waitUntil:"domcontentloaded"}); await ready(a.page,"AVAILABLE"); await language(a.page)
    }
    assert.equal(new Set(ended).size, ended.length)
    const final = await records(a.page)
    for (const id of ended) assert.equal(final.some(r => r.id === `sync_cursor:${id}` || r.id === `terminal_retention:${id}` || (["local_message","local_voice_note"].includes(r.type) && r.value?.conversation_id===id)), false)
  } finally { await close(a); for (const b of peers) await close(b); await browser.close().catch(() => {}) }
})
