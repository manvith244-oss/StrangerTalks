import assert from "node:assert/strict"
import {randomUUID} from "node:crypto"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = "http://localhost:4000"
const WAIT_TIMEOUT_MS = 12_000
const DRAFT_RECORD_TYPE = "conversation_draft"

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_error) {
    return null
  }
}

class Journal {
  constructor() {
    this.events = []
    this.waiters = new Set()
  }

  add(event) {
    this.events.push(event)
    for (const waiter of [...this.waiters]) {
      if (!waiter.predicate(event)) continue
      clearTimeout(waiter.timer)
      this.waiters.delete(waiter)
      waiter.resolve(event)
    }
  }

  mark() {
    return this.events.length
  }

  waitFor(predicate, label, from = 0, timeout = WAIT_TIMEOUT_MS) {
    const existing = this.events.slice(from).find(predicate)
    if (existing) return Promise.resolve(existing)

    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, timer: null}
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter)
        const recentFrames = this.events.slice(-16).map(({type, topic, event, body}) => ({
          type,
          topic,
          event,
          status: body?.status,
          responseStatus: body?.response?.status,
          clientMessageId: body?.response?.client_message_id
        }))
        reject(new Error(`Timed out waiting for ${label}; recent frames: ${JSON.stringify(recentFrames)}`))
      }, timeout)
      this.waiters.add(waiter)
    })
  }
}

async function observePage(context, page) {
  const journal = new Journal()
  const pageErrors = []
  const consoleErrors = []

  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  page.on("response", response => {
    const path = new URL(response.url()).pathname
    if (path === "/api/participants") journal.add({type: "participant_bootstrap", status: response.status()})
  })
  page.on("websocket", websocket => {
    websocket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_sent", ...message})
    })
    websocket.on("framereceived", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_received", ...message})
    })
  })

  return {page, journal, pageErrors, consoleErrors}
}

async function waitForParticipantJoin(observed, from = 0) {
  return observed.journal.waitFor(
    event => event.type === "frame_received" &&
      event.topic?.startsWith("participant:") &&
      event.event === "phx_reply" &&
      event.body?.status === "ok" &&
      event.body?.response?.status === "connected",
    "ParticipantChannel join",
    from
  )
}

