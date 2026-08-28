import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

async function freshPage(browser, {rejectFirstTextSend = false} = {}) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})

  if (rejectFirstTextSend) {
    await context.addInitScript(() => {
      const NativeWebSocket = window.WebSocket
      const nativeSend = NativeWebSocket.prototype.send
      window.__failedRetryProbe = {rejectedMessageId: null, retryDelayed: false}

      class FailedRetryWebSocket extends NativeWebSocket {
        send(data) {
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
                  rejectedFrame[4] = {...body, content: ""}
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
      }

      window.WebSocket = FailedRetryWebSocket
    })
  }

  const page = await context.newPage()
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('body:not(.flow-booting)').waitFor({state: "attached", timeout: 15_000})
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page}
}

async function matchPair(browser) {
  const a = await freshPage(browser, {rejectFirstTextSend: true})
  const b = await freshPage(browser)

  await Promise.all([
    a.page.getByRole("button", {name: /Deep Talk/}).click(),
    b.page.getByRole("button", {name: /Deep Talk/}).click()
  ])

  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
  ])

  return {a, b}
}

test("failed text send retries in the same optimistic bubble", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const text = "F07 failed retry probe"
    const sender = pair.a.page
    const receiver = pair.b.page

    await sender.locator("#message-input").fill(text)
    await sender.locator("#message-form button.primary").click()

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