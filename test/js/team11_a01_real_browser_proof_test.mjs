import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/team11-a01-proof-screenshots")
const WAIT_MS = 15_000
const DB_NAME = "strangertalks-local-v1"
const STORE = "records"

fs.mkdirSync(SCREENSHOTS, {recursive: true})

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
  }

  add(event) {
    this.events.push(event)
  }

  mark() {
    return this.events.length
  }

  since(mark) {
    return this.events.slice(mark)
  }

  async waitFor(predicate, label, from = 0) {
    const deadline = Date.now() + WAIT_MS
    while (Date.now() < deadline) {
      const found = this.events.slice(from).find(predicate)
      if (found) return found
      await new Promise(resolve => setTimeout(resolve, 25))
    }
    throw new Error(`Timed out waiting for ${label}`)
  }
}

async function observePage(context, viewport = {width: 390, height: 844}) {
  const page = await context.newPage()
  await page.setViewportSize(viewport)
  const journal = new Journal()
  const pageErrors = []
  const consoleErrors = []

  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text())
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

  return {context, page, journal, pageErrors, consoleErrors}
}

async function bootFresh(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({
    viewport,
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2
  })
  const observed = await observePage(context, viewport)
  const response = await observed.page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await observed.page.locator("button.door").first().waitFor({state: "visible", timeout: WAIT_MS})
  await observed.page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await observed.journal.waitFor(
    event => event.type === "frame_received" && event.topic?.startsWith("participant:") && event.event === "phx_reply" && event.body?.status === "ok" && event.body?.response?.status === "connected",
    "ParticipantChannel join"
  )
  return observed
}

async function selectLanguageAndQueue(observed, door = "Advice") {
  await observed.page.locator("#conversation-language").selectOption("en")
  await observed.page.getByRole("button", {name: new RegExp(door)}).click()
  await observed.page.locator('[data-screen="queue"].active').waitFor({state: "visible", timeout: WAIT_MS})
  await observed.page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: WAIT_MS})
}

