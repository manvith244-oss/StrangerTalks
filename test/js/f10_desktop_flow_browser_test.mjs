import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/f10-desktop-flow-screenshots")
const WAIT_MS = 15_000

const VIEWPORTS = Object.freeze({
  compact: {width: 1024, height: 720},
  standard: {width: 1440, height: 900},
  large: {width: 1920, height: 1080},
  ultrawide: {width: 2560, height: 1080}
})

fs.mkdirSync(SCREENSHOTS, {recursive: true})

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
  }

  add(event) {
    this.events.push(event)
  }

  mark() {
    return this.events.length
  }

  async waitFor(predicate, label, from = 0) {
    const deadline = Date.now() + WAIT_MS
    while (Date.now() < deadline) {
      const found = this.events.slice(from).find(predicate)
      if (found) return found
      await new Promise(resolve => setTimeout(resolve, 25))
    }
    throw new Error(`Timed out waiting for ${label}`)
  }
}

async function observePage(context, viewport = VIEWPORTS.standard) {
  const page = await context.newPage()
  await page.setViewportSize(viewport)
  const journal = new Journal()
  const pageErrors = []
  const consoleErrors = []
  const failedRequests = []

  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  page.on("requestfailed", request => failedRequests.push({url: request.url(), reason: request.failure()?.errorText || "unknown"}))
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

  return {context, page, journal, pageErrors, consoleErrors, failedRequests}
}

async function bootFresh(browser, viewport = VIEWPORTS.standard) {
  const context = await browser.newContext({viewport})
  const observed = await observePage(context, viewport)
  const response = await observed.page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await observed.page.locator("button.door").first().waitFor({state: "visible", timeout: WAIT_MS})
  await observed.page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await observed.journal.waitFor(
    event => event.type === "frame_received" && event.topic?.startsWith("participant:") && event.event === "phx_reply" && event.body?.status === "ok" && event.body?.response?.status === "connected",
    "ParticipantChannel join"
  )
  return observed
}

async function assertNoOverflow(page, label) {
  const metrics = await page.evaluate(() => ({
    viewport: innerWidth,
    html: document.documentElement.scrollWidth,
    body: document.body.scrollWidth
  }))
  assert.ok(metrics.html <= metrics.viewport + 1, `${label}: html horizontal overflow ${metrics.html - metrics.viewport}px`)
  assert.ok(metrics.body <= metrics.viewport + 1, `${label}: body horizontal overflow ${metrics.body - metrics.viewport}px`)
}

function assertClean(observed) {
  assert.deepEqual(observed.pageErrors, [], "no page errors")
  assert.deepEqual(observed.consoleErrors, [], "no console errors")
  assert.deepEqual(observed.failedRequests, [], "no failed requests")
}

async function selectLanguageAndQueue(observed, door = "Advice") {
  await observed.page.locator("#conversation-language").selectOption("en")
  await observed.page.getByRole("button", {name: new RegExp(door)}).click()
  await observed.page.locator('[data-screen="queue"].active').waitFor({state: "visible", timeout: WAIT_MS})
  await observed.page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: WAIT_MS})
}

