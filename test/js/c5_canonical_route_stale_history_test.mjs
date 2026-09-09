import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const CONVERSATION_ID = "123e4567-e89b-42d3-a456-4266141740c5"
const MESSAGE_TEXT = "C5 canonical stale-history route probe"

async function visibleMessageCount(page) {
  return page.getByText(MESSAGE_TEXT, {exact: true}).evaluateAll(nodes => nodes.filter(node => {
    const style = getComputedStyle(node)
    const rect = node.getBoundingClientRect()
    return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0
  }).length)
}

async function seed(page) {
  await page.evaluate(async ({conversationId, messageText}) => {
    const localData = await import("/assets/local_data.mjs")
    const at = "2026-09-10T00:00:00.000Z"
    const conversation = localData.temporaryConversation({
      conversation_id: conversationId,
      door_type: "EXPLORE",
      display_door: "Advice",
      started_at: at
    })
    await localData.putRecord({...conversation, value: {...conversation.value, status: "kept", connection_state: "ended", ended_at: at}})
    await localData.putRecord(localData.localMessage({
      conversation_id: conversationId,
      client_message_id: "c5-canonical-aba-message",
      message_id: "c5-canonical-aba-message",
      type: "text",
      content: messageText,
      mine: true,
      delivery_status: "delivered",
      sent_at: at,
      sequence: 1
    }))
  }, {conversationId: CONVERSATION_ID, messageText: MESSAGE_TEXT})
}

async function assertCanonicalChats(page, label) {
  await page.locator('[data-screen="chats"].active').waitFor({state: "visible", timeout: 5_000})
  assert.equal(new URL(page.url()).pathname, "/chats", `${label}: URL must be canonical /chats`)
  assert.equal(await page.locator('[data-screen="history"].active').count(), 0, `${label}: deleted history must be inactive`)
  assert.equal(await visibleMessageCount(page), 0, `${label}: deleted content must not visibly remount`)
  const state = await page.evaluate(() => history.state)
  assert.equal(state?.path, "/chats", `${label}: history state must be canonical /chats`)
}

test("C5 canonical RED probe: stale older /chats/:id cannot resurrect after kept Conversation deletion", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const page = await context.newPage()

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok())
    await page.locator("#bottom-nav").waitFor({state: "attached", timeout: 15_000})
    await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: 15_000})

    await seed(page)
    await page.locator('[data-go="chats"]:visible').first().click()
    await page.getByRole("button", {name: "Open local copy: Advice"}).click()
    await page.waitForURL(`**/chats/${CONVERSATION_ID}`)
    await page.locator('[data-screen="history"].active').waitFor({state: "visible"})
    assert.equal(await visibleMessageCount(page), 1)

    await page.evaluate(conversationId => {
      const stale = `/chats/${conversationId}`
      history.pushState({...history.state, path: "/chats"}, "", "/chats")
      history.pushState({...history.state, path: stale}, "", stale)
    }, CONVERSATION_ID)

    page.once("dialog", dialog => dialog.accept())
    await page.locator("#history-delete").click()
    await assertCanonicalChats(page, "after delete")

    await page.goBack({waitUntil: "domcontentloaded"})
    await assertCanonicalChats(page, "after first Back")

    await page.goBack({waitUntil: "domcontentloaded"})
    await assertCanonicalChats(page, "after stale-route Back")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})