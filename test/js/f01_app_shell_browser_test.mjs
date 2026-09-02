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
        reject(new Error(`Timed out waiting for ${label}`))
      }, WAIT_MS)
      this.waiters.add(waiter)
    })
  }
}

async function observePage(page) {
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
  return journal
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

async function bootObserved(browser, viewport, path = "/") {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  const journal = await observePage(page)
  const response = await page.goto(`${BASE_URL}${path}`, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), `${path} loads`)
  await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: WAIT_MS})
  const observed = {context, page, journal}
  await waitForParticipantJoin(observed)
  await page.locator("#conversation-language").selectOption("en")
  return observed
}

function activeScreen(page, screen) {
  return page.locator(`section[data-screen="${screen}"].active`)
}

async function clickDoorAndQueue(observed, label) {
  const mark = observed.journal.mark()
  await observed.page.locator(`button.door:has-text("${label}")`).click()
  await observed.journal.waitFor(
    event => event.type === "frame_received" && event.event === "queue:status" && event.body?.status === "queued",
    "queued status",
    mark
  )
  await activeScreen(observed.page, "queue").waitFor({state: "visible"})
}

async function waitForConversation(observed, from = 0) {
  await activeScreen(observed.page, "conversation").waitFor({state: "visible"})
  return observed.journal.waitFor(
    event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
    "ConversationChannel join",
    from
  )
}

async function matchPair(browser, viewport) {
  const a = await bootObserved(browser, viewport)
  const b = await bootObserved(browser, viewport)
  await activeScreen(a.page, "doors").waitFor({state: "visible"})
  await activeScreen(b.page, "doors").waitFor({state: "visible"})
  await clickDoorAndQueue(a, "Advice")
  const markA = a.journal.mark()
  const markB = b.journal.mark()
  await b.page.locator('button.door:has-text("Advice")').click()
  const [joinedA, joinedB] = await Promise.all([
    waitForConversation(a, markA),
    waitForConversation(b, markB)
  ])
  assert.equal(joinedA.topic, joinedB.topic)
  return {a, b, conversationTopic: joinedA.topic}
}

function destructiveFrames(observed, from = 0) {
  return observed.journal.events.slice(from).filter(event =>
    event.type === "frame_sent" && DESTRUCTIVE_EVENTS.has(event.event)
  )
}

function conversationJoinCount(observed, topic) {
  return observed.journal.events.filter(event =>
    event.type === "frame_sent" && event.topic === topic && event.event === "phx_join"
  ).length
}

async function assertOnePrimaryNav(page) {
  assert.equal(await page.locator('nav[aria-label="Primary"]').count(), 1, "exactly one primary navigation region")
  const nav = page.locator("#bottom-nav")
  await nav.waitFor({state: "visible"})
  assert.deepEqual(
    await nav.locator("button").allTextContents(),
    ["Talk", "Chats", "Bonds", "You"]
  )
  return nav
}

async function assertCompactBottomNav(page, viewport) {
  const nav = await assertOnePrimaryNav(page)
  const box = await nav.boundingBox()
  assert.ok(box, "compact primary nav has geometry")
  assert.ok(box.width > viewport.width * 0.85, `compact nav spans the viewport: ${JSON.stringify(box)}`)
  assert.ok(box.height < viewport.height * 0.25, `compact nav remains a bottom bar: ${JSON.stringify(box)}`)
  assert.ok(box.y + box.height >= viewport.height - 2, `compact nav is bottom anchored: ${JSON.stringify(box)}`)
}

async function assertCompactConversationCoexistence(page) {
  const nav = await assertOnePrimaryNav(page)
  const composer = page.locator("#message-form")
  const input = page.locator("#message-input")
  await composer.waitFor({state: "visible"})
  await input.focus()
  assert.equal(await input.evaluate(node => document.activeElement === node), true, "composer remains keyboard-focusable")

  const navBox = await nav.boundingBox()
  const composerBox = await composer.boundingBox()
  assert.ok(navBox && composerBox, "compact nav and composer both have geometry")
  assert.ok(
    composerBox.y + composerBox.height <= navBox.y + 1,
    `composer stays above compact primary nav: composer=${JSON.stringify(composerBox)} nav=${JSON.stringify(navBox)}`
  )
}

