import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

function phoenixFrame(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_error) {
    return null
  }
}

async function freshPage(browser, {wrapWebSocket = false} = {}) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})

  if (wrapWebSocket) {
    await context.addInitScript(() => {
      const NativeWebSocket = window.WebSocket
      const nativeSend = NativeWebSocket.prototype.send
      class PassthroughWebSocket extends NativeWebSocket {
        send(data) { return nativeSend.call(this, data) }
      }
      window.WebSocket = PassthroughWebSocket
    })
  }

  const page = await context.newPage()
  const frames = []
  page.on("websocket", socket => {
    socket.on("framesent", ({payload}) => {
      const frame = phoenixFrame(payload)
      if (frame) frames.push({direction: "sent", ...frame})
    })
    socket.on("framereceived", ({payload}) => {
      const frame = phoenixFrame(payload)
      if (frame) frames.push({direction: "received", ...frame})
    })
  })

  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('body:not(.flow-booting)').waitFor({state: "attached", timeout: 15_000})
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page, frames}
}

function compactFrame(frame) {
  return {
    direction: frame.direction,
    topic: frame.topic,
    event: frame.event,
    status: frame.body?.status,
    responseStatus: frame.body?.response?.status,
    code: frame.body?.response?.code,
    reason: frame.body?.response?.reason,
    attempt: frame.body?.queue_attempt_id || frame.body?.response?.queue_attempt_id || null
  }
}

async function snapshot(client) {
  return {
    activeScreen: await client.page.locator("section[data-screen].active").getAttribute("data-screen").catch(() => null),
    queueTitle: await client.page.locator("#queue-title").textContent().catch(() => null),
    queueStatus: await client.page.locator("#queue-phase-status").textContent().catch(() => null),
    liveStatus: await client.page.locator("#status").textContent().catch(() => null),
    queueFrames: client.frames.filter(frame => ["queue:join", "queue:status", "match_found"].includes(frame.event)).map(compactFrame),
    conversationFrames: client.frames.filter(frame => frame.topic?.startsWith("conversation:")).map(compactFrame)
  }
}

async function waitConversation(client, timeout = 5_000) {
  try {
    await client.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout})
    return true
  } catch (_error) {
    return false
  }
}

async function runPair(browser, {simultaneous, wrapA = false}) {
  const a = await freshPage(browser, {wrapWebSocket: wrapA})
  const b = await freshPage(browser)
  try {
    if (simultaneous) {
      await Promise.all([
        a.page.getByRole("button", {name: /Deep Talk/}).click(),
        b.page.getByRole("button", {name: /Deep Talk/}).click()
      ])
    } else {
      await a.page.getByRole("button", {name: /Deep Talk/}).click()
      await a.page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 10_000})
      await b.page.getByRole("button", {name: /Deep Talk/}).click()
    }

    const [aMatched, bMatched] = await Promise.all([waitConversation(a), waitConversation(b)])
    return {
      matched: aMatched && bMatched,
      a: await snapshot(a),
      b: await snapshot(b)
    }
  } finally {
    await a.context.close().catch(() => {})
    await b.context.close().catch(() => {})
  }
}

test("base pairing diagnostics", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  try {
    const sequential = await runPair(browser, {simultaneous: false})
    console.log("STEP1_BASE_SEQUENTIAL=" + JSON.stringify(sequential))

    const wrappedSequential = await runPair(browser, {simultaneous: false, wrapA: true})
    console.log("STEP1_BASE_WRAPPED_SEQUENTIAL=" + JSON.stringify(wrappedSequential))

    const simultaneousRuns = []
    for (let i = 0; i < 3; i += 1) {
      simultaneousRuns.push(await runPair(browser, {simultaneous: true, wrapA: true}))
    }
    console.log("STEP1_BASE_SIMULTANEOUS=" + JSON.stringify(simultaneousRuns))

    assert.ok(true, "diagnostic completed")
  } finally {
    await browser.close().catch(() => {})
  }
})
