import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/team6-real-ux-screenshots")
const WAIT_MS = 15_000
let startupFailureSerial = 0

function sanitizedText(value) {
  return String(value || "").replace(/[A-Za-z0-9_+=/.-]{24,}/g, "[redacted]").slice(0, 240)
}

async function saveStartupFailure(observed, error) {
  const {page, startup} = observed
  const stem = `bootstrap-failure-${++startupFailureSerial}`
  let dom = {unavailable: true}
  try {
    dom = await page.evaluate(() => {
      const door = document.querySelector("button.door")
      const style = door ? getComputedStyle(door) : null
      return {
        documentReadyState: document.readyState,
        instagramChatBooted: document.documentElement.dataset.instagramChatBooted || null,
        flowBooting: document.body.classList.contains("flow-booting"),
        activeScreen: document.querySelector("section.screen.active")?.dataset.screen || null,
        bootBridgeState: document.querySelector("#boot-bridge")?.dataset.state || null,
        bootBridgeVisible: !!document.querySelector("#boot-bridge") && !document.querySelector("#boot-bridge").hidden,
        bootBridgeText: document.querySelector("#boot-bridge")?.innerText || "",
        statusText: document.querySelector("#status")?.innerText || "",
        doorsInDOM: document.querySelectorAll("button.door").length,
        firstDoorVisibility: style?.visibility || null,
        firstDoorDisplay: style?.display || null,
        firstDoorClientRects: door?.getClientRects().length || 0
      }
    })
  } catch (_ignored) { /* Even a crashed page must leave network evidence. */ }
  for (const field of ["bootBridgeText", "statusText"]) {
    if (dom[field]) dom[field] = sanitizedText(dom[field])
  }
  try { await page.screenshot({path: path.join(SCREENSHOTS, `${stem}.png`), fullPage: false, timeout: 5000}) } catch (_ignored) {}
  fs.writeFileSync(path.join(SCREENSHOTS, `${stem}.json`), JSON.stringify({
    requestedOrigin: new URL(BASE_URL).origin,
    failure: sanitizedText(error?.message),
    pageErrors: observed.pageErrors.length,
    consoleErrors: observed.consoleErrors.length,
    failedRequests: observed.failedRequests.map(request => ({path: new URL(request.url).pathname, reason: sanitizedText(request.reason)})),
    startup,
    dom
  }, null, 2))
}

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
  const startup = {responses: [], sockets: []}

  page.on("response", response => {
    const url = new URL(response.url())
    if (["/api/account/session", "/api/participants"].includes(url.pathname)) {
      startup.responses.push({path: url.pathname, status: response.status()})
    }
  })
  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  page.on("requestfailed", request => failedRequests.push({url: request.url(), reason: request.failure()?.errorText || "unknown"}))
  page.on("websocket", websocket => {
    startup.sockets.push({event: "created", path: new URL(websocket.url()).pathname})
    websocket.on("close", () => startup.sockets.push({event: "closed"}))
    websocket.on("socketerror", () => startup.sockets.push({event: "error"}))
    websocket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_sent", ...message})
    })
    websocket.on("framereceived", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_received", ...message})
    })
  })

  return {context, page, journal, pageErrors, consoleErrors, failedRequests, startup}
}

async function bootFresh(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const observed = await observePage(context, viewport)
  try {
    const response = await observed.page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    observed.startup.httpStatus = response?.status() || null
    assert.ok(response?.ok(), "root page loads")
    await observed.page.locator("button.door").first().waitFor({state: "visible", timeout: WAIT_MS})
    await observed.page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
    await observed.journal.waitFor(
      event => event.type === "frame_received" && event.topic?.startsWith("participant:") && event.event === "phx_reply" && event.body?.status === "ok" && event.body?.response?.status === "connected",
      "ParticipantChannel join"
    )
    observed.startup.participantJoin = "ok"
    return observed
  } catch (error) {
    await saveStartupFailure(observed, error)
    throw error
  }
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
  await sender.page.locator("#message-form").getByRole("button", {name: "Send message", exact: true}).click()
  await sender.journal.waitFor(
    event => event.type === "frame_sent" && event.topic === topic && event.event === "message:send" && event.body?.content === text,
    "real composer message send",
    mark
  )
  await receiver.page.locator("#messages li", {hasText: text}).waitFor({state: "visible", timeout: WAIT_MS})
  assert.equal(await receiver.page.locator("#messages li", {hasText: text}).count(), 1)
}

const PNG_1X1 = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2Qf8AAAAASUVORK5CYII=", "base64")

