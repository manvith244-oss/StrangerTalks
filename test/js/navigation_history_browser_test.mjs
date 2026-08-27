import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT_MS = 12_000
const DESTRUCTIVE_EVENTS = new Set([
  "queue:leave",
  "conversation:end",
  "conversation:block",
  "conversation:report"
])

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_error) {
    return null
  }
}

class Journal {
  constructor() {
    this.events = []
    this.waiters = new Set()
  }

  add(event) {
    this.events.push(event)
    for (const waiter of [...this.waiters]) {
      if (!waiter.predicate(event)) continue
      clearTimeout(waiter.timer)
      this.waiters.delete(waiter)
      waiter.resolve(event)
    }
  }

  mark() {
    return this.events.length
  }

  waitFor(predicate, label, from = 0) {
    const existing = this.events.slice(from).find(predicate)
    if (existing) return Promise.resolve(existing)

    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, timer: null}
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter)
        const recent = this.events.slice(-20).map(({type, topic, event, body}) => ({
          type,
          topic,
          event,
          status: body?.status,
          responseStatus: body?.response?.status,
          canonicalState: body?.response?.snapshot?.canonical_state
        }))
        reject(new Error(`Timed out waiting for ${label}; recent events: ${JSON.stringify(recent)}`))
      }, WAIT_MS)
      this.waiters.add(waiter)
    })
  }
}

async function observePage(context, page) {
  const journal = new Journal()
  page.on("websocket", websocket => {
    websocket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_sent", ...message})
    })
    websocket.on("framereceived", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_received", ...message})
    })
  })
  return {page, journal}
}

async function waitForParticipantJoin(observed, from = 0) {
  return observed.journal.waitFor(
    event => event.type === "frame_received" &&
      event.topic?.startsWith("participant:") &&
      event.event === "phx_reply" &&
      event.body?.status === "ok" &&
      event.body?.response?.status === "connected",
    "ParticipantChannel join",
    from
  )
}

async function boot(browser, path = "/") {
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const page = await context.newPage()
  const response = await page.goto(`${BASE_URL}${path}`, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), `${path} loads`)
  await page.locator("#bottom-nav").waitFor({state: "attached", timeout: WAIT_MS})
  await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: WAIT_MS})
  return {context, page}
}

async function bootObserved(browser, path = "/") {
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const page = await context.newPage()
  const observed = await observePage(context, page)
  const response = await page.goto(`${BASE_URL}${path}`, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), `${path} loads`)
  await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: WAIT_MS})
  await waitForParticipantJoin(observed)
  await page.locator("#conversation-language").selectOption("en")
  return {context, ...observed}
}

function activeScreen(page, screen) {
  return page.locator(`section[data-screen="${screen}"].active`)
}

async function clickPrimary(page, label) {
  await page.locator(`#bottom-nav button:has-text("${label}")`).click()
}

async function clickHiddenPrimary(page, screen) {
  await page.locator(`#bottom-nav [data-go="${screen}"]`).evaluate(button => button.click())
}

async function clickDoorAndQueue(observed, label) {
  const mark = observed.journal.mark()
  const door = observed.page.locator(`button.door:has-text("${label}")`)
  await door.waitFor({state: "visible"})
  await door.click()
  const queued = await observed.journal.waitFor(
    event => event.type === "frame_received" && event.event === "queue:status" && event.body?.status === "queued",
    "queued status",
    mark
  )
  await activeScreen(observed.page, "queue").waitFor({state: "visible"})
  return queued.body?.queue_attempt_id
}

async function waitForConversation(observed, from = 0) {
  await activeScreen(observed.page, "conversation").waitFor({state: "visible"})
  const joined = await observed.journal.waitFor(
    event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
    "ConversationChannel join",
    from
  )
  return joined.topic
}

async function matchPair(browser, door = "Advice") {
  const a = await bootObserved(browser)
  const b = await bootObserved(browser)
  await activeScreen(a.page, "doors").waitFor({state: "visible"})
  await activeScreen(b.page, "doors").waitFor({state: "visible"})
  await clickDoorAndQueue(a, door)
  const markA = a.journal.mark()
  const markB = b.journal.mark()
  await b.page.locator(`button.door:has-text("${door}")`).click()
  const [conversationA, conversationB] = await Promise.all([
    waitForConversation(a, markA),
    waitForConversation(b, markB)
  ])
  assert.equal(conversationA, conversationB)
  return {a, b, conversationTopic: conversationA}
}

async function confirmEndConversation(page) {
  const actions = page.locator("details.overflow")
  if ((await actions.getAttribute("open")) === null) await actions.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
}