async function bootFresh(browser, {controllableSocket = false} = {}) {
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const socketControl = {dropNextServerFrame: null, droppedServerFrames: []}

  if (controllableSocket) {
    await context.routeWebSocket(/\/socket\/websocket/, route => {
      const serverRoute = route.connectToServer()
      serverRoute.onMessage(payload => {
        const message = phoenixMessage(payload)
        if (socketControl.dropNextServerFrame?.(message)) {
          socketControl.droppedServerFrames.push(message)
          socketControl.dropNextServerFrame = null
          return
        }
        route.send(payload)
      })
    })
  }

  const page = await context.newPage()
  const observed = await observePage(context, page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  const bootstrap = await observed.journal.waitFor(event => event.type === "participant_bootstrap", "participant bootstrap")
  assert.ok(bootstrap.status >= 200 && bootstrap.status < 300, "participant bootstrap succeeds")
  await waitForParticipantJoin(observed)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("#conversation-language").selectOption("en")

  return {
    context,
    dropNextServerFrame: predicate => { socketControl.dropNextServerFrame = predicate },
    socketControl,
    ...observed
  }
}

async function clickDoorAndQueue(page, label) {
  const door = page.locator(`button.door:has-text("${label}")`)
  await door.waitFor({state: "visible"})
  await door.click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
}

async function waitForConversation(observed, from = 0) {
  await observed.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
  const joined = await observed.journal.waitFor(
    event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
    "ConversationChannel join",
    from
  )
  return joined.topic
}

async function matchPair(browser) {
  const a = await bootFresh(browser, {controllableSocket: true})
  const b = await bootFresh(browser)
  await clickDoorAndQueue(a.page, "Advice")
  await b.page.locator('button.door:has-text("Advice")').click()
  const [conversationA, conversationB] = await Promise.all([waitForConversation(a), waitForConversation(b)])
  assert.equal(conversationA, conversationB, "both participants join the same Conversation")
  return {a, b, conversationTopic: conversationA}
}

function draftKey(conversationId) {
  return `conversation_draft:${conversationId}`
}

async function readRecord(page, id) {
  return page.evaluate(async recordId => {
    const {getRecord} = await import("/assets/local_data.mjs")
    return getRecord(recordId)
  }, id)
}

async function writeDraftRecord(page, conversationId, text) {
  return page.evaluate(async ({conversationId, text, type}) => {
    const {putRecord} = await import("/assets/local_data.mjs")
    return putRecord({
      id: `${type}:${conversationId}`,
      type,
      schema_version: 1,
      value: {conversation_id: conversationId, text},
      updated_at: new Date().toISOString()
    })
  }, {conversationId, text, type: DRAFT_RECORD_TYPE})
}

async function waitForRecord(page, id, predicateSource, argument) {
  await page.waitForFunction(async ({id, predicateSource, argument}) => {
    const {getRecord} = await import("/assets/local_data.mjs")
    const record = await getRecord(id)
    const predicate = new Function("record", "argument", `return (${predicateSource})(record, argument)`)
    return predicate(record, argument)
  }, {id, predicateSource, argument}, {timeout: WAIT_TIMEOUT_MS})
}

test("Conversation draft survives reload, stays scoped, and clears at optimistic staging", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, conversationTopic} = pair
    const conversationId = conversationTopic.slice("conversation:".length)
    const foreignConversationId = randomUUID()
    const draftText = "keep this unfinished thought across refresh"
    const foreignText = "belongs to another conversation"

    await writeDraftRecord(a.page, foreignConversationId, foreignText)
    await a.page.locator("#message-input").fill(draftText)

    await waitForRecord(
      a.page,
      draftKey(conversationId),
      "(record, expected) => record?.type === 'conversation_draft' && record?.value?.conversation_id === expected.conversationId && record?.value?.text === expected.text",
      {conversationId, text: draftText}
    )

    const reloadMark = a.journal.mark()
    await a.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(a, reloadMark)
    assert.equal(await waitForConversation(a, reloadMark), conversationTopic, "reload rejoins the same Conversation")
    await a.page.locator("#message-input").waitFor({state: "visible"})
    await a.page.waitForFunction(expected => document.querySelector("#message-input")?.value === expected, draftText)
    assert.equal(await a.page.locator("#message-input").inputValue(), draftText, "typed draft is restored after reload")

    const foreignBeforeSend = await readRecord(a.page, draftKey(foreignConversationId))
    assert.equal(foreignBeforeSend?.value?.text, foreignText, "another Conversation draft remains separate")

    a.dropNextServerFrame(message =>
      message?.topic === conversationTopic &&
      message?.event === "phx_reply" &&
      typeof message?.body?.response?.client_message_id === "string"
    )

    const sendMark = a.journal.mark()
    await a.page.locator("#message-form button.primary").click()
    const bubble = a.page.locator("#messages li", {hasText: draftText})
    await bubble.waitFor({state: "visible"})
    assert.equal(await a.page.locator("#message-input").inputValue(), "", "composer clears when optimistic bubble appears")

    const sentFrame = await a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === conversationTopic && event.event === "message:send" && event.body?.content === draftText,
      "text message send",
      sendMark
    )
    assert.ok(sentFrame.body?.client_message_id, "optimistic send has a stable client message id")

    await waitForRecord(a.page, draftKey(conversationId), "record => record == null", null)
    assert.equal(await readRecord(a.page, draftKey(conversationId)), null, "draft is gone before any send confirmation")
    assert.equal(a.socketControl.droppedServerFrames.length, 1, "server confirmation was intentionally withheld")
    assert.equal((await readRecord(a.page, draftKey(foreignConversationId)))?.value?.text, foreignText, "sending does not clear another Conversation draft")

    await bubble.locator("small").filter({hasText: "failed"}).waitFor({state: "visible", timeout: 20_000})
    assert.equal(await bubble.locator("span").filter({hasText: draftText}).count(), 1, "failed bubble retains the message text")
    assert.equal(await readRecord(a.page, draftKey(conversationId)), null, "failed send does not recreate a duplicate draft")

    await bubble.click()
    await bubble.locator("small").filter({hasText: /sent|delivered/}).waitFor({state: "visible", timeout: 20_000})
    assert.equal(await readRecord(a.page, draftKey(conversationId)), null, "tap-to-retry owns recovery without a draft copy")

    assert.deepEqual(a.pageErrors, [], "no uncaught page errors")
    assert.deepEqual(a.consoleErrors, [], "no console errors")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