test("real Team 6 Arrival -> Door -> Queue -> Leave Queue", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let user
  try {
    user = await bootFresh(browser)
    await user.page.screenshot({path: path.join(SCREENSHOTS, "real-390x844-arrival.png"), fullPage: true})

    await selectLanguageAndQueue(user, "Advice")
    assert.equal((await user.page.locator("#leave-queue").innerText()).trim(), "Leave Queue")
    assert.match(await user.page.locator("#queue-lede").innerText(), /Advice/)
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
    assert.equal(await a.page.locator(".conversation-head-actions .overflow").evaluate(node => node.open), false, "safety dropdown must not cover the Report form")
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

/*
 * G3-003 regression: uses an actual two-participant matched Conversation.
 * It checks the visible warning and clicks its Cancel button at the physical
 * hit-test coordinates. This is NOT a 400%-zoom or screen-reader certification.
 */
test("Team 3B: Voice Privacy Cancel is reachable in a real compact Conversation", {timeout: 150_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    const page = pair.a.page
    for (const viewport of [
      {width: 320, height: 568},
      {width: 390, height: 844},
      {width: 844, height: 390}
    ]) {
      await page.setViewportSize(viewport)
      const isOpen = await page.locator("#message-form").evaluate(form => form.classList.contains("ig-tray-open"))
      if (!isOpen) await page.locator(".ig-compose-plus").click()
      await page.locator("#voice-warning-help").click()
      await page.locator("#voice-warning").waitFor({state: "visible", timeout: WAIT_MS})

      const geometry = await page.evaluate(() => {
        const sheet = document.querySelector("#voice-warning")
        const cancel = document.querySelector("#voice-warning-cancel")
        const rect = sheet.getBoundingClientRect()
        const button = cancel.getBoundingClientRect()
        const x = button.left + button.width / 2
        const y = button.top + button.height / 2
        const hit = document.elementFromPoint(x, y)
        const nav = document.querySelector("#bottom-nav")
        const navVisible = !!nav && getComputedStyle(nav).display !== "none" && nav.getClientRects().length > 0
        const navRect = navVisible ? nav.getBoundingClientRect() : null
        const navButton = navVisible ? [...nav.querySelectorAll("button")].find(button => {
          const style = getComputedStyle(button)
          return style.display !== "none" && style.visibility !== "hidden"
        }) : null
        const navButtonRect = navButton?.getBoundingClientRect()
        const navX = navButtonRect ? navButtonRect.left + navButtonRect.width / 2 : 0
        const navY = navButtonRect ? navButtonRect.top + navButtonRect.height / 2 : 0
        const navTarget = navButtonRect ? document.elementFromPoint(navX, navY) : null
        const navHit = !!navButton && (navTarget === navButton || navButton.contains(navTarget))
        const overlapsNav = !!navRect && rect.top < navRect.bottom && rect.bottom > navRect.top &&
          rect.left < navRect.right && rect.right > navRect.left
        return {
          navVisible,
          navHit,
          overlapsNav,
          top: rect.top,
          bottom: rect.bottom,
          left: rect.left,
          right: rect.right,
          viewportWidth: innerWidth,
          viewportHeight: innerHeight,
          cancelX: x,
          cancelY: y,
          cancelHit: hit === cancel || cancel.contains(hit)
        }
      })
      const label = `${viewport.width}x${viewport.height}`
      assert.ok(geometry.top >= -1, `${label}: Voice Privacy starts above viewport ${JSON.stringify(geometry)}`)
      assert.ok(geometry.bottom <= geometry.viewportHeight + 1, `${label}: Voice Privacy extends below viewport ${JSON.stringify(geometry)}`)
      assert.ok(geometry.left >= -1 && geometry.right <= geometry.viewportWidth + 1, `${label}: Voice Privacy overflows horizontally`)
      assert.ok(geometry.cancelHit, `${label}: Cancel cannot receive a pointer at its center ${JSON.stringify(geometry)}`)
      assert.ok(geometry.navVisible, `${label}: mobile primary navigation must remain visible`)
      assert.ok(!geometry.overlapsNav, `${label}: Voice Privacy overlaps primary navigation ${JSON.stringify(geometry)}`)
      assert.ok(geometry.navHit, `${label}: primary navigation control is pointer-blocked ${JSON.stringify(geometry)}`)
      await page.screenshot({path: path.join(SCREENSHOTS, `team3b-${label}-voice-privacy-before-cancel.png`), fullPage: false})
      await page.mouse.click(geometry.cancelX, geometry.cancelY)
      await page.locator("#voice-warning").waitFor({state: "hidden", timeout: WAIT_MS})
      await page.screenshot({path: path.join(SCREENSHOTS, `team3b-${label}-voice-privacy-after-cancel.png`), fullPage: false})
    }
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
