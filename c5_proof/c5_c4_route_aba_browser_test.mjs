import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const CONVERSATION_ID = "123e4567-e89b-42d3-a456-4266141740c5"
const MESSAGE_TEXT = "C5 stale-history ABA route probe"
const DESTRUCTIVE_EVENTS = new Set(["queue:leave", "conversation:end", "conversation:block", "conversation:report"])

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [, , topic, event, body] = JSON.parse(payload)
    return {topic, event, body}
  } catch {
    return null
  }
}

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
    await localData.putRecord({
      ...conversation,
      value: {...conversation.value, status: "kept", connection_state: "ended", ended_at: at}
    })
    await localData.putRecord(localData.localMessage({
      conversation_id: conversationId,
      client_message_id: "c5-aba-message",
      message_id: "c5-aba-message",
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
  await page.locator('[data-screen="chats"].active').waitFor({state: "visible", timeout: 15_000})
  assert.equal(new URL(page.url()).pathname, "/chats", `${label}: URL must be canonical /chats`)
  assert.equal(await page.locator('[data-screen="history"].active').count(), 0, `${label}: deleted history screen must stay inactive`)
  assert.equal(await visibleMessageCount(page), 0, `${label}: deleted message must not visibly remount`)
  assert.equal(await page.getByRole("button", {name: "Open local copy: Advice"}).count(), 0, `${label}: deleted kept object must not return`)

  const state = await page.evaluate(() => history.state)
  assert.equal(state?.path, "/chats", `${label}: history state must be canonical /chats`)

  const stillKept = await page.evaluate(async conversationId => {
    const localData = await import("/assets/local_data.mjs")
    return localData.keptConversations(await localData.listRecords())
      .some(record => record?.value?.conversation_id === conversationId)
  }, CONVERSATION_ID)
  assert.equal(stillKept, false, `${label}: deleted Conversation must stay absent from kept-local state`)
}

test("C5 hostile Chromium: an older stale /chats/:id history entry cannot resurrect after deletion", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const page = await context.newPage()
  const sentFrames = []

  page.on("websocket", websocket => {
    websocket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) sentFrames.push(message)
    })
  })

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok())
    await page.locator("#bottom-nav").waitFor({state: "attached", timeout: 15_000})
    await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: 15_000})

    await seed(page)
    await page.locator('[data-go="chats"]:visible').first().click()
    await page.locator('[data-screen="chats"].active').waitFor({state: "visible"})
    await page.getByRole("button", {name: "Open local copy: Advice"}).click()
    await page.waitForURL(`**/chats/${CONVERSATION_ID}`)
    await page.locator('[data-screen="history"].active').waitFor({state: "visible"})
    assert.equal(await visibleMessageCount(page), 1, "seeded message is visibly mounted before deletion")

    // Build a realistic ABA-shaped history stack. The current UI remains on the
    // Conversation while browser history now contains an older copy of the same
    // route two entries behind the current one.
    await page.evaluate(conversationId => {
      const stale = `/chats/${conversationId}`
      history.pushState({...history.state, path: "/chats"}, "", "/chats")
      history.pushState({...history.state, path: stale}, "", stale)
    }, CONVERSATION_ID)
    assert.equal(new URL(page.url()).pathname, `/chats/${CONVERSATION_ID}`)

    const destructiveMark = sentFrames.length
    page.once("dialog", dialog => dialog.accept())
    await page.locator("#history-delete").click()
    await assertCanonicalChats(page, "after delete")

    // One Back reaches the synthetic /chats entry.
    await page.goBack({waitUntil: "domcontentloaded"})
    await assertCanonicalChats(page, "after first Back")

    // The second Back reaches the older stale /chats/:id entry. The product must
    // canonicalize it instead of remounting the deleted Conversation or leaving
    // the browser URL on a phantom detail route.
    await page.goBack({waitUntil: "domcontentloaded"})
    await assertCanonicalChats(page, "after stale-route Back")

    await page.goForward({waitUntil: "domcontentloaded"})
    await assertCanonicalChats(page, "after Forward")

    await page.reload({waitUntil: "domcontentloaded"})
    await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: 15_000})
    await assertCanonicalChats(page, "after reload")

    const destructive = sentFrames.slice(destructiveMark).filter(({event}) => DESTRUCTIVE_EVENTS.has(event))
    assert.deepEqual(destructive, [], "history attack must not trigger destructive server lifecycle actions")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})