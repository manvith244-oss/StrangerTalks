import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const CONVERSATION_ID = "123e4567-e89b-42d3-a456-426614174099"
const SEEDED_AT = "2026-09-02T12:00:00.000Z"
const MESSAGE_TEXT = "C4 kept Conversation route proof message."
const DESTRUCTIVE_EVENTS = new Set([
  "queue:leave",
  "conversation:end",
  "conversation:block",
  "conversation:report"
])

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [, , topic, event, body] = JSON.parse(payload)
    return {topic, event, body}
  } catch (_error) {
    return null
  }
}

async function seedKeptConversation(page) {
  await page.evaluate(async ({conversationId, seededAt, messageText}) => {
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
      client_message_id: "c4-kept-route-message",
      message_id: "c4-kept-route-message",
      type: "text",
      content: messageText,
      mine: true,
      delivery_status: "delivered",
      sent_at: seededAt,
      sequence: 1
    }))
  }, {conversationId: CONVERSATION_ID, seededAt: SEEDED_AT, messageText: MESSAGE_TEXT})
}

async function visibleMessageCount(page) {
  return page.getByText(MESSAGE_TEXT, {exact: true}).evaluateAll(nodes => nodes.filter(node => {
    const style = getComputedStyle(node)
    const rect = node.getBoundingClientRect()
    return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0
  }).length)
}

async function assertDeletedConversationCannotMount(page, label) {
  await page.locator('[data-screen="chats"].active').waitFor({state: "visible"})
  assert.equal(new URL(page.url()).pathname, "/chats", `${label}: URL remains canonical Chats`)
  assert.equal(await page.locator('[data-screen="history"].active').count(), 0, `${label}: deleted history screen is not active`)
  assert.equal(await page.getByRole("button", {name: "Open local copy: Advice"}).count(), 0, `${label}: no phantom kept Conversation entry`)
  assert.equal(await visibleMessageCount(page), 0, `${label}: deleted Conversation content is not visible`)

  const state = await page.evaluate(() => history.state)
  assert.equal(state?.path, "/chats", `${label}: browser history state is canonical Chats`)

  const stillKept = await page.evaluate(async conversationId => {
    const localData = await import("/assets/local_data.mjs")
    return localData.keptConversations(await localData.listRecords())
      .some(record => record?.value?.conversation_id === conversationId)
  }, CONVERSATION_ID)
  assert.equal(stillKept, false, `${label}: deleted Conversation is not live kept-local state`)
}

async function runScenario({viewport, isMobile, hasTouch, keyboardDelete}) {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport, isMobile, hasTouch})
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
    assert.ok(response?.ok(), "root page loads")
    await page.locator("#bottom-nav").waitFor({state: "attached", timeout: 15_000})
    await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: 15_000})

    await seedKeptConversation(page)

    const chatsControl = page.locator('[data-go="chats"]:visible').first()
    await chatsControl.waitFor({state: "visible"})
    await chatsControl.click()
    await page.locator('[data-screen="chats"].active').waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")

    await page.getByRole("button", {name: "Open local copy: Advice"}).click()
    await page.waitForURL(`**/chats/${CONVERSATION_ID}`)
    await page.locator('[data-screen="history"].active').waitFor({state: "visible"})
    assert.equal(await visibleMessageCount(page), 1, "seeded local Conversation content is mounted before deletion")

    const destructiveMark = sentFrames.length
    page.once("dialog", dialog => dialog.accept())
    const deleteButton = page.locator("#history-delete")
    if (keyboardDelete) {
      await deleteButton.focus()
      assert.equal(await page.evaluate(() => document.activeElement?.id), "history-delete", "delete action is keyboard focusable")
      await page.keyboard.press("Enter")
    } else {
      await deleteButton.click()
    }

    await assertDeletedConversationCannotMount(page, "after delete")

    await page.goBack({waitUntil: "domcontentloaded"})
    await assertDeletedConversationCannotMount(page, "after browser Back")
    assert.notEqual(new URL(page.url()).pathname, `/chats/${CONVERSATION_ID}`, "Back cannot resurrect the deleted route")

    await page.goForward({waitUntil: "domcontentloaded"})
    await assertDeletedConversationCannotMount(page, "after browser Forward")

    await page.reload({waitUntil: "domcontentloaded"})
    await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: 15_000})
    await assertDeletedConversationCannotMount(page, "after reload")

    const destructive = sentFrames.slice(destructiveMark).filter(({event}) => DESTRUCTIVE_EVENTS.has(event))
    assert.deepEqual(destructive, [], "delete/Back/Forward/reload triggers no destructive server lifecycle action")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
}

test("C4 mobile: kept Conversation deletion replaces route and Back/Forward never resurrect it", {timeout: 60_000}, async () => {
  await runScenario({
    viewport: {width: 390, height: 844},
    isMobile: true,
    hasTouch: true,
    keyboardDelete: false
  })
})

test("C4 desktop: kept Conversation deletion is keyboard reachable and Back/Forward never resurrect it", {timeout: 60_000}, async () => {
  await runScenario({
    viewport: {width: 1280, height: 800},
    isMobile: false,
    hasTouch: false,
    keyboardDelete: true
  })
})
