import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
// Pairing retries isolate the pre-existing post-match transition race from this send/retry regression.
const PAIR_ATTEMPTS = 5

async function freshPage(browser) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('body:not(.flow-booting)').waitFor({state: "attached", timeout: 15_000})
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page}
}

async function stableConversation(client) {
  const input = client.page.locator('section[data-screen="conversation"].active #message-input')
  await input.waitFor({state: "visible", timeout: 15_000})
  await client.page.waitForTimeout(300)
  return input.isVisible()
}

async function matchPairAttempt(browser) {
  const a = await freshPage(browser)
  const b = await freshPage(browser)

  try {
    await a.page.getByRole("button", {name: /Deep Talk/}).click()
    await a.page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 10_000})
    await b.page.getByRole("button", {name: /Deep Talk/}).click()

    const [aStable, bStable] = await Promise.all([stableConversation(a), stableConversation(b)])
    if (!aStable || !bStable) throw new Error("conversation transition did not remain stable")

    return {a, b}
  } catch (_error) {
    await a.context.close().catch(() => {})
    await b.context.close().catch(() => {})
    return null
  }
}

async function matchPair(browser) {
  for (let attempt = 1; attempt <= PAIR_ATTEMPTS; attempt += 1) {
    const pair = await matchPairAttempt(browser)
    if (pair) return pair
    await new Promise(resolve => setTimeout(resolve, 500))
  }
  throw new Error(`could not enter a stable Conversation after ${PAIR_ATTEMPTS} pairing attempts`)
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
    await sender.locator('section[data-screen="conversation"].active #message-form button.primary').click()

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
