import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const BOUNDARY_TIMEOUT_MS = 15_000

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_error) {
    return null
  }
}

function observeFrames(page, label) {
  const events = []
  const waiters = new Set()

  function add(event) {
    events.push(event)
    for (const waiter of [...waiters]) {
      if (!waiter.predicate(event)) continue
      clearTimeout(waiter.timer)
      waiters.delete(waiter)
      waiter.resolve(event)
    }
  }

  page.on("websocket", (socket) => {
    socket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) add({direction: "sent", ...message})
    })
    socket.on("framereceived", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) add({direction: "received", ...message})
    })
  })

  function recent() {
    return events.slice(-20).map(({direction, topic, event, body}) => ({
      direction,
      topic,
      event,
      status: body?.status,
      responseStatus: body?.response?.status,
      code: body?.response?.code,
      reason: body?.response?.reason
    }))
  }

  function waitFor(predicate, description) {
    const existing = events.find(predicate)
    if (existing) return Promise.resolve(existing)
    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, timer: null}
      waiter.timer = setTimeout(() => {
        waiters.delete(waiter)
        reject(new Error(`${label} timed out waiting for ${description}; recent frames: ${JSON.stringify(recent())}`))
      }, BOUNDARY_TIMEOUT_MS)
      waiters.add(waiter)
    })
  }

  return {events, recent, waitFor}
}

async function freshPage(browser, label) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  const frames = observeFrames(page, label)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('body:not(.flow-booting)').waitFor({state: "attached", timeout: 15_000})
  await frames.waitFor(
    event => event.direction === "received" && event.topic?.startsWith("participant:") &&
      event.event === "phx_reply" && event.body?.status === "ok" && event.body?.response?.status === "connected",
    "successful ParticipantChannel join"
  )
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page, frames}
}

async function waitForConversationBoundary(client, label) {
  const match = await client.frames.waitFor(
    event => event.direction === "received" && event.event === "match_found" && event.body?.conversation_id,
    "match_found"
  )
  const conversationId = match.body.conversation_id
  const topic = `conversation:${conversationId}`

  const join = await client.frames.waitFor(
    event => event.direction === "sent" && event.topic === topic && event.event === "phx_join",
    `ConversationChannel phx_join for ${conversationId}`
  )
  const reply = await client.frames.waitFor(
    event => event.direction === "received" && event.topic === topic && event.event === "phx_reply" &&
      (event.ref === join.ref || event.joinRef === join.ref || event.joinRef === join.joinRef),
    `ConversationChannel join reply for ${conversationId}`
  )
  assert.equal(
    reply.body?.status,
    "ok",
    `${label} ConversationChannel join rejected: ${JSON.stringify(reply.body)}; recent frames: ${JSON.stringify(client.frames.recent())}`
  )

  const input = client.page.locator('section[data-screen="conversation"].active #message-input')
  await input.waitFor({state: "visible", timeout: 15_000})
  await client.page.waitForTimeout(300)
  assert.equal(await input.isVisible(), true, `${label} conversation transition remains stable`)
  return conversationId
}

async function matchPair(browser) {
  const a = await freshPage(browser, "A")
  const b = await freshPage(browser, "B")

  try {
    await a.page.getByRole("button", {name: /Deep Talk/}).click()
    await a.page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 10_000})
    await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
    await b.page.getByRole("button", {name: /Deep Talk/}).click()

    const [conversationA, conversationB] = await Promise.all([
      waitForConversationBoundary(a, "A"),
      waitForConversationBoundary(b, "B")
    ])
    assert.equal(conversationA, conversationB, "both participants enter the same Conversation")
    return {a, b}
  } catch (error) {
    await a.context.close().catch(() => {})
    await b.context.close().catch(() => {})
    throw error
  }
}

async function installFailedSendProbe(page) {
  await page.evaluate(() => {
    const nativeSend = WebSocket.prototype.send
    window.__failedRetryProbe = {rejectedMessageId: null, retryDelayed: false}

    WebSocket.prototype.send = function(data) {
      if (typeof data === "string") {
        try {
          const frame = JSON.parse(data)
          const topic = frame?.[2]
          const event = frame?.[3]
          const body = frame?.[4]
          const probe = window.__failedRetryProbe

          if (
            typeof topic === "string" && topic.startsWith("conversation:") &&
            event === "message:send" &&
            typeof body?.content === "string" &&
            body?.client_message_id
          ) {
            if (!probe.rejectedMessageId) {
              probe.rejectedMessageId = body.client_message_id
              const rejectedFrame = [...frame]
              rejectedFrame[4] = {...body, content: null}
              return nativeSend.call(this, JSON.stringify(rejectedFrame))
            }

            if (body.client_message_id === probe.rejectedMessageId && !probe.retryDelayed) {
              probe.retryDelayed = true
              setTimeout(() => nativeSend.call(this, data), 600)
              return
            }
          }
        } catch (_error) {}
      }

      return nativeSend.call(this, data)
    }
  })
}

test("failed text send retries in the same optimistic bubble", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const text = "F07 failed retry probe"
    const sender = pair.a.page
    const receiver = pair.b.page

    await installFailedSendProbe(sender)
    await sender.locator('section[data-screen="conversation"].active #message-input').fill(text)
    await sender.locator('section[data-screen="conversation"].active #message-form').getByRole("button", {name: "Send message"}).click()

    const senderRows = sender.locator("#messages li.message", {hasText: text})
    await senderRows.first().waitFor({state: "visible"})
    assert.equal(await senderRows.count(), 1, "optimistic send creates one bubble")

    const status = senderRows.first().locator(":scope > .message-status")
    await status.filter({hasText: "Failed · Tap to retry"}).waitFor({state: "visible", timeout: 10_000})
    await sender.locator("#status").filter({hasText: "An unexpected error occurred. Please try again."}).waitFor({state: "attached", timeout: 10_000})
    assert.equal(await receiver.locator("#messages li.message", {hasText: text}).count(), 0, "rejected send never reaches peer")

    await senderRows.first().locator(":scope > .message-content").click()
    await status.filter({hasText: "sending"}).waitFor({state: "visible", timeout: 500})
    assert.equal(await senderRows.count(), 1, "retry reuses the original bubble")

    const receiverRows = receiver.locator("#messages li.message", {hasText: text})
    await receiverRows.first().waitFor({state: "visible", timeout: 10_000})
    assert.equal(await receiverRows.count(), 1, "retry delivers one logical message")
    assert.equal(await senderRows.count(), 1, "successful retry still has one sender bubble")
    await status.filter({hasText: /sent|delivered/i}).waitFor({state: "visible", timeout: 10_000})
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
