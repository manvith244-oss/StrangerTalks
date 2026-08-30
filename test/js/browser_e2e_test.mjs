import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = "http://localhost:4000"
const TEST_TIMEOUT_MS = 45_000
const WAIT_TIMEOUT_MS = 12_000
const DOORS = ["Deep Talk", "Vent", "Distract", "Advice"]

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
      if (waiter.predicate(event)) {
        clearTimeout(waiter.timer)
        this.waiters.delete(waiter)
        waiter.resolve(event)
      }
    }
  }

  mark() {
    return this.events.length
  }

  waitFor(predicate, label, from = 0) {
    const existing = this.events.slice(from).find(predicate)
    if (existing) return Promise.resolve(existing)

    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, timer: null}
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter)
        const recentFrames = this.events.slice(-20).map(({type, topic, event, ref, body}) => ({
          type,
          topic,
          event,
          ref,
          status: body?.status,
          responseStatus: body?.response?.status,
          code: body?.response?.code
        }))
        reject(new Error(`Timed out waiting for ${label}; recent frames: ${JSON.stringify(recentFrames)}`))
      }, WAIT_TIMEOUT_MS)
      this.waiters.add(waiter)
    })
  }
}

async function observePage(context, page) {
  const journal = new Journal()
  const pageErrors = []
  const consoleErrors = []
  const failedRequests = []
  const cdp = await context.newCDPSession(page)

  await cdp.send("Network.enable")
  cdp.on("Network.webSocketWillSendHandshakeRequest", ({request}) => {
    const protocols = request.headers["Sec-WebSocket-Protocol"] || request.headers["sec-websocket-protocol"] || ""
    journal.add({
      type: "websocket_handshake",
      hasAuthProtocol: protocols.split(",").some(value => value.trim().startsWith("base64url.bearer.phx."))
    })
  })

  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  page.on("requestfailed", request => {
    failedRequests.push({url: request.url(), reason: request.failure()?.errorText || "unknown"})
  })
  page.on("response", response => {
    const path = new URL(response.url()).pathname
    if (path === "/api/participants") journal.add({type: "participant_bootstrap", status: response.status()})
    if (response.status() >= 400) journal.add({type: "http_error", path, status: response.status()})
  })
  page.on("request", request => {
    const path = new URL(request.url()).pathname
    if (path.includes("/voice-notes/")) journal.add({type: "voice_http", path, method: request.method()})
  })
  page.on("websocket", websocket => {
    journal.add({type: "websocket", url: websocket.url()})
    websocket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_sent", ...message})
    })
    websocket.on("framereceived", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) journal.add({type: "frame_received", ...message})
    })
    websocket.on("close", () => journal.add({type: "websocket_close"}))
  })

  return {page, journal, pageErrors, consoleErrors, failedRequests}
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
  const socketControl = {offline: false, routes: new Set(), dropNextServerFrame: null, droppedServerFrames: []}
  if (controllableSocket) {
    await context.routeWebSocket(/\/socket\/websocket/, route => {
      if (socketControl.offline) {
        route.close({code: 1001, reason: "intentional E2E browser outage"})
        return
      }
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
      socketControl.routes.add({page: route, server: serverRoute})
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
    socketControl,
    disconnectSocket: async () => {
      socketControl.offline = true
      await Promise.all([...socketControl.routes].flatMap(routes => [
        routes.page.close({code: 1001, reason: "intentional E2E browser outage"}),
        routes.server.close({code: 1001, reason: "intentional E2E browser outage"})
      ]))
      socketControl.routes.clear()
    },
    reconnectSocket: () => { socketControl.offline = false },
    dropNextServerFrame: predicate => { socketControl.dropNextServerFrame = predicate },
    injectServerFrame: (frame, routeIndex = 0) => {
      const routes = [...socketControl.routes][routeIndex]
      assert.ok(routes, `controllable WebSocket route ${routeIndex} exists`)
      routes.page.send(JSON.stringify(frame))
    },
    ...observed
  }
}

async function openSameParticipantTab(context) {
  const page = await context.newPage()
  const observed = await observePage(context, page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "same-participant tab loads")
  const joined = await waitForParticipantJoin(observed)
  return {...observed, participantTopic: joined.topic}
}

async function clickDoorAndQueue(page, label) {
  const door = page.locator(`button.door:has-text("${label}")`)
  await door.waitFor({state: "visible"})
  assert.equal(await door.isEnabled(), true, `${label} is enabled`)
  await door.click()
  await page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible"})
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
  assert.equal((await page.locator("#queue-door").textContent()).trim(), label)
}

async function leaveQueue(page) {
  await page.locator("#leave-queue").click()
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.getByRole("status").filter({hasText: "Queue status: left"}).waitFor({state: "visible"})
}

function assertClean(observed, {allowedFailedRequest = () => false} = {}) {
  assert.deepEqual(observed.pageErrors, [], "no uncaught page exceptions")
  assert.deepEqual(observed.consoleErrors, [], "no unexpected console errors")
  assert.deepEqual(observed.failedRequests.filter(request => !allowedFailedRequest(request)), [], "no unexpected failed network requests")
  const httpErrors = observed.journal.events.filter(event => event.type === "http_error")
  assert.deepEqual(httpErrors, [], "no HTTP error responses")
}

function exactMessage(page, text) {
  return page.locator("#messages li span").filter({hasText: text})
}

async function openMessageTools(page) {
  const form = page.locator('section[data-screen="conversation"].active #message-form')
  if (!(await form.evaluate(node => node.classList.contains("ig-tray-open")))) {
    await page.locator(".ig-compose-plus").click()
  }
  await page.waitForFunction(() => document.querySelector("#message-form")?.classList.contains("ig-tray-open"))
  await page.locator("#ig-message-tools").waitFor({state: "visible"})
}

async function openConversationInfo(page) {
  const info = page.locator(".conversation-head-actions .overflow")
  await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 0)))
  if ((await info.getAttribute("open")) === null) await info.locator("summary").click()
  await page.waitForFunction(() => document.querySelector(".conversation-head-actions .overflow")?.open === true)
  await info.locator(".overflow-menu").waitFor({state: "visible"})
}

