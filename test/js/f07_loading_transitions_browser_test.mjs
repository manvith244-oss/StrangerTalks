import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

async function freshPage(browser, {recordQueueFrames = false} = {}) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})

  if (recordQueueFrames) {
    await context.addInitScript(() => {
      const NativeWebSocket = window.WebSocket
      window.__f07Sockets = []
      window.__f07QueuedFrame = null

      class F07RecordingWebSocket extends NativeWebSocket {
        constructor(...args) {
          super(...args)
          window.__f07Sockets.push(this)
          this.addEventListener("message", event => {
            if (typeof event.data !== "string") return
            if (!event.data.includes('"queue:status"') || !event.data.includes('"queued"')) return
            if (!window.__f07QueuedFrame) window.__f07QueuedFrame = event.data
          })
        }
      }

      window.WebSocket = F07RecordingWebSocket
    })
  }

  const page = await context.newPage()
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text())
  })

  return {context, page, errors}
}

async function waitForReadyDoors(page) {
  await page.locator('body:not(.flow-booting)').waitFor({state: "attached", timeout: 15_000})
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
}

async function startQueueTransitionRecording(page) {
  await page.evaluate(() => {
    window.__f07QueueTransitions = []
    const title = document.querySelector("#queue-title")
    const leave = document.querySelector("#leave-queue")
    const record = () => {
      window.__f07QueueTransitions.push({
        title: title?.textContent || "",
        disabled: Boolean(leave?.disabled)
      })
    }
    new MutationObserver(record).observe(title, {childList: true, characterData: true, subtree: true})
    new MutationObserver(record).observe(leave, {attributes: true, attributeFilter: ["disabled"]})
    record()
  })
}

test("cold boot bridge stays authoritative while participant bootstrap is unresolved", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  await context.route("**/api/participants", async route => {
    await new Promise(resolve => setTimeout(resolve, 750))
    await route.continue()
  })
  const page = await context.newPage()

  try {
    const navigation = page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    await page.locator("#boot-bridge").waitFor({state: "visible", timeout: 10_000})
    assert.equal(await page.locator("body").evaluate(body => body.classList.contains("flow-booting")), true)
    assert.equal(await page.locator('section[data-screen="doors"]').isVisible(), false)
    assert.equal(await page.locator("#bottom-nav").isVisible(), false)

    const response = await navigation
    assert.ok(response?.ok(), "root shell loads")
    await page.locator('body:not(.flow-booting)').waitFor({state: "attached", timeout: 15_000})
    await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("matchmaking entry and cancellation expose truthful intermediate states", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const fresh = await freshPage(browser)

  try {
    const {page} = fresh
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root shell loads")
    await waitForReadyDoors(page)
    await startQueueTransitionRecording(page)

    await page.getByRole("button", {name: /Deep Talk/}).click()
    await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 12_000})
    await page.locator("#queue-title").filter({hasText: "Finding someone…"}).waitFor({state: "visible", timeout: 12_000})
    assert.equal(await page.locator("#leave-queue").isEnabled(), true)

    await page.locator("#leave-queue").click()
    await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 12_000})

    const transitions = await page.evaluate(() => window.__f07QueueTransitions)
    assert.equal(
      transitions.some(state => state.title === "Starting matchmaking…" && state.disabled),
      true,
      "admission is visibly blocked before canonical waiting"
    )
    assert.equal(
      transitions.some(state => state.title === "Finding someone…" && !state.disabled),
      true,
      "canonical waiting enables Leave Queue"
    )
    assert.equal(
      transitions.some(state => state.title === "Leaving queue…" && state.disabled),
      true,
      "cancellation is visibly blocked while canonical leave is unresolved"
    )
    assert.deepEqual(fresh.errors, [])
  } finally {
    await fresh.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("late queued event from a retired attempt cannot resurrect matchmaking", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const fresh = await freshPage(browser, {recordQueueFrames: true})

  try {
    const {page} = fresh
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root shell loads")
    await waitForReadyDoors(page)

    await page.getByRole("button", {name: /Deep Talk/}).click()
    await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 12_000})
    await page.locator("#queue-title").filter({hasText: "Finding someone…"}).waitFor({state: "visible", timeout: 12_000})
    await page.waitForFunction(() => Boolean(window.__f07QueuedFrame), null, {timeout: 12_000})

    await page.locator("#leave-queue").click()
    await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 12_000})

    const replayed = await page.evaluate(() => {
      const socket = window.__f07Sockets.find(candidate => candidate.readyState === WebSocket.OPEN)
      if (!socket || !window.__f07QueuedFrame) return false
      socket.dispatchEvent(new MessageEvent("message", {data: window.__f07QueuedFrame}))
      return true
    })
    assert.equal(replayed, true, "captured canonical queued frame is replayed as a late stale event")

    await page.waitForTimeout(250)
    assert.equal(await page.locator('section[data-screen="doors"].active').isVisible(), true)
    assert.equal(await page.locator('section[data-screen="queue"].active').count(), 0)
    assert.deepEqual(fresh.errors, [])
  } finally {
    await fresh.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
