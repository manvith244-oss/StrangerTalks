import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const CONVERSATION_ID = "123e4567-e89b-42d3-a456-426614174099"
const SEEDED_AT = "2026-09-02T12:00:00.000Z"

test("deleting the open kept Conversation replaces its invalidated history route with Chats", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}, isMobile: true, hasTouch: true})
  const page = await context.newPage()
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()) })

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root page loads")
    await page.locator("button.door").first().waitFor({state: "visible", timeout: 15_000})

    await page.evaluate(async ({conversationId, seededAt}) => {
      const localData = await import("/assets/local_data.mjs")
      const conversation = localData.temporaryConversation({
        conversation_id: conversationId,
        door_type: "EXPLORE",
        display_door: "Advice",
        started_at: seededAt
      })

      await localData.putRecord({
        ...conversation,
        value: {
          ...conversation.value,
          status: "kept",
          connection_state: "ended",
          ended_at: seededAt
        }
      })

      await localData.putRecord(localData.localMessage({
        conversation_id: conversationId,
        client_message_id: "t03-history-route-message",
        message_id: "t03-history-route-message",
        type: "text",
        content: "A kept local message.",
        mine: true,
        delivery_status: "delivered",
        sent_at: seededAt,
        sequence: 1
      }))
    }, {conversationId: CONVERSATION_ID, seededAt: SEEDED_AT})

    await page.locator('#bottom-nav [data-go="chats"]').click()
    await page.locator('[data-screen="chats"].active').waitFor({state: "visible"})
    await page.getByRole("button", {name: "Open local copy: Advice"}).click()
    await page.waitForURL(`**/chats/${CONVERSATION_ID}`)
    await page.locator('[data-screen="history"].active').waitFor({state: "visible"})

    assert.match(await page.locator(".local-copy-banner").innerText(), /not an active Conversation/i)

    page.once("dialog", dialog => dialog.accept())
    await page.locator("#history-delete").click()
    await page.locator('[data-screen="chats"].active').waitFor({state: "visible"})

    assert.equal(
      new URL(page.url()).pathname,
      "/chats",
      "deleting the current local copy must replace the invalidated /chats/:id route"
    )
    assert.equal(await page.locator('[data-screen="history"].active').count(), 0)
    assert.deepEqual(errors, [])
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