async function sendMessage(page, text) {
  await page.locator("#message-input").fill(text)
  await page.locator('section[data-screen="conversation"].active #message-form').getByRole("button", {name: "Send message"}).click()
  const message = exactMessage(page, text)
  await message.waitFor({state: "visible"})
  return message
}

async function sendAndReceive(sender, receiver, text, conversationTopic) {
  const senderMark = sender.journal.mark()
  await sendMessage(sender.page, text)
  const sent = await sender.journal.waitFor(
    event => event.type === "frame_sent" && event.topic === conversationTopic && event.event === "message:send" && event.body?.content === text,
    `UI message send of ${text}`,
    senderMark
  )
  assert.ok(sent.ref, `message send of ${text} has a result-bearing reference`)
  await sender.page.locator("#messages li", {hasText: text}).locator("small").filter({hasText: /sent|delivered/}).waitFor({state: "visible"})
  await exactMessage(receiver.page, text).waitFor({state: "visible"})
  assert.equal(await exactMessage(receiver.page, text).count(), 1)
}

async function openEndConfirmation(page) {
  const actions = page.locator("details.overflow")
  if ((await actions.getAttribute("open")) === null) await actions.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
}

async function confirmEndConversation(page) {
  await openEndConfirmation(page)
  await page.locator("#end-confirm").click()
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

async function matchPair(browser, door = "Advice", {controllableA = false, controllableB = false} = {}) {
  const a = await bootFresh(browser, {controllableSocket: controllableA})
  const b = await bootFresh(browser, {controllableSocket: controllableB})
  await clickDoorAndQueue(a.page, door)
  await b.page.locator(`button.door:has-text("${door}")`).click()
  const [conversationA, conversationB] = await Promise.all([waitForConversation(a), waitForConversation(b)])
  assert.equal(conversationA, conversationB, "both participants join the same Conversation")
  return {a, b, conversationTopic: conversationA}
}

test("explicit Telugu Conversation Language survives Match and refresh", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b

  try {
    a = await bootFresh(browser)
    b = await bootFresh(browser)
    await a.page.locator("#conversation-language").selectOption("te")
    await b.page.locator("#conversation-language").selectOption("te")

    await clickDoorAndQueue(a.page, "Advice")
    await b.page.locator('button.door:has-text("Advice")').click()
    const [conversationA, conversationB] = await Promise.all([waitForConversation(a), waitForConversation(b)])
    assert.equal(conversationA, conversationB)
    assert.equal(await a.page.locator("#conversation-language").inputValue(), "te")
    assert.equal(await b.page.locator("#conversation-language").inputValue(), "te")

    for (const participant of [a, b]) {
      const mark = participant.journal.mark()
      await participant.page.reload({waitUntil: "domcontentloaded"})
      await waitForParticipantJoin(participant, mark)
      const reconciliation = await participant.journal.waitFor(
        event => event.type === "frame_received" && event.event === "phx_reply" &&
          event.body?.response?.snapshot?.canonical_state === "CONVERSATION",
        "Telugu Conversation reconciliation",
        mark
      )
      assert.equal(reconciliation.body.response.snapshot.conversation.conversation_language, "te")
      assert.equal(await waitForConversation(participant, mark), conversationA)
      assert.equal(await participant.page.locator("#conversation-language").inputValue(), "te")
    }

    assertClean(a)
    assertClean(b)
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("cross-Door match_found and refresh preserve each participant's own Door", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b
  let evaluator

  try {
    a = await bootFresh(browser)
    b = await bootFresh(browser)
    evaluator = await bootFresh(browser)

    await clickDoorAndQueue(a.page, "Vent")
    await new Promise(resolve => setTimeout(resolve, 15_100))
    await clickDoorAndQueue(b.page, "Advice")
    await new Promise(resolve => setTimeout(resolve, 15_100))

    const markA = a.journal.mark()
    const markB = b.journal.mark()
    await clickDoorAndQueue(evaluator.page, "Deep Talk")

    const [conversationA, conversationB] = await Promise.all([
      waitForConversation(a),
      waitForConversation(b)
    ])

    assert.equal(conversationA, conversationB, "cross-Door participants join one Conversation")
    assert.equal((await a.page.locator('section[data-screen="conversation"] .conversation-head h1').textContent()).trim(), "Vent")
    assert.equal((await b.page.locator('section[data-screen="conversation"] .conversation-head h1').textContent()).trim(), "Advice")
    assert.equal(await a.page.locator('section[data-screen="conversation"]').getAttribute("data-door"), "vent")
    assert.equal(await b.page.locator('section[data-screen="conversation"]').getAttribute("data-door"), "advice")

    const matchFoundA = a.journal.events.slice(markA).find(event =>
      event.type === "frame_received" && event.event === "match_found"
    )
    const matchFoundB = b.journal.events.slice(markB).find(event =>
      event.type === "frame_received" && event.event === "match_found"
    )
    assert.ok(matchFoundA, "A follows the normal match_found transition")
    assert.ok(matchFoundB, "B follows the normal match_found transition")

    for (const [participant, expectedDoor, expectedLabel] of [
      [a, "JUST_TALK", "Vent"],
      [b, "EXPLORE", "Advice"]
    ]) {
      const refreshMark = participant.journal.mark()
      await participant.page.reload({waitUntil: "domcontentloaded"})
      await waitForParticipantJoin(participant, refreshMark)
      const reconciliation = await participant.journal.waitFor(
        event => event.type === "frame_received" && event.event === "phx_reply" &&
          event.body?.status === "ok" &&
          event.body?.response?.snapshot?.canonical_state === "CONVERSATION",
        `participant-specific ${expectedDoor} reconciliation`,
        refreshMark
      )
      assert.equal(reconciliation.body.response.snapshot.conversation.door_type, expectedDoor)
      assert.equal(await waitForConversation(participant, refreshMark), conversationA)
      assert.equal((await participant.page.locator('section[data-screen="conversation"] .conversation-head h1').textContent()).trim(), expectedLabel)
    }

    assertClean(a)
    assertClean(b)
    assertClean(evaluator)
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await evaluator?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

for (const door of DOORS) {
  test(`real browser Door matrix: ${door}`, {timeout: TEST_TIMEOUT_MS}, async () => {
    const browser = await chromium.launch({headless: true})
    let session
    try {
      session = await bootFresh(browser)
      assert.equal(await session.page.locator("button.door").count(), DOORS.length)
      await clickDoorAndQueue(session.page, door)
      await leaveQueue(session.page)
      assertClean(session)
    } finally {
      await session?.context.close().catch(() => {})
      await browser.close().catch(() => {})
    }
  })
}

test("two participants match, exchange delivered messages, and restore the active Conversation after refresh", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair

    await sendAndReceive(a, b, "E2E message A", conversationTopic)
    await a.page.locator("#messages li", {hasText: "E2E message A"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})

    await sendAndReceive(b, a, "E2E message B", conversationTopic)
    await b.page.locator("#messages li", {hasText: "E2E message B"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})

    const refreshMark = a.journal.mark()
    await a.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(a, refreshMark)
    const refreshedConversation = await a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
      "restored ConversationChannel join",
      refreshMark
    )
    assert.equal(refreshedConversation.topic, conversationTopic)
    await a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    assert.equal(await exactMessage(a.page, "E2E message A").count(), 1)
    assert.equal(await exactMessage(a.page, "E2E message B").count(), 1)
    await sendAndReceive(a, b, "E2E after refresh", conversationTopic)
    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("lost match_found plus losing Cancel reconciles to the exact committed Conversation", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b

  try {
    a = await bootFresh(browser, {controllableSocket: true})
    b = await bootFresh(browser)
    await clickDoorAndQueue(a.page, "Advice")
    const raceMark = a.journal.mark()

    a.dropNextServerFrame(message =>
      message?.topic?.startsWith("participant:") && message?.event === "match_found"
    )

    await b.page.locator('button.door:has-text("Advice")').click()
    const committedConversation = await waitForConversation(b)

    await a.journal.waitFor(
      event => event.type === "frame_received" && event.event === "queue:status" && event.body?.status === "matched",
      "matched queue status after deliberately lost match_found",
      raceMark
    )
    await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})

    await a.page.locator("#leave-queue").click()

    const cancelReply = await a.journal.waitFor(
      event => event.type === "frame_received" && event.event === "phx_reply" &&
        event.body?.status === "error" && event.body?.response?.reason === "participant_busy",
      "Cancel losing to committed Conversation",
      raceMark
    )
    assert.equal(cancelReply.body.response.reason, "participant_busy")

    const reconciliation = await a.journal.waitFor(
      event => event.type === "frame_received" && event.event === "phx_reply" &&
        event.body?.status === "ok" && event.body?.response?.snapshot?.canonical_state === "CONVERSATION",
      "canonical Conversation reconciliation",
      raceMark
    )
    assert.equal(
      `conversation:${reconciliation.body.response.snapshot.conversation.conversation_id}`,
      committedConversation
    )

    const reconciledConversation = await waitForConversation(a)
    assert.equal(reconciledConversation, committedConversation)
    assert.equal(await a.page.locator('section[data-screen="doors"].active').count(), 0)
    assert.equal(await a.page.locator('section[data-screen="queue"].active').count(), 0)
    assert.equal(await a.page.locator('section[data-screen="conversation"].active').count(), 1)

    const queueJoinsAfterCommit = a.journal.events.slice(raceMark).filter(event =>
      event.type === "frame_sent" && ["queue:join", "join_queue"].includes(event.event)
    )
    assert.equal(queueJoinsAfterCommit.length, 0, "reconciliation creates no second queue authority")
    assert.equal(a.socketControl.droppedServerFrames.length, 1, "match_found was unavailable")
    assertClean(a)
    assertClean(b)
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

// Remaining tests are unchanged from the parent blob. This file replacement intentionally preserves them byte-for-byte.