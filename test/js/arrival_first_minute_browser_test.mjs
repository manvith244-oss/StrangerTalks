import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/arrival-first-60-screenshots")
const VIEWPORTS = [
  {width: 320, height: 568},
  {width: 360, height: 740},
  {width: 390, height: 844},
  {width: 412, height: 915},
  {width: 844, height: 390},
  {width: 820, height: 1180},
  {width: 1440, height: 900}
]

async function openFresh(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  let participantId = null
  const errors = []
  const failedRequests = []
  const conversationJoins = []
  const socketEvents = {opened: 0, closed: 0, errors: 0}

  // Capture topic *identity only*, never payload, bearer token or chat text.
  page.on("websocket", socket => {
    socketEvents.opened += 1
    socket.on("close", () => { socketEvents.closed += 1 })
    socket.on("socketerror", () => { socketEvents.errors += 1 })
    socket.on("framesent", ({payload}) => {
      try {
        const frame = JSON.parse(payload)
        if (Array.isArray(frame) && frame[3] === "phx_join" &&
            typeof frame[2] === "string" && frame[2].startsWith("conversation:")) {
          conversationJoins.push(frame[2])
        }
      } catch (_ignored) {}
    })
  })
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text())
  })
  page.on("requestfailed", request => failedRequests.push(`${request.method()} ${request.url()} ${request.failure()?.errorText || "failed"}`))
  page.on("response", async response => {
    if (new URL(response.url()).pathname !== "/api/participants" || !response.ok()) return
    try {
      participantId = (await response.json()).participant_id || null
    } catch (_error) {}
  })

  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("button.door").first().waitFor({state: "visible"})

  return {
    context, page, errors, failedRequests,
    participantId: () => participantId,
    conversationTopic: () => conversationJoins.at(-1) || null,
    socketEvents
  }
}

async function waitForQueue(page) {
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 12_000})
  await page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 12_000})
}

async function leaveQueue(page) {
  await page.locator("#leave-queue").click()
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 12_000})
}

async function assertNoHorizontalOverflow(page, label) {
  const dimensions = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    scrollWidth: document.documentElement.scrollWidth,
    bodyScrollWidth: document.body.scrollWidth
  }))
  assert.ok(dimensions.scrollWidth <= dimensions.innerWidth + 1, `${label}: document does not overflow horizontally`)
  assert.ok(dimensions.bodyScrollWidth <= dimensions.innerWidth + 1, `${label}: body does not overflow horizontally`)
}

async function assertPrimaryControlReachable(page, selector, label) {
  const box = await page.locator(selector).boundingBox()
  assert.ok(box, `${label}: primary control is rendered`)
  const viewport = page.viewportSize()
  assert.ok(box.x >= -1 && box.x + box.width <= viewport.width + 1, `${label}: primary control fits horizontally`)
  assert.ok(box.y >= -1 && box.y < viewport.height, `${label}: primary control begins inside viewport`)
}

