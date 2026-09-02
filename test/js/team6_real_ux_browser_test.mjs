import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/team6-real-ux-screenshots")
const WAIT_MS = 15_000

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

async function observePage(context, viewport = {width: 390, height: 844}) {
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

async function bootFresh(browser, viewport = {width: 390, height: 844}) {
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
  await observed.page.locator(".ig-compose-plus").waitFor({state: "visible", timeout: WAIT_MS})
  return joined.topic
}

async function matchPair(browser, door = "Advice") {
  const a = await bootFresh(browser)
  const b = await bootFresh(browser)
  await selectLanguageAndQueue(a, door)
  await b.page.locator("#conversation-language").selectOption("en")
  const markA = a.journal.mark()
  const markB = b.journal.mark()
  await b.page.getByRole("button", {name: new RegExp(door)}).click()
  const [topicA, topicB] = await Promise.all([waitForConversation(a, markA), waitForConversation(b, markB)])
  assert.equal(topicA, topicB, "both real participants enter the same Conversation")
  return {a, b, topic: topicA}
}

async function sendAndReceive(sender, receiver, topic, text) {
  const mark = sender.journal.mark()
  await sender.page.locator("#message-input").fill(text)
  await sender.page.locator("#message-form button.primary").click()
  await sender.journal.waitFor(
    event => event.type === "frame_sent" && event.topic === topic && event.event === "message:send" && event.body?.content === text,
    "real composer message send",
    mark
  )
  await receiver.page.locator("#messages li", {hasText: text}).waitFor({state: "visible", timeout: WAIT_MS})
  assert.equal(await receiver.page.locator("#messages li", {hasText: text}).count(), 1)
}

const PNG_1X1 = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2Qf8AAAAASUVORK5CYII=", "base64")

test("real Team 6 Arrival -> language -> Door -> Queue -> Leave Queue", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let user
  try {
    user = await bootFresh(browser)
    await user.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-arrival.png"), fullPage: true})

    await user.page.getByRole("button", {name: /Advice/}).click()
    await user.page.getByText("Choose a Conversation Language before picking a Door.").waitFor({state: "visible"})
    assert.equal(await user.page.locator("#conversation-language").getAttribute("aria-invalid"), "true")

    await selectLanguageAndQueue(user, "Advice")
    assert.equal((await user.page.locator("#leave-queue").innerText()).trim(), "Leave Queue")
    assert.match(await user.page.locator("#queue-lede").innerText(), /English/)
    await assertNoOverflow(user.page, "real Queue")
    await user.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-queue.png"), fullPage: true})

    await user.page.locator("#leave-queue").click()
    await user.page.locator('[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT_MS})
    await user.page.getByRole("status").filter({hasText: "Queue status: left"}).waitFor({state: "visible", timeout: WAIT_MS})
    assertClean(user)
  } finally {
    await user?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real Team 6 matched Conversation reaches composer, tools, expressions, ephemeral preview and Report", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    const {a, b, topic} = pair

    await sendAndReceive(a, b, topic, "Team 6 real browser hello")
    await sendAndReceive(b, a, topic, "Team 6 peer reply")
    await assertNoOverflow(a.page, "real Conversation")
    await a.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-conversation.png"), fullPage: false})

    await a.page.locator(".ig-compose-plus").click()
    await a.page.locator("#ig-message-tools").waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(await a.page.locator(".ig-compose-plus").getAttribute("aria-expanded"), "true")
    await assertNoOverflow(a.page, "real tools tray")
    await a.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-tools.png"), fullPage: false})

    const expressive = a.page.locator("#expressive-open")
    await expressive.waitFor({state: "visible", timeout: WAIT_MS})
    await expressive.click()
    await a.page.locator("#expressive-picker").waitFor({state: "visible", timeout: WAIT_MS})
    assert.doesNotMatch((await expressive.innerText()).trim(), /GIF/i)
    await a.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-expressions.png"), fullPage: false})
    await a.page.locator("#expressive-search").fill("bright")
    await a.page.getByRole("option", {name: "A bright spark"}).click()
    await b.page.getByRole("img", {name: "A bright spark"}).waitFor({state: "visible", timeout: WAIT_MS})

    const chooser = a.page.waitForEvent("filechooser")
    await a.page.locator("#view-once-picker-btn").click()
    const fileChooser = await chooser
    await fileChooser.setFiles({name: "team6-preview.png", mimeType: "image/png", buffer: PNG_1X1})
    await a.page.locator("#view-once-preview").waitFor({state: "visible", timeout: WAIT_MS})
    await a.page.getByText("View Once can be opened one time. View Twice can be opened up to two times.").waitFor({state: "visible"})
    assert.equal(await a.page.locator("#view-once-send").isVisible(), true)
    assert.equal(await a.page.locator("#view-twice-send").isVisible(), true)
    await assertNoOverflow(a.page, "real View Once/View Twice preview")
    await a.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-view-once-twice-preview.png"), fullPage: false})
    await a.page.locator("#view-once-preview-cancel").click()
    await a.page.locator("#view-once-preview").waitFor({state: "hidden", timeout: WAIT_MS})

    const overflow = a.page.locator(".conversation-head-actions .overflow summary")
    await overflow.click()
    await a.page.locator("#report-open").click()
    await a.page.locator("#report-form").waitFor({state: "visible", timeout: WAIT_MS})
    const reportLabels = (await a.page.locator("#report-category option").allTextContents()).map(text => text.trim())
    assert.deepEqual(reportLabels, ["Choose…", "Spam", "Harassment", "Sexual misconduct", "Malicious links", "Threats"])
    await assertNoOverflow(a.page, "real Report")
    await a.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-report.png"), fullPage: false})
    await a.page.locator("#report-cancel").click()
    await a.page.locator("#report-form").waitFor({state: "hidden", timeout: WAIT_MS})
    assert.equal(await a.page.locator("#report-open").evaluate(node => node === document.activeElement), true)

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