async function assertDesktopLeftRail(page, viewport) {
  const nav = await assertOnePrimaryNav(page)
  const box = await nav.boundingBox()
  assert.ok(box, "desktop primary nav has geometry")
  assert.ok(box.x <= 2, `desktop rail is left anchored: ${JSON.stringify(box)}`)
  assert.ok(box.width <= 240, `desktop rail stays rail-sized: ${JSON.stringify(box)}`)
  assert.ok(box.height > viewport.height * 0.5, `desktop rail is vertically persistent: ${JSON.stringify(box)}`)

  const buttonBoxes = await nav.locator("button").evaluateAll(buttons => buttons.map(button => {
    const rect = button.getBoundingClientRect()
    return {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
  }))
  assert.ok(buttonBoxes[3].y > buttonBoxes[0].y + buttonBoxes[0].height * 2, "desktop destinations stack vertically")
}

async function assertRouteDerivedCurrentDestination(page, label) {
  const nav = await assertOnePrimaryNav(page)
  const selected = nav.locator('button[aria-current="page"]')
  assert.equal(await selected.count(), 1)
  assert.equal((await selected.textContent()).trim(), label)

  const activeWeight = Number(await selected.evaluate(node => getComputedStyle(node).fontWeight))
  const inactiveWeight = Number(await nav.locator('button:not([aria-current="page"])').first().evaluate(node => getComputedStyle(node).fontWeight))
  assert.ok(activeWeight > inactiveWeight, `active destination is visually stronger (${activeWeight} > ${inactiveWeight})`)
}

test("F01 #74: one primary nav is bottom navigation below 992px and a left rail at 992px+", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contexts = []
  try {
    for (const viewport of [
      {width: 390, height: 844},
      {width: 991, height: 700},
      {width: 992, height: 700},
      {width: 1440, height: 900}
    ]) {
      const observed = await bootObserved(browser, viewport)
      contexts.push(observed.context)
      await activeScreen(observed.page, "doors").waitFor({state: "visible"})

      if (viewport.width < 992) await assertCompactBottomNav(observed.page, viewport)
      else await assertDesktopLeftRail(observed.page, viewport)

      await observed.page.locator('#bottom-nav [data-go="settings"]').click()
      await activeScreen(observed.page, "settings").waitFor({state: "visible"})
      assert.equal(new URL(observed.page.url()).pathname, "/you")
      await assertRouteDerivedCurrentDestination(observed.page, "You")
    }
  } finally {
    for (const context of contexts) await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F01 #64: active Conversation exposes ordinary nav and breakpoint crossing stays lifecycle-neutral", {timeout: 110_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    const compact = {width: 390, height: 844}
    const draft = "F-01 draft survives navigation and shell breakpoint crossing"
    pair = await matchPair(browser, compact)
    const page = pair.a.page
    const input = page.locator("#message-input")
    assert.equal(new URL(page.url()).pathname, "/conversation")

    const mark = pair.a.journal.mark()
    await assertCompactBottomNav(page, compact)
    await assertCompactConversationCoexistence(page)
    await input.fill(draft)
    assert.equal(await input.inputValue(), draft, "active Conversation draft is established before navigation and resize")

    await page.locator('#bottom-nav [data-go="settings"]').click()
    await activeScreen(page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])
    await assertRouteDerivedCurrentDestination(page, "You")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "conversation").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/conversation")
    assert.equal(await input.inputValue(), draft, "draft survives You -> Back -> Conversation")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])

    await page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "conversation").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/conversation")
    assert.equal(await input.inputValue(), draft, "draft survives You -> Back/Forward/Back -> Conversation")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])

    const resizeJoinCount = conversationJoinCount(pair.a, pair.conversationTopic)
    for (const viewport of [
      {width: 991, height: 700},
      {width: 992, height: 700},
      {width: 1440, height: 900},
      compact
    ]) {
      await page.setViewportSize(viewport)
      await page.waitForTimeout(50)
      assert.equal(new URL(page.url()).pathname, "/conversation")
      assert.equal(conversationJoinCount(pair.a, pair.conversationTopic), resizeJoinCount, "breakpoint crossing does not recreate ConversationChannel")
      assert.equal(await input.inputValue(), draft, `draft survives breakpoint crossing at ${viewport.width}px`)
      assert.deepEqual(destructiveFrames(pair.a, mark), [])
      if (viewport.width < 992) await assertCompactBottomNav(page, viewport)
      else await assertDesktopLeftRail(page, viewport)
    }

    await page.setViewportSize({width: 1024, height: 700})
    await assertDesktopLeftRail(page, {width: 1024, height: 700})
    assert.equal(await input.inputValue(), draft, "draft survives 1024px desktop shell")
    await page.locator('#bottom-nav [data-go="chats"]').click()
    await activeScreen(page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])
    await assertRouteDerivedCurrentDestination(page, "Chats")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "conversation").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/conversation")
    assert.equal(await input.inputValue(), draft, "draft survives Chats -> Back -> Conversation")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])

    await page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "conversation").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/conversation")
    assert.equal(await input.inputValue(), draft, "draft survives Chats -> Back/Forward/Back -> Conversation")
    assert.deepEqual(destructiveFrames(pair.a, mark), [])
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})