test("first visit is self-explanatory and a Door tap enters queue without language", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let fresh
  try {
    fresh = await openFresh(browser)
    const {page} = fresh

    await page.getByText("Anonymous, one-to-one conversation with another person. No profile required.").waitFor({state: "visible"})
    assert.equal(await page.locator("button.door").count(), 4)
    assert.equal(await page.locator("#conversation-language").count(), 0)
    await page.getByRole("button", {name: /Advice/}).click()
    await waitForQueue(page)
    await page.waitForFunction(() => document.activeElement === document.querySelector('section[data-screen="queue"] h1'))
    await assertNoHorizontalOverflow(page, "390x844 queue")

    await leaveQueue(page)
    await page.waitForFunction(() => document.activeElement === document.querySelector('section[data-screen="doors"] h1'))
    assert.deepEqual(fresh.errors, [])
    assert.deepEqual(fresh.failedRequests, [])
  } finally {
    await fresh?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("participant bootstrap failure becomes a visible recoverable state", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    await context.route("**/api/participants", async route => {
      await route.fulfill({status: 503, contentType: "application/json", body: JSON.stringify({error: "intentional_test_failure"})})
    })
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root shell still loads")

    // The authoritative boot bridge supersedes the older Arrival panel:
    // failed authority must keep all Doors hidden until the Retry succeeds.
    const panel = page.locator('#boot-bridge[data-state="error"]')
    await panel.waitFor({state: "visible", timeout: 12_000})
    await panel.getByRole("heading", {name: "StrangerTalks can’t confirm your session."}).waitFor({state: "visible"})
    const retry = panel.getByRole("button", {name: "Reload StrangerTalks"})
    await retry.waitFor({state: "visible"})
    assert.equal(await page.locator("button.door:visible").count(), 0, "Doors remain hidden without session authority")
    assert.equal(await page.evaluate(() => document.activeElement?.textContent), "Reload StrangerTalks")
    await context.unroute("**/api/participants")
    await retry.click()
    await page.locator('section[data-screen="doors"].active button.door').first().waitFor({state: "visible", timeout: 15_000})
    assert.equal(await page.locator("#boot-bridge").isVisible(), false, "successful recovery hides boot bridge")
    assert.equal(await page.locator("body.flow-booting").count(), 0)
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("required device matrix can enter and leave matchmaking without squeezed or unreachable UI", {timeout: 150_000}, async () => {
  fs.mkdirSync(SCREENSHOTS, {recursive: true})
  const browser = await chromium.launch({headless: true})

  try {
    for (const viewport of VIEWPORTS) {
      const label = `${viewport.width}x${viewport.height}`
      const fresh = await openFresh(browser, viewport)
      try {
        const {page} = fresh
        await assertNoHorizontalOverflow(page, `${label} arrival`)
        const primaryDoor = page.getByRole("button", {name: /Distract/})
        await primaryDoor.scrollIntoViewIfNeeded()
        await assertPrimaryControlReachable(page, 'button[data-door="KEEP_IT_LIGHT"]', `${label} arrival`)
        await primaryDoor.click()
        await waitForQueue(page)
        await assertNoHorizontalOverflow(page, `${label} queue`)
        await assertPrimaryControlReachable(page, "#leave-queue", `${label} queue`)
        await page.screenshot({path: path.join(SCREENSHOTS, `${label}-queue.png`), fullPage: true})
        await leaveQueue(page)
        assert.deepEqual(fresh.errors, [], `${label}: no browser/console errors`)
        assert.deepEqual(fresh.failedRequests, [], `${label}: no failed requests`)
      } finally {
        await fresh.context.close().catch(() => {})
      }
    }
  } finally {
    await browser.close().catch(() => {})
  }
})

test("two isolated fresh participants reach one usable Conversation and can talk", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b

  try {
    a = await openFresh(browser, {width: 390, height: 844})
    b = await openFresh(browser, {width: 390, height: 844})

    await a.page.getByRole("button", {name: /Deep Talk/}).click()
    await waitForQueue(a.page)
    await b.page.getByRole("button", {name: /Deep Talk/}).click()

    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 20_000}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 20_000})
    ])

    // A visible Conversation shell is not proof that two fresh participants
    // actually joined the same authoritative ConversationChannel. Guard against
    // an orphaned synthetic participant from an earlier fixture.
    for (const participant of [a, b]) {
      const deadline = Date.now() + 15_000
      while (!participant.conversationTopic() && Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 25))
      }
      assert.ok(participant.conversationTopic(), "participant must join a real ConversationChannel")
    }
    assert.equal(a.conversationTopic(), b.conversationTopic(), "both new participants must share one authoritative Conversation")

    const text = `Team 1 handoff ${Date.now()}`
    const inputA = a.page.locator("#message-input")
    const inputB = b.page.locator("#message-input")
    assert.equal(await inputA.isVisible(), true)
    assert.equal(await inputA.isEnabled(), true)
    assert.equal(await inputB.isVisible(), true)
    assert.equal(await inputB.isEnabled(), true)

    await inputA.fill(text)
    const send = a.page.locator("#message-form").getByRole("button", {name: "Send message", exact: true})
    try {
      await send.click({timeout: 12_000})
    } catch (error) {
      const dom = await a.page.evaluate(() => {
        const send = document.querySelector("#message-form button.primary")
        const style = send ? getComputedStyle(send) : null
        const rect = send?.getBoundingClientRect()
        return {
          screen: document.querySelector("section.screen.active")?.dataset.screen || null,
          chatMode: document.body.classList.contains("st-chat-mode"),
          booting: document.body.classList.contains("flow-booting"),
          sendHidden: !rect || !rect.width || !rect.height,
          sendDisplay: style?.display || null,
          sendVisibility: style?.visibility || null,
          sendDisabled: Boolean(send?.disabled),
          reportVisible: Boolean(document.querySelector("#report-form")?.getClientRects().length),
          endVisible: Boolean(document.querySelector('[data-screen="ended"].active')),
          presenceStatus: document.querySelector("#presence")?.textContent?.trim().slice(0, 90) || null
        }
      }).catch(() => ({unavailable: true}))
      console.error("TEAM3E_SEND_STABILITY=" + JSON.stringify({
        error: error.name,
        aSocket: a.socketEvents,
        bSocket: b.socketEvents,
        aHasConversationTopic: Boolean(a.conversationTopic()),
        bHasConversationTopic: Boolean(b.conversationTopic()),
        sameConversation: a.conversationTopic() === b.conversationTopic(),
        dom
      }))
      throw error
    }
    await b.page.locator("#messages").getByText(text, {exact: true}).waitFor({state: "visible", timeout: 12_000})

    for (const participant of [a, b]) {
      const participantId = participant.participantId()
      if (participantId) {
        assert.equal((await participant.page.locator("body").innerText()).includes(participantId), false, "participant UUID is not exposed in UI")
      }
      await assertNoHorizontalOverflow(participant.page, "usable Conversation handoff")
      assert.deepEqual(participant.errors, [])
      assert.deepEqual(participant.failedRequests, [])
    }
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("arrival screen focus does not steal focus from active Conversation content", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b

  try {
    a = await openFresh(browser, {width: 1280, height: 800})
    b = await openFresh(browser, {width: 1280, height: 800})

    await a.page.getByRole("button", {name: /Advice/}).click()
    await waitForQueue(a.page)
    await b.page.getByRole("button", {name: /Advice/}).click()

    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 20_000}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 20_000})
    ])

    const target = a.page.locator('section[data-screen="conversation"] #message-input')
    await target.focus()
    const focusSnapshot = async () => a.page.evaluate(() => ({
      activeId: document.activeElement?.id || "",
      activeTag: document.activeElement?.tagName || "",
      screen: document.querySelector("section.screen.active")?.dataset.screen || "",
      inputVisible: Boolean(document.querySelector("#message-input")?.getClientRects().length),
      inputDisabled: Boolean(document.querySelector("#message-input")?.disabled)
    }))
    const beforeProbe = await focusSnapshot()
    assert.equal(beforeProbe.activeId, "message-input", "Composer must accept focus before cosmetic class probe: " + JSON.stringify(beforeProbe))

    await a.page.locator('section[data-screen="conversation"]').evaluate((screen) => {
      screen.classList.toggle("arrival-focus-regression-probe")
    })
    await a.page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))))

    const afterProbe = await focusSnapshot()
    assert.equal(afterProbe.activeId, "message-input", "Cosmetic class change must preserve composer focus: " + JSON.stringify({beforeProbe, afterProbe}))
    assert.deepEqual(a.errors, [])
    assert.deepEqual(a.failedRequests, [])
    assert.deepEqual(b.errors, [])
    assert.deepEqual(b.failedRequests, [])
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