async function waitForConversation(observed, from = 0) {
  await observed.page.locator('[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
  const joined = await observed.journal.waitFor(
    event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
    "ConversationChannel join",
    from
  )
  await observed.page.locator(".ig-compose-plus").waitFor({state: "visible", timeout: WAIT_MS})
  return joined.topic
}

async function matchPair(browser, door = "Advice") {
  const a = await bootFresh(browser)
  const b = await bootFresh(browser)
  await selectLanguageAndQueue(a, door)
  await b.page.locator("#conversation-language").selectOption("en")
  const markA = a.journal.mark()
  const markB = b.journal.mark()
  await b.page.getByRole("button", {name: new RegExp(door)}).click()
  const [topicA, topicB] = await Promise.all([waitForConversation(a, markA), waitForConversation(b, markB)])
  assert.equal(topicA, topicB, "both real participants enter the same Conversation")
  return {a, b, topic: topicA}
}

async function sendAndReceive(sender, receiver, topic, text) {
  const mark = sender.journal.mark()
  await sender.page.locator("#message-input").fill(text)
  await sender.page.getByRole("button", {name: "Send message"}).click()
  const frame = await sender.journal.waitFor(
    event => event.type === "frame_sent" && event.topic === topic && event.event === "message:send" && event.body?.content === text,
    `message:send for ${text}`,
    mark
  )
  await receiver.page.locator("#messages li", {hasText: text}).waitFor({state: "visible", timeout: WAIT_MS})
  assert.equal(await receiver.page.locator("#messages li", {hasText: text}).count(), 1)
  return frame
}

function messageSendEvents(observed, topic, from = 0) {
  return observed.journal.since(from).filter(event => event.type === "frame_sent" && event.topic === topic && event.event === "message:send")
}

async function openCompanion(page) {
  if (await page.locator("#companion-panel").isVisible()) return
  if (!(await page.locator("#companion-control").isVisible())) {
    await page.locator(".ig-compose-plus").click()
  }
  await page.locator("#companion-control").click()
  await page.locator("#companion-panel").waitFor({state: "visible", timeout: WAIT_MS})
  assert.equal(await page.locator("#companion-control").getAttribute("aria-expanded"), "true")
  assert.equal(await page.locator("#companion-request").evaluate(node => node === document.activeElement), true)
  assert.equal(await page.locator("#companion-status").getAttribute("role"), "status")
  assert.equal(await page.locator("#companion-status").getAttribute("aria-live"), "polite")
}

async function closeCompanion(page) {
  if (!(await page.locator("#companion-panel").isVisible())) return
  await page.locator("#companion-close").click()
  await page.locator("#companion-panel").waitFor({state: "hidden", timeout: WAIT_MS})
  assert.equal(await page.locator("#companion-control").getAttribute("aria-expanded"), "false")
  assert.equal(await page.locator("#companion-control").evaluate(node => node === document.activeElement), true)
}

async function clearCompanionRequest(page) {
  await page.locator("#companion-request").fill("")
  await page.locator("#message-input").fill("")
}

async function putRecord(page, record) {
  await page.evaluate(async ({dbName, storeName, value}) => {
    await new Promise((resolve, reject) => {
      const opening = indexedDB.open(dbName, 1)
      opening.onupgradeneeded = () => opening.result.createObjectStore(storeName, {keyPath: "id"})
      opening.onerror = () => reject(opening.error)
      opening.onsuccess = () => {
        const db = opening.result
        const transaction = db.transaction(storeName, "readwrite")
        transaction.objectStore(storeName).put(value)
        transaction.oncomplete = () => { db.close(); resolve() }
        transaction.onerror = () => { db.close(); reject(transaction.error) }
      }
    })
  }, {dbName: DB_NAME, storeName: STORE, value: record})
}

async function getRecord(page, id) {
  return page.evaluate(async ({dbName, storeName, key}) => new Promise((resolve, reject) => {
    const opening = indexedDB.open(dbName, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(storeName, {keyPath: "id"})
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => {
      const db = opening.result
      const transaction = db.transaction(storeName, "readonly")
      const request = transaction.objectStore(storeName).get(key)
      request.onsuccess = () => resolve(request.result || null)
      request.onerror = () => reject(request.error)
      transaction.oncomplete = () => db.close()
    }
  }), {dbName: DB_NAME, storeName: STORE, key: id})
}

async function deleteRecord(page, id) {
  await page.evaluate(async ({dbName, storeName, key}) => {
    await new Promise((resolve, reject) => {
      const opening = indexedDB.open(dbName, 1)
      opening.onupgradeneeded = () => opening.result.createObjectStore(storeName, {keyPath: "id"})
      opening.onerror = () => reject(opening.error)
      opening.onsuccess = () => {
        const db = opening.result
        const transaction = db.transaction(storeName, "readwrite")
        transaction.objectStore(storeName).delete(key)
        transaction.oncomplete = () => { db.close(); resolve() }
        transaction.onerror = () => { db.close(); reject(transaction.error) }
      }
    })
  }, {dbName: DB_NAME, storeName: STORE, key: id})
}

function successBody(text = "That makes sense. What happened next?") {
  return {
    status: "ready",
    language: "en",
    mode: "respond",
    suggestions: [
      {style: "Warm", text},
      {style: "Direct", text: "What changed your mind about it?"}
    ]
  }
}

async function fulfilJson(route, status, body, delayMs = 0) {
  if (delayMs > 0) await new Promise(resolve => setTimeout(resolve, delayMs))
  try {
    await route.fulfill({status, contentType: "application/json", body: JSON.stringify(body)})
  } catch (error) {
    if (!/Target page, context or browser has been closed|Route is already handled|Request aborted|Failed to fulfill/i.test(String(error))) throw error
  }
}

async function requestCompanion(page, requestText, {mode = "respond", tone = "warm"} = {}) {
  await openCompanion(page)
  await page.locator("#companion-mode").selectOption(mode)
  await page.locator("#companion-tone").selectOption(tone)
  await page.locator("#companion-request").fill(requestText)
  await page.locator("#companion-generate").click()
  await page.getByText("Thinking…", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
  assert.equal(await page.locator("#companion-generate").isDisabled(), true)
  assert.equal(await page.locator("#companion-cancel").isVisible(), true)
}

function assertNoUnexpectedPageErrors(observed) {
  assert.deepEqual(observed.pageErrors, [], "no page errors")
  assert.deepEqual(observed.consoleErrors, [], "no console errors")
}

test("T-A11-002 real Chromium proves A01 human authorship and degradation boundaries", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    const {a, b, topic} = pair
    const conversationId = topic.replace(/^conversation:/, "")
    const conversationRecordId = `conversation:${conversationId}`
    const originalConversationRecord = await getRecord(a.page, conversationRecordId)
    assert.ok(originalConversationRecord, "real Conversation is present in participant local authority")

    let responder = null
    let companionRequests = 0
    await a.page.route(/\/api\/conversations\/[^/]+\/companion$/, async route => {
      companionRequests += 1
      assert.equal(typeof responder, "function", "proof responder configured")
      await responder(route)
    })

    let capturedGoldenRequest = null
    responder = async route => {
      capturedGoldenRequest = {
        url: route.request().url(),
        authorization: route.request().headers()["authorization"],
        body: route.request().postDataJSON()
      }
      await fulfilJson(route, 200, successBody(), 350)
    }

    const goldenMark = a.journal.mark()
    await requestCompanion(a.page, "Help me reply naturally.")
    assert.deepEqual(messageSendEvents(a, topic, goldenMark), [], "requesting assistance sends no participant Message")

    await a.page.getByText("Choose one, edit it, or ignore it. Nothing is sent automatically.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(companionRequests, 1)
    assert.ok(capturedGoldenRequest.url.endsWith(`/api/conversations/${conversationId}/companion`))
    assert.match(capturedGoldenRequest.authorization || "", /^Bearer /)
    assert.deepEqual(capturedGoldenRequest.body, {mode: "respond", tone: "warm", request: "Help me reply naturally."})
    assert.deepEqual(messageSendEvents(a, topic, goldenMark), [], "rendering suggestions sends no participant Message")

    await a.page.locator(".companion-suggestion").first().getByRole("button", {name: "Use in draft"}).click()
    assert.equal(await a.page.locator("#message-input").inputValue(), "That makes sense. What happened next?")
    assert.deepEqual(messageSendEvents(a, topic, goldenMark), [], "Use in draft sends no participant Message")

    const participantEditedText = "That makes sense — what happened next for you?"
    await a.page.locator("#message-input").fill(participantEditedText)
    assert.deepEqual(messageSendEvents(a, topic, goldenMark), [], "editing an AI-assisted draft sends no participant Message")

    await a.page.screenshot({path: path.join(SCREENSHOTS, "golden-path-before-human-send.png"), fullPage: false})
    const humanFrame = await sendAndReceive(a, b, topic, participantEditedText)
    assert.equal(humanFrame.body?.content, participantEditedText)
    assert.equal(messageSendEvents(a, topic, goldenMark).length, 1, "ordinary human Send is the first Message authority event")

    await clearCompanionRequest(a.page)
    responder = route => fulfilJson(route, 200, successBody("Late cancelled suggestion"), 700)
    const cancelMark = a.journal.mark()
    await requestCompanion(a.page, "Give me another reply.")
    await a.page.locator("#companion-cancel").click()
    await a.page.getByText("Cancelled.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    await a.page.waitForTimeout(900)
    assert.equal(await a.page.locator(".companion-suggestion").count(), 0)
    assert.deepEqual(messageSendEvents(a, topic, cancelMark), [], "cancelled generation sends no participant Message")

    await clearCompanionRequest(a.page)
    await a.page.locator("#message-input").fill("My original draft")
    responder = route => fulfilJson(route, 200, successBody("AI replacement that must not overwrite"), 500)
    const staleDraftMark = a.journal.mark()
    await requestCompanion(a.page, "Rephrase my draft.", {mode: "rephrase"})
    await a.page.locator("#message-input").fill("My original draft plus newer human words")
    await a.page.getByText("Choose one, edit it, or ignore it. Nothing is sent automatically.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    await a.page.locator(".companion-suggestion").first().getByRole("button", {name: "Use in draft"}).click()
    await a.page.getByText("Your draft changed while this suggestion was being prepared. Generate again so nothing you typed gets overwritten.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(await a.page.locator("#message-input").inputValue(), "My original draft plus newer human words")
    assert.deepEqual(messageSendEvents(a, topic, staleDraftMark), [], "stale suggestion cannot send or overwrite human work")

    await clearCompanionRequest(a.page)
    responder = route => fulfilJson(route, 200, successBody("Stale Conversation suggestion"), 600)
    const staleConversationMark = a.journal.mark()
    await requestCompanion(a.page, "Help me continue.", {mode: "continue"})
    const fakeConversationId = "00000000-0000-4000-8000-000000000011"
    await putRecord(a.page, {
      ...originalConversationRecord,
      id: `conversation:${fakeConversationId}`,
      value: {...originalConversationRecord.value, conversation_id: fakeConversationId, status: "temporary", connection_state: "connected"},
      updated_at: new Date().toISOString()
    })
    await putRecord(a.page, {
      ...originalConversationRecord,
      value: {...originalConversationRecord.value, status: "kept", connection_state: "ended"},
      updated_at: new Date().toISOString()
    })
    await a.page.getByText("The Conversation changed while I was helping. Try again with the current Conversation.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(await a.page.locator(".companion-suggestion").count(), 0)
    assert.deepEqual(messageSendEvents(a, topic, staleConversationMark), [], "stale Conversation result sends no participant Message")
    await putRecord(a.page, originalConversationRecord)
    await deleteRecord(a.page, `conversation:${fakeConversationId}`)

    await clearCompanionRequest(a.page)
    const ambiguousConversationId = "00000000-0000-4000-8000-000000000012"
    await putRecord(a.page, {
      ...originalConversationRecord,
      id: `conversation:${ambiguousConversationId}`,
      value: {...originalConversationRecord.value, conversation_id: ambiguousConversationId, status: "temporary", connection_state: "recovery"},
      updated_at: new Date().toISOString()
    })
    const requestsBeforeAmbiguous = companionRequests
    const ambiguousMark = a.journal.mark()
    responder = route => fulfilJson(route, 200, successBody("must not be requested"))
    await requestCompanion(a.page, "Help while state is ambiguous.")
    await a.page.getByText("Conversation state is still reconciling. Try again once this Conversation is fully active.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(companionRequests, requestsBeforeAmbiguous, "ambiguous authority fails before model HTTP invocation")
    assert.deepEqual(messageSendEvents(a, topic, ambiguousMark), [], "ambiguous authority sends no participant Message")
    await deleteRecord(a.page, `conversation:${ambiguousConversationId}`)

    const failures = [
      {
        name: "rate limited",
        status: 429,
        body: {error: {code: "COMPANION_RATE_LIMITED", retryable: true, retry_after_ms: 1000}},
        copy: "Too many requests right now. Give it a bit and try again."
      },
      {
        name: "output rejected",
        status: 422,
        body: {error: {code: "COMPANION_OUTPUT_REJECTED", retryable: true}},
        copy: "I couldn’t provide a safe suggestion for that. Try asking in a different way."
      },
      {
        name: "provider unavailable",
        status: 503,
        body: {error: {code: "COMPANION_UNAVAILABLE", retryable: true}},
        copy: "Couldn’t help with that right now. Your Conversation still works normally."
      }
    ]

    for (const failure of failures) {
      await clearCompanionRequest(a.page)
      responder = route => fulfilJson(route, failure.status, failure.body, 100)
      const mark = a.journal.mark()
      await requestCompanion(a.page, `Proof ${failure.name}.`)
      await a.page.getByText(failure.copy, {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
      assert.equal(await a.page.locator(".companion-suggestion").count(), 0)
      assert.deepEqual(messageSendEvents(a, topic, mark), [], `${failure.name} sends no participant Message`)
    }

    const afterFailureText = "Human chat still works after Companion failure"
    await sendAndReceive(a, b, topic, afterFailureText)

    await clearCompanionRequest(a.page)
    responder = async route => { await route.abort("connectionfailed") }
    const networkMark = a.journal.mark()
    await requestCompanion(a.page, "Proof network failure.")
    await a.page.getByText("Couldn’t help with that right now. Your Conversation still works normally.", {exact: true}).waitFor({state: "visible", timeout: WAIT_MS})
    assert.deepEqual(messageSendEvents(a, topic, networkMark), [], "network failure sends no participant Message")
    await sendAndReceive(a, b, topic, "Human chat also survives Companion network failure")

    await clearCompanionRequest(a.page)
    await a.page.setViewportSize({width: 844, height: 390})
    await openCompanion(a.page)
    const landscape = await a.page.locator("#companion-panel").evaluate(panel => {
      const rect = panel.getBoundingClientRect()
      const close = panel.querySelector("#companion-close")?.getBoundingClientRect()
      const style = getComputedStyle(panel)
      return {
        top: rect.top,
        bottom: rect.bottom,
        height: rect.height,
        viewportHeight: innerHeight,
        overflowY: style.overflowY,
        scrollHeight: panel.scrollHeight,
        clientHeight: panel.clientHeight,
        closeTop: close?.top ?? null,
        closeBottom: close?.bottom ?? null
      }
    })
    await a.page.screenshot({path: path.join(SCREENSHOTS, "phone-landscape-companion.png"), fullPage: false})
    assert.ok(landscape.closeTop !== null && landscape.closeTop >= -1, `close control starts above viewport: ${landscape.closeTop}`)
    assert.ok(landscape.closeBottom <= landscape.viewportHeight + 1, `close control ends below viewport: ${landscape.closeBottom}`)
    if (landscape.bottom > landscape.viewportHeight + 1) {
      assert.ok(["auto", "scroll"].includes(landscape.overflowY), `overflowing Companion panel is not scrollable: ${JSON.stringify(landscape)}`)
    }
    await closeCompanion(a.page)

    assertNoUnexpectedPageErrors(a)
    assertNoUnexpectedPageErrors(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