function destructiveFrames(observed, from = 0) {
  return observed.journal.events.slice(from).filter(event =>
    event.type === "frame_sent" && DESTRUCTIVE_EVENTS.has(event.event)
  )
}

test("F03 browser J01/J02: primary navigation writes canonical URLs and Back/Forward preserves order", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let context
  try {
    const booted = await boot(browser)
    context = booted.context
    const page = booted.page

    await clickPrimary(page, "Chats")
    await activeScreen(page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")

    await clickPrimary(page, "Bonds")
    await activeScreen(page, "relationships").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/bonds")

    await clickPrimary(page, "You")
    await activeScreen(page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "relationships").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/bonds")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")

    await page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(page, "relationships").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/bonds")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser J12/J13: direct canonical entry presents route and secondary Back uses canonical parent", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let context
  try {
    const booted = await boot(browser, "/you/memories")
    context = booted.context
    const page = booted.page

    await activeScreen(page, "memories").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you/memories")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser active primary destination is route-derived via aria-current", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let context
  try {
    const booted = await boot(browser, "/you/reflections")
    context = booted.context
    const page = booted.page

    await activeScreen(page, "reflections").waitFor({state: "visible"})
    const selected = page.locator('#bottom-nav button[aria-current="page"]')
    assert.equal(await selected.count(), 1)
    assert.equal((await selected.textContent()).trim(), "You")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser J05/J06/J15: QUEUED navigation away and Back/Forward preserve queue without Cancel", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let observed
  try {
    observed = await bootObserved(browser)
    await activeScreen(observed.page, "doors").waitFor({state: "visible"})
    const queueAttemptId = await clickDoorAndQueue(observed, "Advice")
    assert.ok(queueAttemptId)
    assert.equal(new URL(observed.page.url()).pathname, "/matchmaking")

    const navigationMark = observed.journal.mark()
    await clickHiddenPrimary(observed.page, "settings")
    await activeScreen(observed.page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(observed.page.url()).pathname, "/you")
    assert.deepEqual(destructiveFrames(observed, navigationMark), [])

    await observed.page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(observed.page, "queue").waitFor({state: "visible"})
    assert.equal(new URL(observed.page.url()).pathname, "/matchmaking")
    assert.deepEqual(destructiveFrames(observed, navigationMark), [])

    await observed.page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(observed.page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(observed.page.url()).pathname, "/you")
    assert.deepEqual(destructiveFrames(observed, navigationMark), [])
  } finally {
    await observed?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser J07/J08/J15: match_found replaces transient matchmaking and active Conversation Back is non-destructive", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation")

    const navigationMark = pair.a.journal.mark()
    await pair.a.page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(pair.a.page, "doors").waitFor({state: "visible"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/")
    assert.deepEqual(destructiveFrames(pair.a, navigationMark), [])

    await pair.a.page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(pair.a.page, "conversation").waitFor({state: "visible"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation")

    await clickHiddenPrimary(pair.a.page, "chats")
    await activeScreen(pair.a.page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/chats")
    assert.deepEqual(destructiveFrames(pair.a, navigationMark), [])

    await pair.a.page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(pair.a.page, "conversation").waitFor({state: "visible"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation")
    assert.deepEqual(destructiveFrames(pair.a, navigationMark), [])
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser J09: terminal route replaces active Conversation and stale history cannot resurrect ACTIVE", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation")

    await confirmEndConversation(pair.a.page)
    await activeScreen(pair.a.page, "ended").waitFor({state: "visible"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation/ended")

    await pair.a.page.goBack({waitUntil: "domcontentloaded"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/")
    assert.equal(await activeScreen(pair.a.page, "conversation").count(), 0)

    await pair.a.page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(pair.a.page, "ended").waitFor({state: "visible"})
    assert.equal(new URL(pair.a.page.url()).pathname, "/conversation/ended")

    await pair.a.page.evaluate(() => {
      history.pushState({staleConversation: true}, "", "/conversation")
      dispatchEvent(new PopStateEvent("popstate", {state: history.state}))
    })
    await pair.a.page.waitForFunction(() => location.pathname !== "/conversation", null, {timeout: WAIT_MS})
    assert.notEqual(new URL(pair.a.page.url()).pathname, "/conversation")
    assert.equal(await activeScreen(pair.a.page, "conversation").count(), 0)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser J10: direct unavailable Conversation canonicalizes with replace", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let observed
  try {
    observed = await bootObserved(browser, "/conversation")
    await activeScreen(observed.page, "unrecoverable").waitFor({state: "visible"})
    assert.equal(new URL(observed.page.url()).pathname, "/conversation/unavailable")
  } finally {
    await observed?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