async function waitForConversation(observed, from = 0) {
  await observed.page.locator('[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
  const joined = await observed.journal.waitFor(
    event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
    "ConversationChannel join",
    from
  )
  await observed.page.locator("#message-input").waitFor({state: "visible", timeout: WAIT_MS})
  return joined.topic
}

async function matchPair(browser) {
  const a = await bootFresh(browser, VIEWPORTS.compact)
  const b = await bootFresh(browser, VIEWPORTS.compact)
  await selectLanguageAndQueue(a)
  await b.page.locator("#conversation-language").selectOption("en")
  const markA = a.journal.mark()
  const markB = b.journal.mark()
  await b.page.getByRole("button", {name: /Advice/}).click()
  const [topicA, topicB] = await Promise.all([waitForConversation(a, markA), waitForConversation(b, markB)])
  assert.equal(topicA, topicB, "both participants enter the same Conversation")
  return {a, b, topic: topicA}
}

function sentCount(observed, topic, event) {
  return observed.journal.events.filter(item => item.type === "frame_sent" && item.topic === topic && item.event === event).length
}

async function resizeThrough(page, entries, labelPrefix) {
  for (const [label, viewport] of entries) {
    await page.setViewportSize(viewport)
    await page.waitForTimeout(75)
    await assertNoOverflow(page, `${labelPrefix} ${label}`)
    await page.screenshot({path: path.join(SCREENSHOTS, `${labelPrefix}-${label}.png`), fullPage: false})
  }
}

test("F-10 queue resize preserves one queue attempt and desktop layout continuity", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let user
  try {
    user = await bootFresh(browser, VIEWPORTS.compact)
    await selectLanguageAndQueue(user)

    const participantTopic = user.journal.events.find(item => item.type === "frame_sent" && item.topic?.startsWith("participant:") && item.event === "queue:join")?.topic
    assert.ok(participantTopic, "queue join is observable on the participant channel")
    assert.equal(sentCount(user, participantTopic, "queue:join"), 1, "exactly one queue attempt before resize")

    await resizeThrough(user.page, Object.entries(VIEWPORTS), "queue")

    assert.equal(await user.page.locator('[data-screen="queue"]').getAttribute("class").then(value => value.includes("active")), true, "queue screen remains active")
    assert.equal(sentCount(user, participantTopic, "queue:join"), 1, "resize does not submit another queue attempt")
    assert.equal(await user.page.locator("#conversation-language").inputValue(), "en", "selected language survives resize")
    assertClean(user)
  } finally {
    await user?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F-10 Conversation resize preserves runtime, unsent draft and readable width", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a, b, topic} = pair
    const joinsBefore = sentCount(a, topic, "phx_join")
    assert.equal(joinsBefore, 1, "one Conversation join before resize")

    const draft = "Unsent desktop resize draft — preserve me"
    await a.page.locator("#message-input").fill(draft)

    await b.page.locator("#message-input").fill("Desktop width proof")
    await b.page.locator("#message-form button.primary").click()
    await a.page.locator("#messages li", {hasText: "Desktop width proof"}).waitFor({state: "visible", timeout: WAIT_MS})

    await resizeThrough(a.page, Object.entries(VIEWPORTS), "conversation")

    assert.equal(sentCount(a, topic, "phx_join"), joinsBefore, "resize does not create another Conversation subscription")
    assert.equal(await a.page.locator("#message-input").inputValue(), draft, "unsent composer draft survives resize")
    assert.equal(await a.page.locator('[data-screen="conversation"]').evaluate(node => node.classList.contains("active")), true, "same Conversation surface remains active")

    const layout = await a.page.evaluate(() => {
      const bubble = document.querySelector("#messages .message")
      const composer = document.querySelector("#message-form")
      const screen = document.querySelector('[data-screen="conversation"].active')
      const rect = element => element?.getBoundingClientRect()
      return {bubble: rect(bubble), composer: rect(composer), screen: rect(screen), viewport: innerWidth}
    })
    assert.ok(layout.screen.width <= 48 * 16 + 2, `Conversation stays constrained instead of stretching across ${layout.viewport}px`)
    assert.ok(layout.bubble.width <= 36 * 16 + 2, "message bubble stays within readable max width")
    assert.ok(layout.composer.left >= layout.screen.left - 1 && layout.composer.right <= layout.screen.right + 1, "composer remains anchored to Conversation region")
    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F-10 desktop report surface is a keyboard-contained modal and Escape restores focus", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a} = pair
    await a.page.setViewportSize(VIEWPORTS.standard)

    await a.page.locator(".conversation-head-actions .overflow summary").click()
    await a.page.locator("#report-open").click()
    const report = a.page.locator("#report-form")
    await report.waitFor({state: "visible", timeout: WAIT_MS})

    assert.equal(await report.getAttribute("role"), "dialog", "report surface exposes dialog semantics")
    assert.equal(await report.getAttribute("aria-modal"), "true", "report surface is modal to assistive technology")
    assert.equal(await report.getAttribute("aria-labelledby"), "report-title", "report dialog has a stable accessible name")
    assert.equal(await a.page.locator("#report-title").evaluate(node => node === document.activeElement), true, "focus enters report dialog")

    const focusable = report.locator('button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')
    const focusableCount = await focusable.count()
    assert.ok(focusableCount >= 2, "report dialog has multiple keyboard controls")
    await focusable.nth(focusableCount - 1).focus()
    await a.page.keyboard.press("Tab")
    const focusStayedInside = await a.page.evaluate(() => document.querySelector("#report-form")?.contains(document.activeElement))
    assert.equal(focusStayedInside, true, "Tab cannot escape the open report dialog")

    await a.page.keyboard.press("Escape")
    await report.waitFor({state: "hidden", timeout: WAIT_MS})
    assert.equal(await a.page.locator("#report-open").evaluate(node => node === document.activeElement), true, "Escape closes report and restores trigger focus")
    assertClean(a)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
