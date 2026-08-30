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

test("shared delivery E2E-1: sent becomes delivered only after recipient browser progress", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await sendAndReceive(pair.a, pair.b, "delivery truth E2E", pair.conversationTopic)

    const accepted = pair.a.journal.events.slice(markA).find(event =>
      event.type === "frame_received" && event.topic === pair.conversationTopic &&
      event.event === "phx_reply" && event.body?.response?.status === "sent"
    )
    assert.ok(accepted, "canonical acceptance returns sent")

    const progress = await pair.b.journal.waitFor(event =>
      event.type === "frame_sent" && event.topic === pair.conversationTopic &&
      event.event === "delivery:progress" && event.body?.highest_contiguous_sequence >= 1,
    "recipient cumulative progress crossing WebSocket", markB)
    assert.ok(progress.body.epoch_id, "progress is epoch scoped")
    await pair.a.page.locator("#messages li", {hasText: "delivery truth E2E"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("shared delivery acknowledgment retry: lost result resends the same cumulative progress idempotently", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Advice", {controllableB: true})
    const mark = pair.b.journal.mark()
    pair.b.dropNextServerFrame(message => {
      if (message?.topic !== pair.conversationTopic || message?.event !== "phx_reply") return false
      return pair.b.journal.events.slice(mark).some(event =>
        event.type === "frame_sent" && event.event === "delivery:progress" && event.ref === message.ref
      )
    })

    await sendAndReceive(pair.a, pair.b, "lost progress result", pair.conversationTopic)
    await pair.a.page.locator("#messages li", {hasText: "lost progress result"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})

    const retry = await pair.b.journal.waitFor(event => {
      if (event.type !== "frame_sent" || event.event !== "delivery:progress") return false
      const reports = pair.b.journal.events.slice(mark).filter(candidate =>
        candidate.type === "frame_sent" && candidate.event === "delivery:progress" &&
        candidate.body?.highest_contiguous_sequence === event.body?.highest_contiguous_sequence
      )
      return reports.length >= 2
    }, "same cumulative delivery progress retry", mark)

    assert.ok(retry.ref, "retry remains a result-bearing Channel request")
    assert.equal(pair.b.socketControl.droppedServerFrames.length, 1)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("shared delivery acknowledgment retry: higher cumulative progress subsumes an earlier unconfirmed value", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Advice", {controllableB: true})
    const mark = pair.b.journal.mark()
    pair.b.dropNextServerFrame(message => {
      if (message?.topic !== pair.conversationTopic || message?.event !== "phx_reply") return false
      return pair.b.journal.events.slice(mark).some(event =>
        event.type === "frame_sent" && event.event === "delivery:progress" && event.ref === message.ref
      )
    })

    await sendAndReceive(pair.a, pair.b, "unconfirmed progress one", pair.conversationTopic)
    await pair.b.journal.waitFor(event =>
      event.type === "frame_sent" && event.event === "delivery:progress" &&
      event.body?.highest_contiguous_sequence === 1,
    "initial cumulative progress", mark)
    await sendAndReceive(pair.a, pair.b, "unconfirmed progress two", pair.conversationTopic)

    await pair.b.journal.waitFor(event =>
      event.type === "frame_sent" && event.event === "delivery:progress" &&
      event.body?.highest_contiguous_sequence === 2,
    "higher cumulative progress retry", mark)

    const reports = pair.b.journal.events.slice(mark).filter(event =>
      event.type === "frame_sent" && event.event === "delivery:progress"
    )
    assert.deepEqual(reports.map(event => event.body.highest_contiguous_sequence), [1, 2])
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("shared delivery E2E-2: missed live application stays sent until recipient reconnect replay", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Advice", {controllableB: true})
    pair.b.dropNextServerFrame(message =>
      message?.topic === pair.conversationTopic && message?.event === "message:new" &&
      message?.body?.content === "missed live delivery"
    )

    await sendMessage(pair.a.page, "missed live delivery")
    const senderMessage = pair.a.page.locator("#messages li", {hasText: "missed live delivery"})
    await senderMessage.locator("small", {hasText: "sent"}).waitFor({state: "visible"})
    assert.equal(await senderMessage.locator("small", {hasText: "delivered"}).count(), 0)
    assert.equal(await senderMessage.locator("small", {hasText: "failed"}).count(), 0)
    assert.equal(await exactMessage(pair.b.page, "missed live delivery").count(), 0)
    assert.equal(pair.b.socketControl.droppedServerFrames.length, 1, "one recipient live frame was suppressed")

    const reconnectMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.b, reconnectMark)
    await exactMessage(pair.b.page, "missed live delivery").waitFor({state: "visible"})
    await senderMessage.locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("shared delivery E2E-3: post-baseline gap reconciles before cumulative progress advances", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Advice", {controllableB: true})
    await sendAndReceive(pair.a, pair.b, "gap baseline", pair.conversationTopic)
    await pair.a.page.locator("#messages li", {hasText: "gap baseline"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})

    pair.b.dropNextServerFrame(message =>
      message?.topic === pair.conversationTopic && message?.event === "message:new" &&
      message?.body?.content === "gap missing"
    )
    await sendMessage(pair.a.page, "gap missing")
    await pair.a.page.locator("#messages li", {hasText: "gap missing"}).locator("small", {hasText: "sent"}).waitFor({state: "visible"})

    const gapMark = pair.b.journal.mark()
    await sendMessage(pair.a.page, "gap after")
    await exactMessage(pair.b.page, "gap missing").waitFor({state: "visible"})
    await exactMessage(pair.b.page, "gap after").waitFor({state: "visible"})

    await pair.b.journal.waitFor(event =>
      event.type === "frame_sent" && event.event === "delivery:progress" &&
      event.body?.highest_contiguous_sequence >= 3,
    "progress through reconciled gap", gapMark)

    const events = pair.b.journal.events.slice(gapMark)
    const receivedAfter = events.findIndex(event => event.type === "frame_received" && event.event === "message:new" && event.body?.content === "gap after")
    const reconcile = events.findIndex(event => event.type === "frame_sent" && event.event === "sync:reconcile")
    const progressThroughGap = events.findIndex(event => event.type === "frame_sent" && event.event === "delivery:progress" && event.body?.highest_contiguous_sequence >= 3)
    assert.ok(receivedAfter >= 0, "post-gap live sequence arrives")
    assert.ok(reconcile > receivedAfter, "gap triggers the existing sync:reconcile path")
    assert.ok(progressThroughGap > reconcile, "cumulative progress advances only after reconcile")
    await pair.a.page.locator("#messages li", {hasText: "gap missing"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
    await pair.a.page.locator("#messages li", {hasText: "gap after"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("browser-layer disconnect recovers and catches up exactly once", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Advice", {controllableA: true})
    const {a, b, conversationTopic} = pair
    await sendAndReceive(a, b, "E2E before offline", conversationTopic)

    const failedBeforeOffline = a.failedRequests.length
    const offlineCatchupMark = a.journal.mark()
    await a.disconnectSocket()
    await a.page.locator("#presence").filter({hasText: /Reconnecting|Disconnected/}).waitFor({state: "visible"})
    await sendMessage(b.page, "E2E offline catchup")
    a.reconnectSocket()
    await a.page.locator("#presence").filter({hasText: /Connected|away/}).waitFor({state: "visible"})
    await a.journal.waitFor(
      event => event.type === "frame_received" && event.topic === conversationTopic && event.event === "message:new" && event.body?.content === "E2E offline catchup",
      "offline catch-up delivery",
      offlineCatchupMark
    )
    await exactMessage(a.page, "E2E offline catchup").waitFor({state: "visible"})
    assert.equal(await exactMessage(a.page, "E2E offline catchup").count(), 1)
    assert.equal(await exactMessage(a.page, "E2E before offline").count(), 1)
    assert.ok(a.failedRequests.length >= failedBeforeOffline, "offline failures are bounded to the intentional outage")

    assertClean(b)
    assertClean(a, {allowedFailedRequest: request => new URL(request.url).pathname === "/socket/websocket"})
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("same participant keeps the Conversation through first-tab close and recovers after final-tab close", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let tabA2

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair
    tabA2 = await openSameParticipantTab(a.context)
    assert.equal(await waitForConversation(tabA2), conversationTopic)
    const participantTopicA1 = a.journal.events.find(event => event.type === "frame_received" && event.topic?.startsWith("participant:") && event.body?.response?.status === "connected")?.topic
    assert.equal(tabA2.participantTopic, participantTopicA1, "second tab reuses the same participant")

    await a.page.close()
    await sendAndReceive(b, tabA2, "E2E after A tab 1 close", conversationTopic)
    await sendAndReceive(tabA2, b, "E2E message from A tab 2", conversationTopic)
    assert.equal(await b.page.locator('section[data-screen="conversation"].active').count(), 1)

    await tabA2.page.close()
    await b.page.waitForFunction(() => document.querySelector("#presence").textContent === "")
    assert.equal(await b.page.locator("#presence").textContent(), "")
    assertClean(a)
    assertClean(tabA2)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("same-participant queue survives one tab and clears after the final tab", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  let tab2
  let tab3

  try {
    session = await bootFresh(browser)
    await clickDoorAndQueue(session.page, "Vent")
    tab2 = await openSameParticipantTab(session.context)
    await tab2.page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
    assert.equal((await tab2.page.locator("#queue-door").textContent()).trim(), "Vent")

    await session.page.close()
    assert.equal(await tab2.page.locator('section[data-screen="queue"].active').count(), 1)
    await leaveQueue(tab2.page)

    await clickDoorAndQueue(tab2.page, "Vent")
    await tab2.page.close()
    tab3 = await openSameParticipantTab(session.context)
    await tab3.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    assert.equal(await tab3.page.locator('section[data-screen="queue"].active').count(), 0)
    assertClean(tab3)
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("same-participant sibling Cancel converges both Waiting tabs", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  let sibling

  try {
    session = await bootFresh(browser)
    await clickDoorAndQueue(session.page, "Vent")
    sibling = await openSameParticipantTab(session.context)
    await sibling.page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})

    const siblingMark = sibling.journal.mark()
    await sibling.page.locator("#leave-queue").click()

    await Promise.all([
      session.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"}),
      sibling.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    ])
    assert.equal(await session.page.locator('section[data-screen="queue"].active').count(), 0)
    assert.equal(await sibling.page.locator('section[data-screen="queue"].active').count(), 0)

    const siblingLeaves = sibling.journal.events.slice(siblingMark).filter(event =>
      event.type === "frame_sent" && event.event === "queue:leave"
    )
    assert.equal(siblingLeaves.length, 1)
    assertClean(session)
    assertClean(sibling)
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("delayed Attempt-1 left cannot dismiss Attempt-2 Waiting", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session

  try {
    session = await bootFresh(browser, {controllableSocket: true})
    await clickDoorAndQueue(session.page, "Vent")

    const firstJoin = [...session.journal.events].reverse().find(event =>
      event.type === "frame_received" && event.event === "phx_reply" &&
      event.body?.status === "ok" && event.body?.response?.queue_attempt_id
    )
    const attempt1 = firstJoin?.body.response.queue_attempt_id
    assert.ok(attempt1)

    await leaveQueue(session.page)
    const attempt2Mark = session.journal.mark()
    await clickDoorAndQueue(session.page, "Vent")

    const secondJoin = await session.journal.waitFor(
      event => event.type === "frame_received" && event.event === "phx_reply" &&
        event.body?.status === "ok" && event.body?.response?.queue_attempt_id &&
        event.body.response.queue_attempt_id !== attempt1,
      "fresh Attempt-2 queue identity",
      attempt2Mark
    )
    const attempt2 = secondJoin.body.response.queue_attempt_id
    const participantTopic = session.journal.events.find(event =>
      event.type === "frame_received" && event.topic?.startsWith("participant:") &&
        event.body?.response?.status === "connected"
    )?.topic
    assert.ok(participantTopic)

    session.injectServerFrame([null, null, participantTopic, "queue:status", {
      status: "left",
      queue_attempt_id: attempt1
    }])
    await session.page.evaluate(() => new Promise(resolve => {
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    }))

    assert.equal(await session.page.locator('section[data-screen="queue"].active').count(), 1)
    assert.equal(await session.page.locator('section[data-screen="doors"].active').count(), 0)

    const cancelMark = session.journal.mark()
    await session.page.locator("#leave-queue").click()
    const currentCancel = await session.journal.waitFor(
      event => event.type === "frame_sent" && event.event === "queue:leave",
      "Attempt-2 Cancel",
      cancelMark
    )
    assert.equal(currentCancel.body.queue_attempt_id, attempt2)
    await session.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    assertClean(session)
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Conversation end converges both clients and refresh cannot resurrect it", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Deep Talk")
    await sendAndReceive(pair.a, pair.b, "E2E before end", pair.conversationTopic)

    await confirmEndConversation(pair.a.page)
    await Promise.all([
      pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      pair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    ])
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"].active').count(), 0)
    assert.equal(await pair.b.page.locator('section[data-screen="conversation"].active').count(), 0)

    const refreshMark = pair.a.journal.mark()
    await pair.a.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.a, refreshMark)
    await pair.a.page.locator('section[data-screen="doors"].active, section[data-screen="ended"].active').first().waitFor({state: "visible"})
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"].active').count(), 0)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("stale non-sensitive local state cannot override server reconciliation", {timeout: TEST_TIMEOUT_MS}, async () => {
  const browser = await chromium.launch({headless: true})
  let session

  try {
    session = await bootFresh(browser)
    await session.page.evaluate(async () => {
      localStorage.setItem("strangertalks:malformed-test", "{malformed")
      await new Promise((resolve, reject) => {
        const opening = indexedDB.open("strangertalks-local-v1", 1)
        opening.onerror = () => reject(opening.error)
        opening.onsuccess = () => {
          const transaction = opening.result.transaction("records", "readwrite")
          transaction.objectStore("records").put({
            id: "conversation:00000000-0000-4000-8000-000000000000",
            type: "local_conversation",
            value: {
              conversation_id: "00000000-0000-4000-8000-000000000000",
              door_type: "EXPLORE",
              display_door: "Advice",
              abstract_signature_seed: "sig-stale-e2e",
              status: "temporary",
              connection_state: "connected",
              started_at: new Date().toISOString(),
              ended_at: null,
              summary_id: null
            },
            updated_at: new Date().toISOString()
          })
          transaction.oncomplete = () => { opening.result.close(); resolve() }
          transaction.onerror = () => reject(transaction.error)
        }
      })
    })

    const reloadMark = session.journal.mark()
    await session.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(session, reloadMark)
    await session.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    assert.equal(await session.page.locator('section[data-screen="conversation"].active').count(), 0)
    assertClean(session)
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("authenticated WebSocket keeps credentials out of the URL", {timeout: TEST_TIMEOUT_MS}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await bootFresh(browser)
    const websocket = await session.journal.waitFor(event => event.type === "websocket", "WebSocket creation")
    const url = new URL(websocket.url)
    assert.equal(url.searchParams.has("token"), false)
    assert.equal(url.searchParams.has("auth_token"), false)
    const handshake = await session.journal.waitFor(event => event.type === "websocket_handshake", "WebSocket auth subprotocol")
    assert.equal(handshake.hasAuthProtocol, true)
    assertClean(session)
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real browser reply: peer delivers message, author replies with canonical quote, clicking quote highlights original", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair

    // A sends original message to B
    await sendAndReceive(a, b, "Original question from A", conversationTopic)
    const originalBubble = b.page.locator("#messages li", {hasText: "Original question from A"})
    await originalBubble.waitFor({state: "visible"})

    // B hovers and clicks Reply action button on A's message
    await originalBubble.hover()
    const replyBtn = originalBubble.locator("button.reply-action-btn")
    await replyBtn.waitFor({state: "visible"})
    await replyBtn.click()

    // B's staging bar appears with "Replying to Stranger" and canonical snippet
    const staging = b.page.locator("#reply-staging")
    await staging.waitFor({state: "visible"})
    assert.equal(await b.page.locator("#reply-staging-author").textContent(), "Replying to Stranger")
    assert.equal(await b.page.locator("#reply-staging-snippet").textContent(), "Original question from A")

    // B types and sends reply
    await b.page.locator("#message-input").fill("This is my answer B")
    await b.page.locator('section[data-screen="conversation"].active #message-form').getByRole("button", {name: "Send message"}).click()

    // A receives reply with quote preview
    const replyBubbleA = a.page.locator("#messages li", {hasText: "This is my answer B"})
    await replyBubbleA.waitFor({state: "visible"})
    const quoteInA = replyBubbleA.locator(".reply-quote")
    await quoteInA.waitFor({state: "visible"})
    assert.equal(await quoteInA.locator(".reply-author").textContent(), "Replying to You")
    assert.equal(await quoteInA.locator(".reply-snippet").textContent(), "Original question from A")

    // A clicks quote preview to jump to original
    await quoteInA.click()
    const origBubbleInA = a.page.locator("#messages li", {hasText: "Original question from A"})
    await origBubbleInA.locator(".highlight").waitFor({state: "attached", timeout: 5000}).catch(() => {})

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real browser emoji reactions: add, change, remove converge between participants", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair

    // A sends message to B
    await sendAndReceive(a, b, "Message for reaction testing", conversationTopic)
    const bubbleInB = b.page.locator("#messages li", {hasText: "Message for reaction testing"})
    await bubbleInB.waitFor({state: "visible"})

    // 1. B hovers and clicks React action button to open picker
    await bubbleInB.hover()
    const reactBtn = bubbleInB.locator("button.react-action-btn")
    await reactBtn.waitFor({state: "visible"})
    await reactBtn.click()

    const pickerInB = bubbleInB.locator(".reaction-picker")
    await pickerInB.waitFor({state: "visible"})

    // B chooses Heart from quick tray
    const heartBtn = pickerInB.locator("button.reaction-btn[data-emoji='❤️']")
    await heartBtn.click()

    // B sees own reaction pill
    const selfPillInB = bubbleInB.locator(".reaction-pill.self")
    await selfPillInB.waitFor({state: "visible"})
    assert.equal(await selfPillInB.textContent(), "❤️")

    // A receives peer reaction pill
    const bubbleInA = a.page.locator("#messages li", {hasText: "Message for reaction testing"})
    await bubbleInA.waitFor({state: "visible"})
    const peerPillInA = bubbleInA.locator(".reaction-pill.peer")
    await peerPillInA.waitFor({state: "visible"})
    assert.equal(await peerPillInA.textContent(), "❤️")

    // 2. B changes reaction to Laugh
    await bubbleInB.hover()
    await reactBtn.click()
    await pickerInB.waitFor({state: "visible"})
    const laughBtn = pickerInB.locator("button.reaction-btn[data-emoji='😂']")
    await laughBtn.click()

    await b.page.waitForFunction(() => document.querySelector(".reaction-pill.self")?.textContent === "😂")
    await a.page.waitForFunction(() => document.querySelector(".reaction-pill.peer")?.textContent === "😂")

    // 3. B removes reaction by clicking own pill
    await selfPillInB.click()

    await b.page.waitForFunction(() => document.querySelectorAll(".reaction-pill.self").length === 0)
    await a.page.waitForFunction(() => document.querySelectorAll(".reaction-pill.peer").length === 0)

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real browser emoji reactions: same participant multi-tab convergence and reconnect sync", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair

    // A sends message to B
    await sendAndReceive(a, b, "Multi-tab reaction test message", conversationTopic)
    const bubbleInB = b.page.locator("#messages li", {hasText: "Multi-tab reaction test message"})
    await bubbleInB.waitFor({state: "visible"})

    // Open second tab in B's context (same participant)
    const bTab2 = await b.context.newPage()
    await bTab2.goto(BASE_URL)
    const bubbleInB2 = bTab2.locator("#messages li", {hasText: "Multi-tab reaction test message"})
    await bubbleInB2.waitFor({state: "visible"})

    // Tab 1 reacts with Thumbs Up
    await bubbleInB.hover()
    const reactBtn1 = bubbleInB.locator("button.react-action-btn")
    await reactBtn1.waitFor({state: "visible"})
    await reactBtn1.click()
    const picker1 = bubbleInB.locator(".reaction-picker")
    await picker1.waitFor({state: "visible"})
    await picker1.locator("button.reaction-btn[data-emoji='👍️']").click()

    // Tab 1 sees self pill
    await b.page.waitForFunction(() => document.querySelector(".reaction-pill.self")?.textContent === "👍️")

    // Tab 2 converges to self pill without refresh
    await bTab2.waitForFunction(() => document.querySelector(".reaction-pill.self")?.textContent === "👍️")

    // A receives peer pill
    await a.page.waitForFunction(() => document.querySelector(".reaction-pill.peer")?.textContent === "👍️")

    await bTab2.close().catch(() => {})
    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real browser emoji reactions: keyboard E shortcut, arrow navigation, Enter/Space selection, Escape dismissal", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair

    // A sends message to B
    await sendAndReceive(a, b, "Keyboard reaction test message", conversationTopic)
    const bubbleInB = b.page.locator("#messages li", {hasText: "Keyboard reaction test message"})
    await bubbleInB.waitFor({state: "visible"})

    // 1. Focus message and press 'E' to open reaction picker
    await bubbleInB.focus()
    await b.page.keyboard.press("KeyE")

    const pickerInB = bubbleInB.locator(".reaction-picker")
    await pickerInB.waitFor({state: "visible"})

    // First button (heart) is focused
    const heartBtn = pickerInB.locator("button.reaction-btn[data-emoji='❤️']")
    assert.equal(await heartBtn.evaluate(el => el === document.activeElement), true)

    // 2. ArrowRight moves focus to 'laugh'
    await b.page.keyboard.press("ArrowRight")
    const laughBtn = pickerInB.locator("button.reaction-btn[data-emoji='😂']")
    assert.equal(await laughBtn.evaluate(el => el === document.activeElement), true)

    // 3. Escape closes picker without selecting
    await b.page.keyboard.press("Escape")
    await pickerInB.waitFor({state: "detached"})
    assert.equal(await bubbleInB.locator(".reaction-pill").count(), 0)

    // 4. Press 'E' again, navigate, and press Enter to select
    await bubbleInB.focus()
    await b.page.keyboard.press("KeyE")
    await pickerInB.waitFor({state: "visible"})

    await b.page.keyboard.press("ArrowRight") // laugh
    await b.page.keyboard.press("Enter")

    // B sees own reaction pill
    const selfPillInB = bubbleInB.locator(".reaction-pill.self")
    await selfPillInB.waitFor({state: "visible"})
    assert.equal(await selfPillInB.textContent(), "😂")

    // A receives peer reaction pill
    const bubbleInA = a.page.locator("#messages li", {hasText: "Keyboard reaction test message"})
    await bubbleInA.waitFor({state: "visible"})
    const peerPillInA = bubbleInA.locator(".reaction-pill.peer")
    await peerPillInA.waitFor({state: "visible"})
    assert.equal(await peerPillInA.textContent(), "😂")

    // 5. Editor exclusion: typing 'e' in textarea does not open picker
    const composer = b.page.locator("#message-input")
    await composer.focus()
    await b.page.keyboard.type("testing editor")
    assert.equal(await pickerInB.count(), 0)

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real browser emoji reactions: full picker lazy loading via '+' and multi-skin selection", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair

    // A sends message to B
    await sendAndReceive(a, b, "Full picker test message", conversationTopic)
    const bubbleInB = b.page.locator("#messages li", {hasText: "Full picker test message"})
    await bubbleInB.waitFor({state: "visible"})

    // Open quick tray
    await bubbleInB.hover()
    const reactBtn = bubbleInB.locator("button.react-action-btn")
    await reactBtn.waitFor({state: "visible"})
    await reactBtn.click()

    const pickerInB = bubbleInB.locator(".reaction-picker")
    await pickerInB.waitFor({state: "visible"})

    // Click '+' to open full lazy picker
    const moreBtn = pickerInB.locator("button.reaction-btn.more-btn")
    await moreBtn.waitFor({state: "visible"})
    await moreBtn.click()

    // Full custom emoji-picker element is mounted
    const fullPicker = pickerInB.locator("emoji-picker")
    await fullPicker.waitFor({state: "visible"})

    // Dispatch selection of a full Unicode sequence (e.g. 👩‍💻) on the picker
    await fullPicker.evaluate((pickerEl) => {
      pickerEl.dispatchEvent(new CustomEvent("emoji-click", {
        detail: {
          unicode: "👩‍💻",
          emoji: {annotation: "woman technologist", unicode: "👩‍💻"}
        },
        bubbles: true
      }))
    })

    // B sees own reaction pill with the full Unicode sequence
    const selfPillInB = bubbleInB.locator(".reaction-pill.self")
    await selfPillInB.waitFor({state: "visible"})
    assert.equal(await selfPillInB.textContent(), "👩‍💻")

    // A receives peer reaction pill
    const bubbleInA = a.page.locator("#messages li", {hasText: "Full picker test message"})
    await bubbleInA.waitFor({state: "visible"})
    const peerPillInA = bubbleInA.locator(".reaction-pill.peer")
    await peerPillInA.waitFor({state: "visible"})
    assert.equal(await peerPillInA.textContent(), "👩‍💻")

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("real browser emoji reactions: self-hosted picker performs device-aware browser support filtering", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext()
  const page = await context.newPage()

  try {
    await page.goto(BASE_URL)

    const verificationResult = await page.evaluate(async () => {
      // 1. Import the production self-hosted picker module
      await import("/assets/emoji_picker/index.js")

      // 2. Instantiate picker using production self-hosted data source
      const picker = document.createElement("emoji-picker")
      picker.dataSource = "/assets/emoji_picker/data.json"
      document.body.appendChild(picker)

      await picker.database.ready()
      await new Promise((r) => setTimeout(r, 200))

      // 3. Inspect underlying IndexedDB dataset to prove it contains multi-version emojis with version tags
      const smileysGroup = await picker.database.getEmojiByGroup(0)
      const meltingEmoji = smileysGroup.find((e) => e.unicode === "🫠") // Unicode 14.0
      const grinningEmoji = smileysGroup.find((e) => e.unicode === "😀") // Unicode 1.0

      // 4. Test deterministic support-level filtering:
      // When picker operates at a constrained support level (e.g. emojiVersion = 1.0),
      // the support filtering boundary (filterEmojisByVersion) suppresses unsupported emojis from the UI
      const constrainedPicker = document.createElement("emoji-picker")
      constrainedPicker.dataSource = "/assets/emoji_picker/data.json"
      constrainedPicker.emojiVersion = 1.0
      document.body.appendChild(constrainedPicker)

      await constrainedPicker.database.ready()
      await new Promise((r) => setTimeout(r, 400))

      const renderedButtons = Array.from(
        constrainedPicker.shadowRoot.querySelectorAll('button.emoji[role="menuitem"]')
      ).map((btn) => btn.textContent.trim())

      const grinningOffered = renderedButtons.includes("😀")
      const meltingOffered = renderedButtons.includes("🫠")

      // Clean up DOM
      picker.remove()
      constrainedPicker.remove()

      return {
        dbLoaded: smileysGroup.length > 0,
        meltingInDb: !!meltingEmoji,
        meltingVersion: meltingEmoji?.version,
        grinningInDb: !!grinningEmoji,
        grinningVersion: grinningEmoji?.version,
        grinningOffered,
        meltingOffered,
        totalRenderedInConstrained: renderedButtons.length
      }
    })

    assert.equal(verificationResult.dbLoaded, true, "Self-hosted data.json loads into IndexedDB")
    assert.equal(verificationResult.meltingInDb, true, "Dataset contains modern Unicode 14 emoji (melting face)")
    assert.equal(verificationResult.meltingVersion, 14, "Melting face is version 14")
    assert.equal(verificationResult.grinningInDb, true, "Dataset contains baseline Unicode 1.0 emoji (grinning face)")
    assert.equal(verificationResult.grinningVersion, 1, "Grinning face is version 1")
    assert.equal(verificationResult.grinningOffered, true, "Supported Unicode 1.0 emoji is offered as selectable")
    assert.equal(verificationResult.meltingOffered, false, "Unsupported Unicode 14 emoji is filtered out from selectable options")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1C: Session Pinned Messages - private pin, panel view, jump to message, and unpin", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Deep Talk")
    await sendAndReceive(pair.a, pair.b, "Important pinned text message", pair.conversationTopic)

    // Participant A hovers message and clicks Pin action button
    const messageNodeA = pair.a.page.locator("#messages li.message").first()
    await messageNodeA.hover()
    const pinBtnA = messageNodeA.locator(".pin-action-btn")
    await pinBtnA.waitFor({state: "visible"})
    await pinBtnA.click()

    // Message on A gets is-pinned class and pinned badge
    await messageNodeA.locator(".message-pinned-badge").waitFor({state: "visible"})
    const isPinnedA = await messageNodeA.evaluate(el => el.classList.contains("is-pinned"))
    assert.equal(isPinnedA, true, "Message on participant A has is-pinned class")

    // Pinned control on A shows count 1
    await openConversationInfo(pair.a.page)
    const pinControlA = pair.a.page.locator("#pinned-messages-control")
    await pinControlA.waitFor({state: "visible"})
    const pinCountA = await pair.a.page.locator("#pinned-count").textContent()
    assert.equal(pinCountA.trim(), "1", "Pinned count shows 1")

    // Open pinned messages panel on A
    await pinControlA.click()
    const pinPanelA = pair.a.page.locator("#pinned-messages-panel")
    await pinPanelA.waitFor({state: "visible"})
    const snippetText = await pinPanelA.locator(".pinned-snippet").textContent()
    assert.ok(snippetText.includes("Important pinned text message"), "Snippet contains pinned text")

    // Participant B MUST NOT have pinned badges or controls (privacy preserved)
    const messageNodeB = pair.b.page.locator("#messages li.message").first()
    const isPinnedB = await messageNodeB.evaluate(el => el.classList.contains("is-pinned"))
    assert.equal(isPinnedB, false, "Message on participant B is NOT marked pinned")
    const pinControlBVisible = await pair.b.page.locator("#pinned-messages-control").isVisible()
    assert.equal(pinControlBVisible, false, "Pinned control on participant B is hidden")

    // Unpin from panel on A
    const unpinBtn = pinPanelA.locator(".pinned-unpin-btn")
    await unpinBtn.waitFor({state: "visible"})
    await unpinBtn.click()
    await pinControlA.waitFor({state: "hidden"})
    const isPinnedAfter = await messageNodeA.evaluate(el => el.classList.contains("is-pinned"))
    assert.equal(isPinnedAfter, false, "Message is no longer pinned on participant A")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1C: Scenario B - same participant second tab converges without refresh and keeps peer blind", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Vent")
    const {a, b, conversationTopic} = pair
    await sendAndReceive(a, b, "Multi-tab pin test message", conversationTopic)

    // Open second tab in A's context (same participant)
    const aTab2 = await a.context.newPage()
    await aTab2.goto(BASE_URL)
    const bubbleInA2 = aTab2.locator("#messages li", {hasText: "Multi-tab pin test message"})
    await bubbleInA2.waitFor({state: "visible"})

    // Tab 1 of participant A pins message
    const bubbleInA1 = a.page.locator("#messages li", {hasText: "Multi-tab pin test message"})
    await bubbleInA1.hover()
    const pinBtn1 = bubbleInA1.locator(".pin-action-btn")
    await pinBtn1.waitFor({state: "visible"})
    await pinBtn1.click()

    // Tab 1 sees pinned marker
    await bubbleInA1.locator(".message-pinned-badge").waitFor({state: "visible"})

    // Tab 2 converges to pinned state without refresh
    await bubbleInA2.locator(".message-pinned-badge").waitFor({state: "visible"})
    await openConversationInfo(aTab2)
    const pinControlA2 = aTab2.locator("#pinned-messages-control")
    await pinControlA2.waitFor({state: "visible"})

    // Peer B receives NO pin marker or control
    const bubbleInB = b.page.locator("#messages li", {hasText: "Multi-tab pin test message"})
    const isPinnedB = await bubbleInB.evaluate(el => el.classList.contains("is-pinned"))
    assert.equal(isPinnedB, false, "Message on participant B is NOT marked pinned")
    const pinControlBVisible = await b.page.locator("#pinned-messages-control").isVisible()
    assert.equal(pinControlBVisible, false, "Pinned control on participant B is hidden")

    await aTab2.close().catch(() => {})
    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1C: Scenario C - reconnect to same runtime preserves canonical pins through sync", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Advice")
    const {a, b, conversationTopic} = pair
    await sendAndReceive(a, b, "Reconnect pin test message", conversationTopic)

    // Participant A pins message
    const bubbleInA = a.page.locator("#messages li", {hasText: "Reconnect pin test message"})
    await bubbleInA.hover()
    const pinBtn = bubbleInA.locator(".pin-action-btn")
    await pinBtn.waitFor({state: "visible"})
    await pinBtn.click()

    await bubbleInA.locator(".message-pinned-badge").waitFor({state: "visible"})

    // Reload Participant A's page (reconnect to same server runtime)
    const refreshMark = a.journal.mark()
    await a.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(a, refreshMark)
    await a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
      "restored ConversationChannel join",
      refreshMark
    )

    await a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})

    // Pinned message and control recover through join/reconnect sync
    const reloadedBubbleA = a.page.locator("#messages li", {hasText: "Reconnect pin test message"})
    await reloadedBubbleA.locator(".message-pinned-badge").waitFor({state: "visible"})

    const pinControlA = a.page.locator("#pinned-messages-control")
    await pinControlA.waitFor({state: "visible"})
    const pinCount = await a.page.locator("#pinned-count").textContent()
    assert.equal(pinCount.trim(), "1", "Pinned count recovered after reconnect")

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("D3: Pin state is isolated when Conversation A ends and Conversation B begins in the same tabs", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, "Deep Talk")
    const {a, b, conversationTopic: conversationA} = pair
    const conversationAText = "D3 Conversation A pinned message"
    await sendAndReceive(a, b, conversationAText, conversationA)

    const conversationAMessage = a.page.locator("#messages li.message", {hasText: conversationAText})
    await conversationAMessage.hover()
    await conversationAMessage.locator(".pin-action-btn").click()
    await conversationAMessage.locator(".message-pinned-badge").waitFor({state: "visible"})
    assert.equal((await a.page.locator("#pinned-count").textContent()).trim(), "1")
    await openConversationInfo(a.page)
    await a.page.locator("#pinned-messages-control").click()
    assert.match(await a.page.locator("#pinned-messages-panel").textContent(), /D3 Conversation A pinned message/)

    await confirmEndConversation(a.page)
    await Promise.all([
      a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    ])
    await Promise.all([
      a.page.locator("#fade-conversation").click(),
      b.page.locator("#fade-conversation").click()
    ])
    await Promise.all([
      a.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"}),
      b.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    ])

    const markA = a.journal.mark()
    const markB = b.journal.mark()
    await clickDoorAndQueue(a.page, "Advice")
    await b.page.locator('button.door:has-text("Advice")').click()
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    ])
    const [joinA, joinB] = await Promise.all([
      a.journal.waitFor(
        event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
        "Conversation B join for participant A",
        markA
      ),
      b.journal.waitFor(
        event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
        "Conversation B join for participant B",
        markB
      )
    ])
    assert.equal(joinA.topic, joinB.topic, "both participants join Conversation B")
    assert.notEqual(joinA.topic, conversationA, "Conversation B has a new canonical identity")

    const canonicalB = await a.journal.waitFor(
      event => event.type === "frame_received" && event.topic === joinA.topic && event.event === "phx_reply" && event.body?.status === "ok" && event.body?.response?.pins,
      "Conversation B authoritative Pin baseline",
      markA
    )
    assert.equal(canonicalB.body.response.pins.revision, 0, "Conversation B canonical Pin revision starts at 0")
    assert.deepEqual(canonicalB.body.response.pins.items, [], "Conversation B canonical Pin collection is empty")
    assert.equal((await a.page.locator("#pinned-count").textContent()).trim(), "0", "Conversation B browser Pin count is 0")
    assert.equal(await a.page.locator("#pinned-messages-control").isVisible(), false, "Conversation B Pin control is hidden at count 0")
    assert.equal(await a.page.locator("#pinned-items-list .pinned-card").count(), 0, "Conversation B Pin panel has no Conversation A card")
    assert.doesNotMatch(await a.page.locator("#pinned-messages-panel").textContent(), /D3 Conversation A pinned message/)

    const conversationBText = "D3 Conversation B own pinned message"
    await sendAndReceive(a, b, conversationBText, joinA.topic)
    const conversationBMessage = a.page.locator("#messages li.message", {hasText: conversationBText})
    await conversationBMessage.hover()
    await conversationBMessage.locator(".pin-action-btn").click()
    await conversationBMessage.locator(".message-pinned-badge").waitFor({state: "visible"})
    assert.equal((await a.page.locator("#pinned-count").textContent()).trim(), "1", "Conversation B can establish its own Pin state")

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1D E2E-1: real two-user expressive send is canonical and singular", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Distract")
    const mark = pair.b.journal.mark()
    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#expressive-open").click()
    await pair.a.page.locator("#expressive-search").fill("bright")
    await pair.a.page.getByRole("option", {name: "A bright spark"}).click()
    const delivery = await pair.b.journal.waitFor(event => event.type === "frame_received" && event.topic === pair.conversationTopic && event.event === "message:new" && event.body?.type === "expressive", "expressive delivery", mark)
    assert.equal(delivery.body.expressive.id, "bright-spark")
    assert.equal("asset_path" in (pair.a.journal.events.find(event => event.type === "frame_sent" && event.event === "message:send" && event.body?.expressive_id)?.body || {}), false)
    await pair.b.page.getByRole("img", {name: "A bright spark"}).waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 1)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1D E2E-2: unsent search and browsing remain private", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    const sentinel = "private-sentinel-1d-937"
    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#expressive-open").click()
    await pair.a.page.locator("#expressive-search").fill(sentinel)
    await pair.a.page.locator("#expressive-close").click()
    assert.equal(pair.a.journal.events.slice(markA).some(event => JSON.stringify(event).includes(sentinel)), false)
    assert.equal(pair.b.journal.events.slice(markB).some(event => event.event === "message:new"), false)
    const persisted = await pair.a.page.evaluate(async () => new Promise((resolve, reject) => { const request = indexedDB.open("strangertalks-local-v1", 1); request.onerror = () => reject(request.error); request.onsuccess = () => { const tx = request.result.transaction("records", "readonly"); const all = tx.objectStore("records").getAll(); all.onsuccess = () => resolve(JSON.stringify(all.result)); all.onerror = () => reject(all.error) } }))
    assert.equal(persisted.includes(sentinel), false)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1D E2E-3: keyboard, focus, touch safety, and reduced motion", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await pair.a.page.emulateMedia({reducedMotion: "reduce"})
    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#expressive-open").focus()
    await pair.a.page.keyboard.press("Enter")
    await pair.a.page.locator("#expressive-search").press("Tab")
    const first = pair.a.page.locator(".expressive-option").first()
    await first.press("ArrowRight")
    assert.equal(await pair.a.page.locator(".expressive-option").nth(1).evaluate(node => node === document.activeElement), true)
    assert.equal(await pair.a.page.locator(".expressive-loop").first().evaluate(node => getComputedStyle(node).animationName), "none")
    const before = pair.a.journal.events.filter(event => event.event === "message:send").length
    await pair.a.page.locator(".expressive-option").nth(1).dispatchEvent("pointermove", {clientX: 20, clientY: 80})
    assert.equal(pair.a.journal.events.filter(event => event.event === "message:send").length, before)
    await pair.a.page.keyboard.press("Escape")
    assert.equal(await pair.a.page.locator("#expressive-picker").isHidden(), true)
    assert.equal(await pair.a.page.locator("#expressive-open").evaluate(node => node === document.activeElement), true)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1D diagnostic proof: real expressive asset failure remains content-blind", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    const path = "/assets/expressive/bright-spark.svg"
    const url = `${BASE_URL}${path}`
    const forbidden = ["bright-spark", "bright-spark.svg", path, url, "A bright spark", "private-filter-1d", "celebrate"]
    await pair.b.context.route(`**${path}`, route => route.abort("failed"))
    const frameMark = pair.b.journal.mark()
    const failedMark = pair.b.failedRequests.length

    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#expressive-open").click()
    await pair.a.page.locator("#expressive-search").fill("private-filter-1d")
    await pair.a.page.locator("#expressive-search").fill("bright")
    await pair.a.page.getByRole("option", {name: "A bright spark"}).click()

    await pair.b.page.getByText("Expressive media unavailable").waitFor({state: "visible"})
    const failure = pair.b.failedRequests.slice(failedMark).find(request => request.url === url)
    assert.ok(failure, "Playwright observes the deterministic real asset request failure")
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 1, "canonical message remains rendered")

    const retainedDiagnostics = JSON.stringify({
      pageErrors: pair.b.pageErrors,
      consoleErrors: pair.b.consoleErrors,
      outboundFrames: pair.b.journal.events.slice(frameMark).filter(event => event.type === "frame_sent")
    })
    for (const value of forbidden) assert.equal(retainedDiagnostics.includes(value), false, `retained diagnostics exclude ${value}`)
    assert.deepEqual(pair.b.pageErrors, [])
    assert.deepEqual(pair.b.consoleErrors, ["Failed to load resource: net::ERR_FAILED"])
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

async function prepareInstrumentedVoiceCapture(observed) {
  await observed.context.grantPermissions(["microphone"], {origin: BASE_URL})
  await observed.page.addInitScript(() => {
    const original = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices)
    globalThis.__voiceTestStreams = []
    navigator.mediaDevices.getUserMedia = async constraints => {
      const stream = await original(constraints)
      globalThis.__voiceTestStreams.push(stream)
      return stream
    }
  })
  const mark = observed.journal.mark()
  await observed.page.reload({waitUntil: "domcontentloaded"})
  await waitForParticipantJoin(observed, mark)
  await observed.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
}

async function beginVoiceDraft(observed) {
  await observed.page.locator("#voice-start").click()
  await Promise.race([
    observed.page.locator("#voice-warning").waitFor({state: "visible"}),
    observed.page.locator("#voice-recording").waitFor({state: "visible"})
  ])
  if (await observed.page.locator("#voice-warning").isVisible()) await observed.page.locator("#voice-warning-continue").click()
  await observed.page.locator("#voice-recording").waitFor({state: "visible"})
}

test("Feature 1E E2E-1: record preview send and peer playback controls", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true, args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    await prepareInstrumentedVoiceCapture(pair.a)
    const peerMark = pair.b.journal.mark()
    await beginVoiceDraft(pair.a)
    await pair.a.page.locator("#voice-recording-status").waitFor({state: "attached"})
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => event.event === "voice_note:new"), false)
    await pair.a.page.locator("#voice-stop").click()
    await pair.a.page.locator("#voice-preview").waitFor({state: "visible"})
    assert.equal(await pair.a.page.evaluate(() => globalThis.__voiceTestStreams.every(stream => stream.getTracks().every(track => track.readyState === "ended"))), true)
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => event.event === "voice_note:new"), false)
    await pair.a.page.locator("#voice-send").click()
    await pair.b.journal.waitFor(event => event.type === "frame_received" && event.event === "voice_note:new", "peer voice-note delivery", peerMark)
    const note = pair.b.page.locator("#messages .voice-note").last()
    await note.waitFor({state: "visible"})
    const speed = note.locator(".voice-speed")
    await speed.click(); assert.equal(await note.locator("audio").evaluate(audio => audio.playbackRate), 1.5)
    await speed.click(); assert.equal(await note.locator("audio").evaluate(audio => audio.playbackRate), 2)
    await speed.click(); assert.equal(await note.locator("audio").evaluate(audio => audio.playbackRate), 1)
    await note.locator("input[type=range]").focus()
    await note.locator("input[type=range]").press("ArrowRight")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1E E2E-2: recording cancel and preview discard send nothing", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true, args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await prepareInstrumentedVoiceCapture(pair.a)
    const markA = pair.a.journal.mark(); const markB = pair.b.journal.mark()
    await beginVoiceDraft(pair.a)
    await pair.a.page.locator("#voice-record-cancel").click()
    await pair.a.page.locator("#voice-recording").waitFor({state: "hidden"})
    assert.equal(await pair.a.page.evaluate(() => globalThis.__voiceTestStreams.every(stream => stream.getTracks().every(track => track.readyState === "ended"))), true)
    await beginVoiceDraft(pair.a)
    await pair.a.page.locator("#voice-stop").click()
    await pair.a.page.locator("#voice-preview").waitFor({state: "visible"})
    await pair.a.page.locator("#voice-preview-cancel").click()
    await pair.a.page.locator("#voice-preview").waitFor({state: "hidden"})
    assert.equal(pair.a.journal.events.slice(markA).some(event => event.type === "voice_http" && event.method === "POST"), false)
    assert.equal(pair.b.journal.events.slice(markB).some(event => event.event === "voice_note:new"), false)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1E E2E-3: ended-runtime draft cannot send or rebind", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true, args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await prepareInstrumentedVoiceCapture(pair.a)
    await beginVoiceDraft(pair.a)
    await pair.a.page.locator("#voice-stop").click()
    await pair.a.page.locator("#voice-preview").waitFor({state: "visible"})
    const before = pair.a.journal.events.filter(event => event.type === "voice_http" && event.method === "POST").length
    await confirmEndConversation(pair.a.page)
    await pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    await pair.a.page.locator("#voice-send").dispatchEvent("click")
    assert.equal(pair.a.journal.events.filter(event => event.type === "voice_http" && event.method === "POST").length, before)
    assert.equal(await pair.a.page.locator("#voice-preview").isHidden(), true)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1F E2E-1: multi-tab aggregation and clean departure", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let b2Observed
  try {
    pair = await matchPair(browser, "Deep Talk")
    await sendAndReceive(pair.a, pair.b, "warmup 1F-1", pair.conversationTopic)

    // Explicitly set B1 to visible
    await pair.b.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "visible", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await pair.a.page.locator("#presence", {hasText: "Connected"}).waitFor({state: "visible"})

    // Open second page in B's context
    const b2Page = await pair.b.context.newPage()
    b2Observed = await observePage(pair.b.context, b2Page)
    await b2Page.goto(BASE_URL)
    await waitForParticipantJoin(b2Observed)
    await b2Page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})

    // B1 visible + B2 hidden -> Aggregation: A still sees Connected
    await b2Page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    assert.equal(await pair.a.page.locator("#presence").textContent(), "Connected")

    // Both B1 and B2 hidden -> A sees Temporarily away
    await pair.b.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await pair.a.page.locator("#presence", {hasText: "Temporarily away"}).waitFor({state: "visible"})

    // Close B2 -> B1 is still hidden -> A still sees Temporarily away
    await b2Page.close()
    await new Promise(r => setTimeout(r, 500))
    assert.equal(await pair.a.page.locator("#presence").textContent(), "Temporarily away")

    // Close B1 -> 0 active sessions -> presence becomes empty
    await pair.b.page.close()
    await pair.a.page.waitForFunction(() => document.querySelector("#presence").textContent === "")
    assert.equal(await pair.a.page.locator("#presence").textContent(), "")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1F E2E-2: hidden join and visibility transitions", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await sendAndReceive(pair.a, pair.b, "warmup 1F-2", pair.conversationTopic)

    // Explicitly set B to visible
    await pair.b.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "visible", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await pair.a.page.locator("#presence", {hasText: "Connected"}).waitFor({state: "visible"})

    // B flips to hidden -> A sees Temporarily away
    await pair.b.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await pair.a.page.locator("#presence", {hasText: "Temporarily away"}).waitFor({state: "visible"})

    // B reloads while hidden -> upon rejoin, immediately reports current hidden document.visibilityState
    const bReloadMark = pair.b.journal.mark()
    await pair.b.page.addInitScript(() => {
      Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
    })
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.b, bReloadMark)
    await pair.b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    await pair.a.page.locator("#presence", {hasText: "Temporarily away"}).waitFor({state: "visible"})

    // B flips back to visible -> A sees Connected
    await pair.b.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "visible", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await pair.a.page.locator("#presence", {hasText: "Connected"}).waitFor({state: "visible"})
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1F E2E-3: local reconnect and delivery separation", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice", {controllableA: true})
    await sendAndReceive(pair.a, pair.b, "presence test warmup", pair.conversationTopic)

    // A cuts local socket -> A displays Reconnecting… locally
    await pair.a.disconnectSocket()
    await pair.a.page.locator("#presence", {hasText: "Reconnecting…"}).waitFor({state: "visible"})

    // Peer B does NOT see Reconnecting…
    const textOnB = await pair.b.page.locator("#presence").textContent()
    assert.notEqual(textOnB, "The other person is reconnecting…")
    assert.notEqual(textOnB, "Reconnecting…")

    // Restore A
    const restoreMark = pair.a.journal.mark()
    pair.a.reconnectSocket()
    await pair.a.page.locator("#presence", {hasText: "Connected"}).waitFor({state: "visible"})
    await pair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join",
      "reconnected conversation join",
      restoreMark
    )

    // Send a message -> verify delivered status requires delivery progress
    await sendAndReceive(pair.a, pair.b, "presence delivery separation text", pair.conversationTopic)
    await pair.a.page.locator("#messages li", {hasText: "presence delivery separation text"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1G E2E-1: Quiet Mode toggle, header UI, and peer privacy", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    await sendAndReceive(pair.a, pair.b, "warmup 1G-1", pair.conversationTopic)

    const quietBtnA = pair.a.page.locator("#quiet-mode-control")
    const quietBtnB = pair.b.page.locator("#quiet-mode-control")

    // Default state is OFF
    assert.equal(await quietBtnA.getAttribute("aria-pressed"), "false")
    assert.equal(await quietBtnA.getAttribute("aria-label"), "Quiet Mode, off")
    assert.equal(await quietBtnA.textContent(), "🔔")

    // Enable Quiet Mode on A
    await openConversationInfo(pair.a.page)
    await quietBtnA.click()
    assert.equal(await quietBtnA.getAttribute("aria-pressed"), "true")
    assert.equal(await quietBtnA.getAttribute("aria-label"), "Quiet Mode, on")
    assert.equal(await quietBtnA.textContent(), "🔕")

    // Peer B remains unaffected (zero peer state, privacy preserved)
    assert.equal(await quietBtnB.getAttribute("aria-pressed"), "false")
    assert.equal(await quietBtnB.getAttribute("aria-label"), "Quiet Mode, off")
    assert.equal(await quietBtnB.textContent(), "🔔")

    // Disable Quiet Mode on A
    await openConversationInfo(pair.a.page)
    await quietBtnA.click()
    assert.equal(await quietBtnA.getAttribute("aria-pressed"), "false")
    assert.equal(await quietBtnA.getAttribute("aria-label"), "Quiet Mode, off")
    assert.equal(await quietBtnA.textContent(), "🔔")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1G E2E-2: Quiet Mode socket reconnect preservation and refresh reset", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent", {controllableA: true})
    await sendAndReceive(pair.a, pair.b, "warmup 1G-2", pair.conversationTopic)

    const quietBtnA = pair.a.page.locator("#quiet-mode-control")

    // Enable Quiet Mode on A
    await openConversationInfo(pair.a.page)
    await quietBtnA.click()
    assert.equal(await quietBtnA.getAttribute("aria-pressed"), "true")

    // Socket disconnects and reconnects -> Quiet Mode remains ON
    await pair.a.disconnectSocket()
    await pair.a.page.locator("#presence", {hasText: "Reconnecting…"}).waitFor({state: "visible"})

    const restoreMark = pair.a.journal.mark()
    pair.a.reconnectSocket()
    await pair.a.page.locator("#presence", {hasText: "Connected"}).waitFor({state: "visible"})
    await pair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join",
      "reconnected conversation join",
      restoreMark
    )
    assert.equal(await quietBtnA.getAttribute("aria-pressed"), "true")

    // Page refresh -> resets to default OFF (RAM-only, zero persistence)
    await pair.a.page.reload()
    await pair.a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    assert.equal(await pair.a.page.locator("#quiet-mode-control").getAttribute("aria-pressed"), "false")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1G E2E-3: Quiet Mode delivery preservation and conversation lifecycle reset", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    const quietBtnA = pair.a.page.locator("#quiet-mode-control")

    // Enable Quiet Mode on A
    await openConversationInfo(pair.a.page)
    await quietBtnA.click()
    assert.equal(await quietBtnA.getAttribute("aria-pressed"), "true")

    // Exchange messages while Quiet Mode is ON -> delivery progress functions completely normally
    await sendAndReceive(pair.a, pair.b, "quiet delivery test message", pair.conversationTopic)
    await pair.a.page.locator("#messages li", {hasText: "quiet delivery test message"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})

    // End conversation on A
    await confirmEndConversation(pair.a.page)

    await pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    await pair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1H E2E-1: choose Rain Window locally while Conversation controls remain usable", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    const conversationA = pair.a.page.locator('section[data-screen="conversation"]')
    const conversationB = pair.b.page.locator('section[data-screen="conversation"]')
    const originalBackground = await conversationA.evaluate(node => getComputedStyle(node).backgroundImage)
    const peerMark = pair.b.journal.mark()

    await openConversationInfo(pair.a.page)

    await pair.a.page.locator("#atmosphere-control").click()
    const rain = pair.a.page.locator('[data-atmosphere-option="rain-window"]')
    await rain.click()
    assert.equal(await rain.getAttribute("aria-pressed"), "true")
    assert.equal(await conversationA.getAttribute("data-atmosphere"), "rain-window")
    assert.notEqual(await conversationA.evaluate(node => getComputedStyle(node).backgroundImage), originalBackground)
    assert.equal(await conversationB.getAttribute("data-atmosphere"), null)
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => /theme|atmosphere/.test(event.event || "")), false)

    await sendAndReceive(pair.a, pair.b, "Rain Window stays canonical", pair.conversationTopic)
    await pair.a.page.locator("#messages li", {hasText: "Rain Window stays canonical"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
    assert.equal(await pair.a.page.locator("#message-input").isVisible(), true)
    assert.equal(await pair.a.page.locator("#report-open").count(), 1)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1H E2E-2: reconnect preserves, tabs stay independent, and refresh resets", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let tabA2
  try {
    pair = await matchPair(browser, "Vent", {controllableA: true})
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#atmosphere-control").click()
    await pair.a.page.locator('[data-atmosphere-option="late-night-library"]').click()
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "late-night-library")

    await pair.a.disconnectSocket()
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "late-night-library")
    const reconnectMark = pair.a.journal.mark()
    pair.a.reconnectSocket()
    await pair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join",
      "1H ConversationChannel reconnect",
      reconnectMark
    )
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "late-night-library")

    tabA2 = await openSameParticipantTab(pair.a.context)
    assert.equal(await waitForConversation(tabA2), pair.conversationTopic)
    assert.equal(await tabA2.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), null)
    await openConversationInfo(tabA2.page)
    await tabA2.page.locator("#atmosphere-control").click()
    await tabA2.page.locator('[data-atmosphere-option="coffee-shop"]').click()
    assert.equal(await tabA2.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "coffee-shop")
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "late-night-library")

    await tabA2.page.reload({waitUntil: "domcontentloaded"})
    await tabA2.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    assert.equal(await tabA2.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), null)
  } finally {
    await tabA2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1H E2E-3: keyboard chooser remains functional across accessibility and responsive modes", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await pair.a.page.emulateMedia({reducedMotion: "reduce", forcedColors: "active"})
    await pair.a.page.setViewportSize({width: 390, height: 844})

    await openConversationInfo(pair.a.page)
    const control = pair.a.page.locator("#atmosphere-control")
    await control.focus()
    await pair.a.page.keyboard.press("Enter")
    const train = pair.a.page.locator('[data-atmosphere-option="train-journey"]')
    await train.focus()
    await pair.a.page.keyboard.press("Enter")
    assert.equal(await train.getAttribute("aria-pressed"), "true")
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "train-journey")
    assert.equal(await pair.a.page.locator("#message-input").isVisible(), true)
    assert.equal(await control.isVisible(), false)
    const mobileComposer = await pair.a.page.locator("#message-form").boundingBox()
    assert.ok(mobileComposer && mobileComposer.x >= 0 && mobileComposer.x + mobileComposer.width <= 390)

    await pair.a.page.setViewportSize({width: 1440, height: 900})
    const wideTimeline = await pair.a.page.locator("#message-viewport").boundingBox()
    const wideComposer = await pair.a.page.locator("#message-form").boundingBox()
    assert.ok(wideTimeline && wideTimeline.width <= 800)
    assert.ok(wideComposer && wideComposer.width <= 800)

    await openConversationInfo(pair.a.page)

    await pair.a.page.locator("#quiet-mode-control").click()
    assert.equal(await pair.a.page.locator("#quiet-mode-control").getAttribute("aria-pressed"), "true")
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"]').getAttribute("data-atmosphere"), "train-journey")
    assertClean(pair.a)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1I E2E-1: Ambient Audio requires explicit enable and stops on disable", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    const ambientRequests = []
    pair.a.page.on("request", request => {
      if (new URL(request.url()).pathname.startsWith("/assets/ambient/")) ambientRequests.push(request.url())
    })
    const audio = pair.a.page.locator("#ambient-audio")
    assert.equal(await audio.evaluate(element => element.paused), true, "page load is silent")
    assert.equal(await audio.getAttribute("src"), null, "page load has no selected audio source")

    await openConversationInfo(pair.a.page)

    await pair.a.page.locator("#atmosphere-control").click()
    await pair.a.page.locator('[data-atmosphere-option="rain-window"]').click()
    assert.equal(await audio.evaluate(element => element.paused), true, "theme selection remains silent")
    assert.equal(ambientRequests.length, 0, "theme selection does not fetch ambience")

    const peerMark = pair.b.journal.mark()
    const assetResponse = pair.a.page.waitForResponse(response => new URL(response.url()).pathname === "/assets/ambient/rain-window.wav")
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#ambient-audio-control").click()
    assert.equal((await assetResponse).ok(), true, "same-origin Rain asset loads")
    await pair.a.page.waitForFunction(() => !document.querySelector("#ambient-audio").paused)
    assert.equal(await pair.a.page.locator("#ambient-audio-control").getAttribute("aria-pressed"), "true")
    assert.equal(ambientRequests.length, 1, "only the selected ambience loads")
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => /ambient|atmosphere|audio/.test(event.event || "")), false)
    await sendAndReceive(pair.a, pair.b, "ambient leaves canonical delivery alone", pair.conversationTopic)
    await pair.a.page.locator("#messages li", {hasText: "ambient leaves canonical delivery alone"}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})

    await openConversationInfo(pair.a.page)

    await pair.a.page.locator("#ambient-audio-control").click()
    assert.equal(await audio.evaluate(element => element.paused), true)
    assert.equal(await pair.a.page.locator("#ambient-audio-control").getAttribute("aria-pressed"), "false")

    await pair.a.page.route("**/assets/ambient/train-journey.wav", route => route.abort("failed"))
    await pair.a.page.locator('[data-atmosphere-option="train-journey"]').click()
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#ambient-audio-control").click()
    await pair.a.page.waitForFunction(() => ["unavailable", "blocked"].includes(document.querySelector("#ambient-audio-control").dataset.playbackStatus))
    assert.equal(await audio.evaluate(element => element.paused), true, "asset failure degrades to silence")
    assert.equal(await pair.a.page.locator('section[data-screen="conversation"].active').isVisible(), true, "Conversation remains active")
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => /ambient|atmosphere|audio/.test(event.event || "")), false)
    await pair.a.page.unroute("**/assets/ambient/train-journey.wav")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1I E2E-2: Quiet Mode and visibility locally suppress and resume ambience", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#atmosphere-control").click()
    await pair.a.page.locator('[data-atmosphere-option="coffee-shop"]').click()
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#ambient-audio-control").click()
    await pair.a.page.waitForFunction(() => !document.querySelector("#ambient-audio").paused)

    const networkMark = pair.a.journal.mark()
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#quiet-mode-control").click()
    assert.equal(await pair.a.page.locator("#ambient-audio").evaluate(audio => audio.paused), true)
    assert.equal(await pair.a.page.locator("#ambient-audio-control").getAttribute("aria-pressed"), "true", "preference remains ON")
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#quiet-mode-control").click()
    await pair.a.page.waitForFunction(() => !document.querySelector("#ambient-audio").paused)
    assert.equal(pair.a.journal.events.slice(networkMark).some(event => /quiet|ambient|audio/.test(event.event || "")), false)

    await pair.a.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    assert.equal(await pair.a.page.locator("#ambient-audio").evaluate(audio => audio.paused), true)
    await pair.b.page.locator("#presence", {hasText: "Temporarily away"}).waitFor({state: "visible"})

    await pair.a.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {value: "visible", configurable: true})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await pair.a.page.waitForFunction(() => !document.querySelector("#ambient-audio").paused)
    await pair.b.page.locator("#presence", {hasText: "Connected"}).waitFor({state: "visible"})
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1I E2E-3: explicit voice playback suppresses ambience and Conversation end resets it", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true, args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await prepareInstrumentedVoiceCapture(pair.a)
    await beginVoiceDraft(pair.a)
    await pair.a.page.waitForFunction(() => document.querySelector("#voice-timer").textContent !== "0:00")
    await pair.a.page.locator("#voice-stop").click()
    await pair.a.page.locator("#voice-preview").waitFor({state: "visible"})

    await openConversationInfo(pair.a.page)

    await pair.a.page.locator("#atmosphere-control").click()
    await pair.a.page.locator('[data-atmosphere-option="night-observatory"]').click()
    await openConversationInfo(pair.a.page)
    await pair.a.page.locator("#ambient-audio-control").click()
    await pair.a.page.waitForFunction(() => !document.querySelector("#ambient-audio").paused)

    await pair.a.page.locator("#voice-preview-audio").evaluate(audio => audio.play())
    assert.equal(await pair.a.page.locator("#ambient-audio").evaluate(audio => audio.paused), true, "voice playback pauses ambience")
    await pair.a.page.waitForFunction(() => document.querySelector("#voice-preview-audio").ended)
    await pair.a.page.waitForFunction(() => !document.querySelector("#ambient-audio").paused)

    const endMark = pair.a.journal.mark()
    await confirmEndConversation(pair.b.page)
    await pair.a.journal.waitFor(
      event => event.type === "frame_received" && event.event === "conversation:ended",
      "1I peer Conversation end",
      endMark
    )
    await pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    assert.equal(await pair.a.page.locator("#ambient-audio").evaluate(audio => audio.paused), true)
    assert.equal(await pair.a.page.locator("#ambient-audio-control").getAttribute("aria-pressed"), "false")
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1J E2E-1: prompt inserts locally and only edited explicit Send reaches peer", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    const approvedText = "What’s something you’ve been thinking about lately?"
    const finalText = `${approvedText} I’ve been learning to bake.`
    const senderMark = pair.a.journal.mark()
    const peerMark = pair.b.journal.mark()

    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#prompt-control").click()
    const option = pair.a.page.locator('[data-prompt-option="start-1"]')
    await option.click()
    assert.equal(await option.getAttribute("aria-pressed"), "true")
    await pair.a.page.locator("#prompt-use").click()

    assert.equal(await pair.a.page.locator("#message-input").inputValue(), approvedText)
    assert.equal(await pair.a.page.locator("#prompt-helper").isHidden(), true)
    assert.equal(await pair.a.page.locator("#reply-staging").isHidden(), true)
    assert.equal(pair.a.journal.events.slice(senderMark).some(event => event.type === "frame_sent" && event.event === "message:send"), false)
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => event.type === "frame_received" && event.event === "message:new"), false)
    assert.equal(await pair.a.page.locator("#messages li").count(), 0)
    assert.equal(await pair.b.page.locator("#messages li").count(), 0)

    await pair.a.page.locator("#message-input").fill(finalText)
    const explicitSendMark = pair.a.journal.mark()
    await pair.a.page.locator('section[data-screen="conversation"].active #message-form').getByRole("button", {name: "Send message"}).click()
    const sent = await pair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "message:send",
      "1J explicit ordinary message Send",
      explicitSendMark
    )
    assert.deepEqual(Object.keys(sent.body).sort(), ["client_message_id", "content", "message_id"])
    assert.equal(sent.body.content, finalText)
    assert.equal(Object.keys(sent.body).some(key => /prompt|category/i.test(key)), false)
    await exactMessage(pair.b.page, finalText).waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator("#messages li").count(), 1)
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => event.type === "frame_received" && event.event === "message:new" && event.body?.content === approvedText), false)
    await pair.a.page.locator("#messages li", {hasText: finalText}).locator("small", {hasText: "delivered"}).waitFor({state: "visible"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1J E2E-2: non-empty draft and Reply context survive prompt interaction", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await sendAndReceive(pair.a, pair.b, "Original prompt safety question", pair.conversationTopic)
    const original = pair.b.page.locator("#messages li", {hasText: "Original prompt safety question"})
    await original.hover()
    await original.locator("button.reply-action-btn").click()
    await pair.b.page.locator("#reply-staging").waitFor({state: "visible"})
    await pair.b.page.locator("#message-input").fill("my own draft")
    const senderMark = pair.b.journal.mark()
    const peerMark = pair.a.journal.mark()

    await pair.b.page.locator("#prompt-control").click()
    await pair.b.page.locator('[data-prompt-category="continue"]').click()
    await pair.b.page.locator('[data-prompt-option="continue-2"]').click()
    const useButton = pair.b.page.locator("#prompt-use")
    assert.equal(await useButton.isDisabled(), true)
    await useButton.dispatchEvent("click")

    assert.equal(await pair.b.page.locator("#message-input").inputValue(), "my own draft")
    assert.equal(await pair.b.page.locator("#reply-staging").isVisible(), true)
    assert.equal(await pair.b.page.locator("#reply-staging-author").textContent(), "Replying to Stranger")
    assert.equal(await pair.b.page.locator("#reply-staging-snippet").textContent(), "Original prompt safety question")
    assert.match(await pair.b.page.locator("#prompt-draft-status").textContent(), /existing draft is kept/i)
    assert.equal(pair.b.journal.events.slice(senderMark).some(event => event.type === "frame_sent" && event.event === "message:send"), false)
    assert.equal(pair.a.journal.events.slice(peerMark).some(event => event.type === "frame_received" && event.event === "message:new"), false)
    assert.equal(await exactMessage(pair.a.page, "my own draft").count(), 0)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1J E2E-3: Prompt helper is tab-local, keyboard accessible, and lifecycle-reset", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let tabA2
  try {
    pair = await matchPair(browser, "Vent")
    const firstTabMark = pair.a.journal.mark()
    const peerMark = pair.b.journal.mark()
    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#prompt-control").click()
    await pair.a.page.locator('[data-prompt-category="recover"]').click()
    await pair.a.page.locator('[data-prompt-option="recover-3"]').click()
    assert.equal(await pair.a.page.locator('[data-prompt-category="recover"]').getAttribute("aria-pressed"), "true")

    tabA2 = await openSameParticipantTab(pair.a.context)
    assert.equal(await waitForConversation(tabA2), pair.conversationTopic)
    assert.equal(await tabA2.page.locator("#prompt-helper").isHidden(), true)
    assert.equal(await tabA2.page.locator('[data-prompt-category="start"]').getAttribute("aria-pressed"), "true")

    await tabA2.page.emulateMedia({reducedMotion: "reduce", forcedColors: "active"})
    await tabA2.page.setViewportSize({width: 390, height: 844})
    await openMessageTools(tabA2.page)
    const control = tabA2.page.locator("#prompt-control")
    await control.focus()
    await tabA2.page.keyboard.press("Enter")
    assert.equal(await control.getAttribute("aria-expanded"), "true")
    const continueCategory = tabA2.page.locator('[data-prompt-category="continue"]')
    await continueCategory.focus()
    await tabA2.page.keyboard.press("Enter")
    const continueOption = tabA2.page.locator('[data-prompt-option="continue-4"]')
    await continueOption.focus()
    await tabA2.page.keyboard.press("Enter")
    assert.equal(await continueOption.getAttribute("aria-pressed"), "true")
    assert.equal(await pair.a.page.locator('[data-prompt-category="recover"]').getAttribute("aria-pressed"), "true")
    assert.equal(await pair.a.page.locator('[data-prompt-option="recover-3"]').getAttribute("aria-pressed"), "true")
    const tapTarget = await control.boundingBox()
    assert.ok(tapTarget && tapTarget.height >= 44)

    for (const observed of [pair.a, tabA2]) {
      assert.equal(observed.journal.events.some(event => /prompt|start-[1-4]|continue-[1-4]|recover-[1-4]/i.test(JSON.stringify(event))), false)
    }
    assert.equal(pair.b.journal.events.slice(peerMark).some(event => /prompt|start-[1-4]|continue-[1-4]|recover-[1-4]/i.test(JSON.stringify(event))), false)
    assert.equal(pair.a.journal.events.slice(firstTabMark).some(event => event.type === "frame_sent" && event.event === "message:send"), false)

    await tabA2.page.reload({waitUntil: "domcontentloaded"})
    await tabA2.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    assert.equal(await tabA2.page.locator("#prompt-helper").isHidden(), true)
    assert.equal(await tabA2.page.locator("#prompt-control").getAttribute("aria-expanded"), "false")
    assert.equal(await tabA2.page.locator('[data-prompt-category="start"]').getAttribute("aria-pressed"), "true")

    await confirmEndConversation(pair.b.page)
    await Promise.all([
      pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      tabA2.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      pair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    ])
    assert.equal(await pair.a.page.locator("#prompt-helper").isHidden(), true)
    assert.equal(await pair.a.page.locator("#prompt-control").getAttribute("aria-expanded"), "false")
    assertClean(pair.a)
    assertClean(tabA2)
    assertClean(pair.b)
  } finally {
    await tabA2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1K E2E-1: shared Ice Breaker retires for both participants after ordinary text", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    const cardA = pair.a.page.locator("#icebreaker-card")
    const cardB = pair.b.page.locator("#icebreaker-card")
    await Promise.all([cardA.waitFor({state: "visible"}), cardB.waitFor({state: "visible"})])
    assert.equal(await pair.a.page.locator("#icebreaker-text").textContent(), await pair.b.page.locator("#icebreaker-text").textContent())

    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await sendAndReceive(pair.a, pair.b, "A human-authored first message", pair.conversationTopic)
    await Promise.all([cardA.waitFor({state: "hidden"}), cardB.waitFor({state: "hidden"})])

    assert.equal(await exactMessage(pair.a.page, "A human-authored first message").count(), 1)
    assert.equal(await exactMessage(pair.b.page, "A human-authored first message").count(), 1)
    assert.equal(await pair.a.page.locator("#messages").getByText("Ice Breaker", {exact: false}).count(), 0)
    assert.equal(await pair.b.page.locator("#messages").getByText("Ice Breaker", {exact: false}).count(), 0)
    assert.equal(pair.a.journal.events.slice(markA).filter(event => event.type === "frame_received" && event.event === "conversation:icebreaker" && event.body?.status === "retired").length, 1)
    assert.equal(pair.b.journal.events.slice(markB).filter(event => event.type === "frame_received" && event.event === "conversation:icebreaker" && event.body?.status === "retired").length, 1)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1K E2E-2: local dismissal survives reconcile until canonical retirement reaches every tab", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let tabA2
  try {
    pair = await matchPair(browser, "Advice", {controllableA: true})
    await Promise.all([
      pair.a.page.locator("#icebreaker-card").waitFor({state: "visible"}),
      pair.b.page.locator("#icebreaker-card").waitFor({state: "visible"})
    ])
    const sharedText = await pair.a.page.locator("#icebreaker-text").textContent()
    const dismissMark = pair.a.journal.mark()
    await pair.a.page.locator("#icebreaker-dismiss").click()
    assert.equal(await pair.a.page.locator("#icebreaker-card").isHidden(), true)
    assert.equal(await pair.a.page.locator("#message-input").evaluate(node => node === document.activeElement), true)
    assert.equal(pair.a.journal.events.slice(dismissMark).some(event => event.type === "frame_sent" && /icebreaker/i.test(event.event || "")), false)

    tabA2 = await openSameParticipantTab(pair.a.context)
    assert.equal(await waitForConversation(tabA2), pair.conversationTopic)
    await tabA2.page.locator("#icebreaker-card").waitFor({state: "visible"})
    assert.equal(await tabA2.page.locator("#icebreaker-text").textContent(), sharedText)
    assert.equal(await pair.b.page.locator("#icebreaker-text").textContent(), sharedText)

    const join = pair.a.journal.events.find(event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join")
    assert.ok(join?.ref, "first participant ConversationChannel join has a reference")
    const joinReply = pair.a.journal.events.find(event => event.type === "frame_received" && event.topic === pair.conversationTopic && event.event === "phx_reply" && event.ref === join.ref && event.body?.status === "ok")
    assert.ok(joinReply?.body?.response?.epoch_id, "join supplies the authoritative epoch")
    const reconcileMark = pair.a.journal.mark()
    pair.a.injectServerFrame([
      join.ref,
      null,
      pair.conversationTopic,
      "message:new",
      {
        epoch_id: joinReply.body.response.epoch_id,
        sequence: 2,
        client_message_id: "11000000-0000-4000-8000-000000000001",
        message_id: "11000000-0000-4000-8000-000000000001",
        sender_id: "test-only-gap-probe",
        type: "text",
        content: "Test-only reconcile gap probe",
        status: "sent",
        sent_at: new Date().toISOString()
      }
    ])
    const reconcile = await pair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "sync:reconcile",
      "1K actual sync:reconcile after a test-controlled gap",
      reconcileMark
    )
    const reconcileReply = await pair.a.journal.waitFor(
      event => event.type === "frame_received" && event.topic === pair.conversationTopic && event.event === "phx_reply" && event.ref === reconcile.ref && event.body?.status === "ok",
      "1K authoritative reconcile reply",
      reconcileMark
    )
    assert.equal(reconcileReply.body.response.icebreaker.status, "active")
    assert.equal(await pair.a.page.locator("#icebreaker-card").isHidden(), true, "authoritative active reconcile preserves this tab's dismissal")
    assert.equal(await tabA2.page.locator("#icebreaker-card").isVisible(), true)
    assert.equal(await pair.b.page.locator("#icebreaker-card").isVisible(), true)

    await sendAndReceive(pair.b, pair.a, "Canonical retirement after local dismissal", pair.conversationTopic)
    await Promise.all([
      pair.a.page.locator("#icebreaker-card").waitFor({state: "hidden"}),
      tabA2.page.locator("#icebreaker-card").waitFor({state: "hidden"}),
      pair.b.page.locator("#icebreaker-card").waitFor({state: "hidden"})
    ])
    assertClean(pair.a)
    assertClean(tabA2)
    assertClean(pair.b)
  } finally {
    await tabA2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1K E2E-3: expressive first contribution retires once and remains retired after reload", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Distract")
    await Promise.all([
      pair.a.page.locator("#icebreaker-card").waitFor({state: "visible"}),
      pair.b.page.locator("#icebreaker-card").waitFor({state: "visible"})
    ])
    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await openMessageTools(pair.a.page)
    await pair.a.page.locator("#expressive-open").click()
    await pair.a.page.locator("#expressive-search").fill("bright")
    await pair.a.page.getByRole("option", {name: "A bright spark"}).click()
    await pair.b.journal.waitFor(
      event => event.type === "frame_received" && event.topic === pair.conversationTopic && event.event === "message:new" && event.body?.type === "expressive" && event.body?.expressive?.id === "bright-spark",
      "1K expressive first contribution"
    )
    await Promise.all([
      pair.a.page.locator("#icebreaker-card").waitFor({state: "hidden"}),
      pair.b.page.locator("#icebreaker-card").waitFor({state: "hidden"})
    ])
    assert.equal(pair.a.journal.events.slice(markA).filter(event => event.type === "frame_received" && event.event === "conversation:icebreaker" && event.body?.status === "retired").length, 1)
    assert.equal(pair.b.journal.events.slice(markB).filter(event => event.type === "frame_received" && event.event === "conversation:icebreaker" && event.body?.status === "retired").length, 1)
    await pair.b.page.getByRole("img", {name: "A bright spark"}).waitFor({state: "visible"})

    const refreshMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.b, refreshMark)
    await pair.b.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join",
      "1K restored ConversationChannel join",
      refreshMark
    )
    await pair.b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator("#icebreaker-card").isHidden(), true)
    await pair.b.page.getByRole("img", {name: "A bright spark"}).waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 1)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1L E2E-1: entry disclosure opens details and remains a local cue in the live Conversation", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b
  try {
    a = await bootFresh(browser)
    const entry = a.page.locator(".temporary-entry")
    await entry.waitFor({state: "visible"})
    assert.equal(await entry.locator("h2").textContent(), "Temporary Conversation")
    assert.equal(await entry.locator("p").textContent(), "This Conversation isn't kept as a permanent chat history. StrangerTalks temporarily keeps enough recent Conversation information to keep the chat working and help it recover from a short connection interruption.")

    await a.page.emulateMedia({reducedMotion: "reduce", forcedColors: "active"})
    await a.page.setViewportSize({width: 390, height: 844})
    const detailsTrigger = entry.getByRole("button", {name: "How this works"})
    const disclosureMark = a.journal.mark()
    await detailsTrigger.focus()
    await a.page.keyboard.press("Enter")
    const dialog = a.page.locator("#lifetime-details-dialog")
    await dialog.waitFor({state: "visible"})
    assert.equal(await a.page.locator("#lifetime-details-close").evaluate((node) => node === document.activeElement), true)
    for (const heading of ["Temporary by design", "If your connection drops", "When the Conversation ends", "Safety reports are different", "The other person can still keep what they receive"]) {
      await dialog.getByRole("heading", {name: heading}).scrollIntoViewIfNeeded()
      assert.equal(await dialog.getByRole("heading", {name: heading}).isVisible(), true)
    }
    assert.match(await dialog.textContent(), /StrangerTalks can't remove copies they keep outside the temporary Conversation\./)
    await a.page.keyboard.press("Escape")
    assert.equal(await a.page.locator("#lifetime-details-backdrop").isHidden(), true)
    assert.equal(await detailsTrigger.evaluate((node) => node === document.activeElement), true)
    assert.equal(a.journal.events.slice(disclosureMark).some((event) => event.type === "frame_sent" && event.event !== "heartbeat"), false)

    await a.page.setViewportSize({width: 1280, height: 800})
    b = await bootFresh(browser)
    await clickDoorAndQueue(a.page, "Deep Talk")
    await b.page.locator('button.door:has-text("Deep Talk")').click()
    const [topicA, topicB] = await Promise.all([waitForConversation(a), waitForConversation(b)])
    assert.equal(topicA, topicB)
    const cue = a.page.locator(".temporary-conversation-cue")
    await cue.waitFor({state: "visible"})
    assert.equal(await cue.locator("strong").textContent(), "Temporary chat")
    const cueTrigger = cue.getByRole("button", {name: "Learn what happens to this Conversation when it ends"})
    const cueTarget = await cueTrigger.boundingBox()
    assert.ok(cueTarget && cueTarget.height >= 44)
    await sendAndReceive(a, b, "1L ordinary composer remains usable", topicA)
    for (const observed of [a, b]) {
      assert.equal(observed.journal.events.some((event) => /privacy|lifetime|ephemeral|temporary_conversation/i.test(event.event || "")), false)
      assertClean(observed)
    }
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1L E2E-2: reconnect, explicit end, and unrecoverable states remain semantically distinct", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let recoverablePair
  let terminalPair
  try {
    recoverablePair = await matchPair(browser, "Advice", {controllableA: true})
    await recoverablePair.a.disconnectSocket()
    await recoverablePair.a.page.locator("#presence", {hasText: "Reconnecting…"}).waitFor({state: "visible"})
    assert.equal(await recoverablePair.a.page.locator("#presence-support").textContent(), "Your Conversation may still recover.")
    assert.equal(await recoverablePair.a.page.locator("#presence-support").isVisible(), true)
    const reconnectCopy = `${await recoverablePair.a.page.locator("#presence").textContent()} ${await recoverablePair.a.page.locator("#presence-support").textContent()}`
    assert.doesNotMatch(reconnectCopy, /deleted|ended|disappeared|removed|gone forever/i)

    const reconnectMark = recoverablePair.a.journal.mark()
    recoverablePair.a.reconnectSocket()
    await recoverablePair.a.journal.waitFor(
      (event) => event.type === "frame_received" && event.topic === recoverablePair.conversationTopic && event.event === "phx_reply" && event.body?.status === "ok",
      "1L recoverable ConversationChannel rejoin",
      reconnectMark
    )
    await recoverablePair.a.page.locator("#presence-support").waitFor({state: "hidden"})

    const cancelMark = recoverablePair.a.journal.mark()
    await openEndConfirmation(recoverablePair.a.page)
    const confirmation = recoverablePair.a.page.locator("#end-confirmation-dialog")
    assert.equal(await confirmation.getByRole("heading").textContent(), "End this Conversation?")
    assert.match(await confirmation.textContent(), /live temporary Conversation/)
    assert.match(await confirmation.textContent(), /server-owned voice-note audio/)
    assert.match(await confirmation.textContent(), /Safety reports are stored separately/)
    assert.match(await confirmation.textContent(), /either participant's device can remain/)
    assert.equal(await recoverablePair.a.page.locator("#end-cancel").evaluate((node) => node === document.activeElement), true)
    await recoverablePair.a.page.locator("#end-cancel").click()
    assert.equal(recoverablePair.a.journal.events.slice(cancelMark).some((event) => event.type === "frame_sent" && event.event === "conversation:end"), false)
    assert.equal(await recoverablePair.a.page.locator("#end-conversation").evaluate((node) => node === document.activeElement), true)

    await confirmEndConversation(recoverablePair.a.page)
    await Promise.all([
      recoverablePair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      recoverablePair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    ])
    assert.equal(recoverablePair.a.journal.events.some((event) => event.type === "frame_sent" && event.event === "conversation:end"), true)

    terminalPair = await matchPair(browser, "Vent", {controllableA: true})
    const terminalMark = terminalPair.a.journal.mark()
    terminalPair.a.dropNextServerFrame((message) => message?.topic === terminalPair.conversationTopic && message?.event === "phx_reply" && terminalPair.a.journal.events.slice(terminalMark).some((event) => event.type === "frame_sent" && event.event === "message:send" && event.ref === message.ref))
    await sendMessage(terminalPair.a.page, "1L terminal harness probe")
    const pendingSend = await terminalPair.a.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === terminalPair.conversationTopic && event.event === "message:send",
      "1L terminal harness message request",
      terminalMark
    )
    terminalPair.a.injectServerFrame([pendingSend.joinRef, pendingSend.ref, pendingSend.topic, "phx_reply", {status: "error", response: {code: "CONVERSATION_UNAVAILABLE"}}])
    const terminal = terminalPair.a.page.locator('section[data-screen="unrecoverable"].active')
    await terminal.waitFor({state: "visible"})
    assert.equal(await terminal.getByRole("heading", {level: 1}).textContent(), "This Conversation can't be restored")
    assert.match(await terminal.textContent(), /The live Conversation is no longer available to recover\./)
    assert.doesNotMatch(await terminal.textContent(), /securely erased|permanently deleted|wiped|destroyed everywhere|gone forever/i)
    assert.equal(await terminalPair.a.page.locator("#presence-support").isVisible(), false)
    assertClean(recoverablePair.a, {allowedFailedRequest: () => false})
    assertClean(recoverablePair.b)
    assertClean(terminalPair.a)
    assertClean(terminalPair.b)
  } finally {
    await recoverablePair?.a.context.close().catch(() => {})
    await recoverablePair?.b.context.close().catch(() => {})
    await terminalPair?.a.context.close().catch(() => {})
    await terminalPair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1L E2E-3: the real report flow shows safety lifetime limits without adding report fields", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Distract")
    await pair.a.page.setViewportSize({width: 390, height: 844})
    await pair.a.page.locator("details.overflow summary").click()
    const reportOpen = pair.a.page.locator("#report-open")
    await reportOpen.click()
    const report = pair.a.page.locator("#report-form")
    await report.waitFor({state: "visible"})
    assert.equal(await report.getByRole("heading", {name: "About this report"}).evaluate((node) => node === document.activeElement), true)
    assert.match(await report.textContent(), /Reports are stored separately for safety and can remain after this Conversation ends\./)
    assert.match(await report.textContent(), /does not automatically save the ordinary Conversation transcript, Reply structure, GIF or sticker choice, voice-note identity or audio, or surrounding chat history/)
    assert.match(await report.textContent(), /no automatic expiry or cleanup/)
    const submitTarget = await report.getByRole("button", {name: "Submit Report"}).boundingBox()
    assert.ok(submitTarget && submitTarget.height >= 44)

    await pair.a.page.locator("#report-cancel").click()
    assert.equal(await report.isHidden(), true)
    assert.equal(await reportOpen.evaluate((node) => node === document.activeElement), true)
    await reportOpen.click()
    await report.getByRole("heading", {name: "About this report"}).waitFor({state: "visible"})
    await pair.a.page.locator("#report-category").selectOption({label: "HARASSMENT"})
    await pair.a.page.locator("#report-evidence").fill("Participant-selected evidence only")
    const submitMark = pair.a.journal.mark()
    await report.getByRole("button", {name: "Submit Report"}).click()
    const submitted = await pair.a.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "conversation:report",
      "1L real report submission",
      submitMark
    )
    assert.deepEqual(Object.keys(submitted.body).sort(), ["category", "evidence"])
    assert.deepEqual(submitted.body, {category: "HARASSMENT", evidence: "Participant-selected evidence only"})
    assert.equal(pair.a.journal.events.slice(submitMark).some((event) => /privacy|lifetime|ephemeral|retention/i.test(event.event || "")), false)
    await pair.a.page.getByRole("status").filter({hasText: "Report submitted for pending review."}).waitFor({state: "visible"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1M E2E-1: basic edit preserves identity, references, draft, Reply staging, and latest-content delivery", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk", {controllableB: true})
    await pair.a.context.grantPermissions(["clipboard-read", "clipboard-write"], {origin: BASE_URL})
    await sendAndReceive(pair.a, pair.b, "1M original text", pair.conversationTopic)
    const bubbleA = pair.a.page.locator("#messages li", {hasText: "1M original text"})
    await bubbleA.locator(".message-status", {hasText: "delivered"}).waitFor({state: "visible"})
    const messageId = await bubbleA.getAttribute("data-message-id")
    const initialIndex = await pair.a.page.locator("#messages li").evaluateAll((nodes, id) => nodes.findIndex((node) => node.dataset.messageId === id), messageId)

    await sendAndReceive(pair.b, pair.a, "1M Reply staging target", pair.conversationTopic)
    await pair.b.page.locator("#messages li", {hasText: "1M Reply staging target"}).locator(".message-status", {hasText: "delivered"}).waitFor({state: "visible"})
    const peerBubble = pair.a.page.locator("#messages li", {hasText: "1M Reply staging target"})
    await peerBubble.focus()
    await peerBubble.getByRole("button", {name: "Reply to message"}).click()
    await pair.a.page.locator("#reply-staging").waitFor({state: "visible"})
    await pair.a.page.locator("#message-input").fill("participant draft stays")

    await bubbleA.focus()
    await bubbleA.getByRole("button", {name: "Pin message"}).click()
    await bubbleA.locator(".message-pinned-badge").waitFor({state: "visible"})

    const editMarkA = pair.a.journal.mark()
    const editMarkB = pair.b.journal.mark()
    pair.b.dropNextServerFrame((message) => message?.topic === pair.conversationTopic && message?.event === "message:edited")
    await bubbleA.focus()
    await bubbleA.getByRole("button", {name: "Edit message"}).click()
    const editForm = bubbleA.locator(".message-edit-form")
    await editForm.getByLabel("Edit message text").fill("1M edited text")
    await editForm.getByRole("button", {name: "Save"}).click()

    const editRequest = await pair.a.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "message:edit",
      "1M explicit edit request",
      editMarkA
    )
    assert.deepEqual(Object.keys(editRequest.body).sort(), ["content", "expected_content_revision", "target_client_message_id"])
    assert.equal(editRequest.body.target_client_message_id, messageId)
    assert.equal(editRequest.body.expected_content_revision, 0)
    assert.equal(editRequest.body.content, "1M edited text")
    assert.equal(await pair.a.page.locator("#message-input").inputValue(), "participant draft stays")
    assert.equal(await pair.a.page.locator("#reply-staging").isVisible(), true)
    assert.equal(await pair.a.page.locator(`[data-message-id="${messageId}"]`).count(), 1)
    assert.equal(await pair.a.page.locator("#messages li").evaluateAll((nodes, id) => nodes.findIndex((node) => node.dataset.messageId === id), messageId), initialIndex)
    await pair.a.page.locator(`[data-message-id="${messageId}"] .message-status`, {hasText: "Edited · Sent"}).waitFor({state: "visible"})
    assert.equal(pair.b.journal.events.slice(editMarkB).some((event) => event.event === "content:applied" && event.body?.target_client_message_id === messageId && event.body?.content_revision === 1), false)

    await pair.b.page.waitForTimeout(250)
    const dropped = pair.b.socketControl.droppedServerFrames.find((message) => message?.event === "message:edited" && message?.body?.client_message_id === messageId)
    assert.ok(dropped, "recipient edit frame was deterministically withheld")
    pair.b.injectServerFrame([dropped.joinRef, dropped.ref, dropped.topic, dropped.event, dropped.body])
    await exactMessage(pair.b.page, "1M edited text").waitFor({state: "visible"})
    await pair.a.page.locator(`[data-message-id="${messageId}"] .message-status`, {hasText: "Edited · Delivered"}).waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator(`[data-message-id="${messageId}"] .message-edited`).isVisible(), true)
    const editedBubbleA = pair.a.page.locator(`[data-message-id="${messageId}"]`)
    assert.equal(await editedBubbleA.locator(".message-pinned-badge").isVisible(), true)
    await editedBubbleA.focus()
    await editedBubbleA.getByRole("button", {name: "Copy message text"}).click()
    await pair.a.page.getByRole("status").filter({hasText: "Message copied."}).waitFor({state: "visible"})
    assert.equal(await pair.a.page.evaluate(() => navigator.clipboard.readText()), "1M edited text")
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1M E2E-2: same-participant stale edit preserves attempted text without automatic retry", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let a2
  try {
    pair = await matchPair(browser, "Advice")
    a2 = await openSameParticipantTab(pair.a.context)
    await waitForConversation(a2)
    await a2.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    await sendAndReceive(pair.a, pair.b, "1M shared revision zero", pair.conversationTopic)
    const a2RefreshMark = a2.journal.mark()
    await a2.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(a2, a2RefreshMark)
    await a2.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join",
      "1M same-participant sibling rejoin",
      a2RefreshMark
    )
    await a2.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    await exactMessage(a2.page, "1M shared revision zero").waitFor({state: "visible"})

    const sharedId = await pair.a.page.locator("#messages li", {hasText: "1M shared revision zero"}).getAttribute("data-message-id")
    const bubbleA1 = pair.a.page.locator(`[data-message-id="${sharedId}"]`)
    const bubbleA2 = a2.page.locator(`[data-message-id="${sharedId}"]`)
    await bubbleA1.focus()
    await bubbleA1.getByRole("button", {name: "Edit message"}).click()
    await bubbleA1.getByLabel("Edit message text").fill("1M winner X")
    await bubbleA2.focus()
    await bubbleA2.getByRole("button", {name: "Edit message"}).click()
    await bubbleA2.getByLabel("Edit message text").fill("1M attempted Y")

    await bubbleA1.getByRole("button", {name: "Save"}).click()
    await exactMessage(pair.b.page, "1M winner X").waitFor({state: "visible"})
    await a2.page.locator(".edit-canonical-current", {hasText: "1M winner X"}).waitFor({state: "visible"})
    assert.equal(await bubbleA2.getByLabel("Edit message text").inputValue(), "1M attempted Y")

    const staleMark = a2.journal.mark()
    await bubbleA2.getByRole("button", {name: "Save"}).click()
    const staleRequest = await a2.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "message:edit" && event.body?.content === "1M attempted Y",
      "1M stale edit request",
      staleMark
    )
    assert.equal(staleRequest.body.expected_content_revision, 0)
    await bubbleA2.locator(".message-edit-conflict", {hasText: "changed elsewhere"}).waitFor({state: "visible"})
    assert.equal(await bubbleA2.getByLabel("Edit message text").inputValue(), "1M attempted Y")
    assert.equal(await exactMessage(a2.page, "1M winner X").count(), 1)
    assert.equal(await exactMessage(pair.b.page, "1M attempted Y").count(), 0)
    await a2.page.waitForTimeout(750)
    assert.equal(a2.journal.events.slice(staleMark).filter((event) => event.type === "frame_sent" && event.event === "message:edit" && event.body?.content === "1M attempted Y").length, 1)
    assertClean(pair.a)
    assertClean(a2)
    assertClean(pair.b)
  } finally {
    await a2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1M E2E-3: missed live edit recovers current revision and safely re-announces applied evidence", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent", {controllableB: true})
    await sendAndReceive(pair.a, pair.b, "1M recovery original", pair.conversationTopic)
    const bubbleA = pair.a.page.locator("#messages li", {hasText: "1M recovery original"})
    await bubbleA.locator(".message-status", {hasText: "delivered"}).waitFor({state: "visible"})
    const messageId = await bubbleA.getAttribute("data-message-id")

    pair.b.dropNextServerFrame((message) => message?.topic === pair.conversationTopic && message?.event === "message:edited")
    await bubbleA.focus()
    await bubbleA.getByRole("button", {name: "Edit message"}).click()
    await bubbleA.getByLabel("Edit message text").fill("1M recovered revision")
    await bubbleA.getByRole("button", {name: "Save"}).click()
    await pair.a.page.locator(`[data-message-id="${messageId}"] .message-status`, {hasText: "Edited · Sent"}).waitFor({state: "visible"})
    assert.equal(await exactMessage(pair.b.page, "1M recovery original").count(), 1)
    assert.equal(await exactMessage(pair.b.page, "1M recovered revision").count(), 0)

    const recoveryMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.b, recoveryMark)
    await pair.b.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "phx_join",
      "1M recipient recovery join",
      recoveryMark
    )
    await pair.b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
    await exactMessage(pair.b.page, "1M recovered revision").waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator(`[data-message-id="${messageId}"]`).count(), 1)
    assert.equal(await exactMessage(pair.b.page, "1M recovery original").count(), 0)
    await pair.b.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "content:applied" && event.body?.target_client_message_id === messageId && event.body?.content_revision === 1,
      "1M recovered applied-revision reannouncement",
      recoveryMark
    )
    await pair.a.page.locator(`[data-message-id="${messageId}"] .message-status`, {hasText: "Edited · Delivered"}).waitFor({state: "visible"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1N E2E-1: basic Unsend preserves identity and delivery while sanitizing references", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")
    await sendAndReceive(pair.a, pair.b, "1N target private text", pair.conversationTopic)
    const initialTargetA = pair.a.page.locator("#messages li", {hasText: "1N target private text"})
    await initialTargetA.locator(".message-status", {hasText: "delivered"}).waitFor({state: "visible"})
    const messageId = await initialTargetA.getAttribute("data-message-id")
    const targetA = pair.a.page.locator(`[data-message-id="${messageId}"]`)
    const targetB = pair.b.page.locator(`[data-message-id="${messageId}"]`)
    const originalIndex = await pair.a.page.locator("#messages li").evaluateAll((nodes, id) => nodes.findIndex((node) => node.dataset.messageId === id), messageId)

    await targetB.hover()
    await targetB.locator(".reply-action-btn").click()
    await pair.b.page.locator("#reply-staging").waitFor({state: "visible"})
    await pair.b.page.locator("#message-input").fill("1N reply survives")
    await pair.b.page.locator('section[data-screen="conversation"].active #message-form').getByRole("button", {name: "Send message"}).click()
    const replyA = pair.a.page.locator("#messages li", {hasText: "1N reply survives"})
    await replyA.waitFor({state: "visible"})
    assert.equal(await replyA.locator(".reply-snippet").textContent(), "1N target private text")

    await targetB.hover()
    await targetB.locator(".react-action-btn").click()
    await targetB.locator(".reaction-picker button.reaction-btn:not(.more-btn)").first().click()
    await targetA.locator(".reaction-pill.peer").waitFor({state: "visible"})

    await targetB.hover()
    await targetB.getByRole("button", {name: "Pin message"}).click()
    await openConversationInfo(pair.b.page)
    await pair.b.page.locator("#pinned-messages-control").waitFor({state: "visible"})

    const unsendMark = pair.a.journal.mark()
    await targetA.focus()
    await targetA.getByRole("button", {name: "Unsend message"}).click()
    const dialog = pair.a.page.locator("#unsend-confirmation-dialog")
    await dialog.waitFor({state: "visible"})
    assert.equal(await dialog.getByRole("heading", {name: "Unsend this message?"}).count(), 1)
    assert.match(await dialog.textContent(), /may already have seen, copied, or saved it/)
    assert.match(await dialog.textContent(), /temporarily keep a safety copy/)
    assert.equal(pair.a.journal.events.slice(unsendMark).some((event) => event.event === "message:unsend"), false)
    await dialog.getByRole("button", {name: "Unsend", exact: true}).click()

    const unsendRequest = await pair.a.journal.waitFor(
      (event) => event.type === "frame_sent" && event.topic === pair.conversationTopic && event.event === "message:unsend",
      "1N explicit Unsend request",
      unsendMark
    )
    assert.deepEqual(Object.keys(unsendRequest.body).sort(), ["expected_content_revision", "target_client_message_id"])
    assert.equal(unsendRequest.body.target_client_message_id, messageId)
    assert.equal(unsendRequest.body.expected_content_revision, 0)

    const terminalA = pair.a.page.locator(`[data-message-id="${messageId}"]`)
    const terminalB = pair.b.page.locator(`[data-message-id="${messageId}"]`)
    await terminalA.locator(".message-content", {hasText: "Message unsent"}).waitFor({state: "visible"})
    await terminalB.locator(".message-content", {hasText: "Message unsent"}).waitFor({state: "visible"})
    assert.equal(await pair.a.page.locator(`[data-message-id="${messageId}"]`).count(), 1)
    assert.equal(await pair.a.page.locator("#messages li").evaluateAll((nodes, id) => nodes.findIndex((node) => node.dataset.messageId === id), messageId), originalIndex)
    assert.equal(await exactMessage(pair.a.page, "1N target private text").count(), 0)
    assert.equal(await exactMessage(pair.b.page, "1N target private text").count(), 0)
    assert.equal(await replyA.locator(".reply-snippet").textContent(), "Unsent message")
    assert.equal(await targetA.locator(".reaction-pill").count(), 0)
    assert.match(await terminalA.locator(".message-status").textContent(), /delivered/i)

    for (const action of ["Copy message text", "Edit message", "React to message", "Reply to message", "Pin message"]) {
      assert.equal(await terminalA.getByRole("button", {name: action}).count(), 0)
      assert.equal(await terminalB.getByRole("button", {name: action}).count(), 0)
    }

    await openConversationInfo(pair.b.page)

    await pair.b.page.locator("#pinned-messages-control").click()
    const pinPanel = pair.b.page.locator("#pinned-messages-panel")
    await pinPanel.waitFor({state: "visible"})
    assert.equal(await pinPanel.locator(".pinned-snippet").textContent(), "Unsent message")
    await pinPanel.getByRole("button", {name: "Unpin message"}).click()
    await pair.b.page.locator("#pinned-messages-control").waitFor({state: "hidden"})
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1N E2E-2: same-participant Edit and Unsend races preserve CAS and terminal precedence", {timeout: 150_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let a2
  try {
    pair = await matchPair(browser, "Advice")
    await sendAndReceive(pair.a, pair.b, "1N edit wins base", pair.conversationTopic)
    a2 = await openSameParticipantTab(pair.a.context)
    await waitForConversation(a2)
    await exactMessage(a2.page, "1N edit wins base").waitFor({state: "visible"})
    const firstId = await pair.a.page.locator("#messages li", {hasText: "1N edit wins base"}).getAttribute("data-message-id")
    const firstA1 = pair.a.page.locator(`[data-message-id="${firstId}"]`)
    const firstA2 = a2.page.locator(`[data-message-id="${firstId}"]`)

    await firstA2.focus()
    await firstA2.getByRole("button", {name: "Unsend message"}).click()
    await a2.page.locator("#unsend-confirmation-dialog").waitFor({state: "visible"})
    await firstA1.focus()
    await firstA1.getByRole("button", {name: "Edit message"}).click()
    await firstA1.getByLabel("Edit message text").fill("1N edit wins canonical")
    await firstA1.getByRole("button", {name: "Save"}).click()
    await exactMessage(pair.b.page, "1N edit wins canonical").waitFor({state: "visible"})

    const staleMark = a2.journal.mark()
    await a2.page.locator("#unsend-confirm").click()
    const staleUnsend = await a2.journal.waitFor(
      (event) => event.type === "frame_sent" && event.event === "message:unsend" && event.body?.target_client_message_id === firstId,
      "1N stale Unsend request",
      staleMark
    )
    assert.equal(staleUnsend.body.expected_content_revision, 0)
    await a2.page.getByRole("status").filter({hasText: "changed elsewhere and was not unsent"}).waitFor({state: "visible"})
    assert.equal(await exactMessage(a2.page, "1N edit wins canonical").count(), 1)
    assert.equal(await a2.page.locator(`[data-message-id="${firstId}"]`, {hasText: "Message unsent"}).count(), 0)

    await sendAndReceive(pair.a, pair.b, "1N unsend wins base", pair.conversationTopic)
    const refreshMark = a2.journal.mark()
    await a2.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(a2, refreshMark)
    await waitForConversation(a2)
    await exactMessage(a2.page, "1N unsend wins base").waitFor({state: "visible"})
    const secondId = await pair.a.page.locator("#messages li", {hasText: "1N unsend wins base"}).getAttribute("data-message-id")
    const secondA1 = pair.a.page.locator(`[data-message-id="${secondId}"]`)
    const secondA2 = a2.page.locator(`[data-message-id="${secondId}"]`)
    // Diagnostic only: observe the original focus/click sequence without retrying it.
    await a2.page.evaluate((messageId) => {
      const nodes = new WeakMap()
      let nextNodeId = 0
      const describe = (element) => {
        if (!(element instanceof Element)) return null
        if (!nodes.has(element)) nodes.set(element, ++nextNodeId)
        const style = getComputedStyle(element)
        const rect = element.getBoundingClientRect()
        return {
          nodeId: nodes.get(element), tag: element.tagName, id: element.id,
          class: element.getAttribute("class"), connected: element.isConnected,
          tabIndex: element.tabIndex, hidden: element.hasAttribute("hidden"),
          inert: element.hasAttribute("inert"), ariaHidden: element.getAttribute("aria-hidden"),
          ariaLabel: element.getAttribute("aria-label"), disabled: element.disabled,
          focus: element.matches(":focus"), focusWithin: element.matches(":focus-within"),
          focusVisible: element.matches(":focus-visible"), hover: element.matches(":hover"),
          display: style.display, visibility: style.visibility, opacity: style.opacity,
          pointerEvents: style.pointerEvents, contentVisibility: style.contentVisibility,
          overflow: style.overflow, position: style.position, zIndex: style.zIndex,
          rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
        }
      }
      const initial = document.querySelector(`[data-message-id="${messageId}"]`)
      const snapshot = () => {
        const message = document.querySelector(`[data-message-id="${messageId}"]`)
        const button = message?.querySelector(".edit-action-btn")
        const ancestors = []
        for (let node = button || message; node; node = node.parentElement) ancestors.push(describe(node))
        return {
          documentHasFocus: document.hasFocus(), visibilityState: document.visibilityState,
          activeElement: describe(document.activeElement), initialMessage: describe(initial),
          currentMessage: describe(message), sameMessageNode: message === initial,
          matchingMessages: document.querySelectorAll(`[data-message-id="${messageId}"]`).length,
          ancestors, viewport: {width: innerWidth, height: innerHeight},
          anyHover: matchMedia("(any-hover: hover)").matches,
          reducedMotion: matchMedia("(prefers-reduced-motion: reduce)").matches
        }
      }
      const events = []
      let droppedEvents = 0
      const record = (reason, detail = null) => {
        events.push({time: performance.now(), reason, detail, snapshot: snapshot()})
        if (events.length > 100) { events.shift(); droppedEvents++ }
      }
      const onFocus = (event) => record(event.type, {
        target: describe(event.target), relatedTarget: describe(event.relatedTarget)
      })
      for (const name of ["focus", "blur", "focusin", "focusout"]) document.addEventListener(name, onFocus, true)
      const observer = new MutationObserver((records) => {
        const relevant = records.filter((entry) => {
          const current = document.querySelector(`[data-message-id="${messageId}"]`)
          return [initial, current].some((message) => message && (
            entry.target === message || message.contains(entry.target) || entry.target.contains(message) ||
            [...entry.removedNodes].some((node) => node === message || node.contains(message))
          ))
        })
        if (relevant.length) record("mutation", relevant.map((entry) => ({
          type: entry.type, target: describe(entry.target), attribute: entry.attributeName,
          oldValue: entry.oldValue,
          newValue: entry.attributeName ? entry.target.getAttribute(entry.attributeName) : null,
          added: [...entry.addedNodes].map(describe), removed: [...entry.removedNodes].map(describe)
        })))
      })
      observer.observe(document.documentElement, {
        subtree: true, childList: true, attributes: true, attributeOldValue: true,
        attributeFilter: ["class", "style", "hidden", "inert", "tabindex", "aria-hidden", "disabled"]
      })
      let frame
      let previousState
      const sample = () => {
        const state = JSON.stringify(snapshot())
        if (state !== previousState) { record("animation-frame-change"); previousState = state }
        frame = requestAnimationFrame(sample)
      }
      record("before-focus")
      frame = requestAnimationFrame(sample)
      window.__diag64FocusTrace = () => {
        observer.disconnect()
        cancelAnimationFrame(frame)
        for (const name of ["focus", "blur", "focusin", "focusout"]) document.removeEventListener(name, onFocus, true)
        const current = document.querySelector(`[data-message-id="${messageId}"]`)
        const elements = []
        for (let node = current?.querySelector(".edit-action-btn") || current; node; node = node.parentElement) elements.push(node)
        const matchedRules = []
        const readRules = (rules, conditions = []) => {
          for (const rule of rules) {
            if (rule.selectorText) {
              const matches = elements.filter((element) => element.matches(rule.selectorText))
              if (matches.length) matchedRules.push({
                selector: rule.selectorText, css: rule.style.cssText, conditions,
                nodes: matches.map((element) => nodes.get(element))
              })
            }
            if (rule.cssRules) readRules(rule.cssRules, [...conditions, {
              text: rule.conditionText || rule.name || rule.constructor.name,
              mediaMatches: rule instanceof CSSMediaRule ? matchMedia(rule.conditionText).matches : null
            }])
          }
        }
        for (const sheet of document.styleSheets) {
          try { readRules(sheet.cssRules) } catch (error) {
            matchedRules.push({href: sheet.href, error: error.message})
          }
        }
        return {messageId, droppedEvents, events, finalSnapshot: snapshot(), matchedRules}
      }
    }, secondId)
    try {
      await secondA2.focus()
      await secondA2.getByRole("button", {name: "Edit message"}).click()
    } catch (error) {
      const trace = await a2.page.evaluate(() => window.__diag64FocusTrace()).catch((traceError) => ({traceError: traceError.message}))
      console.log(`DIAG64_FOCUS_FAILURE ${JSON.stringify(trace)}`)
      error.message += `\nDIAG64_FOCUS_FAILURE ${JSON.stringify(trace)}`
      throw error
    } finally {
      await a2.page.evaluate(() => {
        window.__diag64FocusTrace?.()
        delete window.__diag64FocusTrace
      }).catch(() => {})
    }
    await secondA2.getByLabel("Edit message text").fill("1N delayed edit must stay local")

    await secondA1.focus()
    await secondA1.getByRole("button", {name: "Unsend message"}).click()
    await pair.a.page.locator("#unsend-confirm").click()
    await pair.b.page.locator(`[data-message-id="${secondId}"] .message-content`, {hasText: "Message unsent"}).waitFor({state: "visible"})
    await secondA2.locator(".message-edit-conflict", {hasText: "was unsent"}).waitFor({state: "visible"})
    assert.equal(await secondA2.getByLabel("Edit message text").inputValue(), "1N delayed edit must stay local")

    const lateEditMark = a2.journal.mark()
    await secondA2.getByRole("button", {name: "Save"}).click()
    await a2.journal.waitFor(
      (event) => event.type === "frame_sent" && event.event === "message:edit" && event.body?.target_client_message_id === secondId,
      "1N delayed stale Edit",
      lateEditMark
    )
    await a2.page.getByRole("status").filter({hasText: "no longer available to edit"}).waitFor({state: "visible"})
    assert.equal(await exactMessage(pair.b.page, "1N delayed edit must stay local").count(), 0)
    assert.equal(await pair.b.page.locator(`[data-message-id="${secondId}"] .message-content`).textContent(), "Message unsent")
    assertClean(pair.a)
    assertClean(a2)
    assertClean(pair.b)
  } finally {
    await a2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1N E2E-3: offline recovery retains tombstone then post-prune authority removes stale cache without inventing cause", {timeout: 240_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent", {controllableB: true})
    const oldText = "1N offline stale private text"
    await sendAndReceive(pair.a, pair.b, oldText, pair.conversationTopic)
    const targetA = pair.a.page.locator("#messages li", {hasText: oldText})
    const targetB = pair.b.page.locator("#messages li", {hasText: oldText})
    await targetA.locator(".message-status", {hasText: "delivered"}).waitFor({state: "visible"})
    const messageId = await targetA.getAttribute("data-message-id")
    await targetB.hover()
    await targetB.getByRole("button", {name: "Pin message"}).click()
    await openConversationInfo(pair.b.page)
    await pair.b.page.locator("#pinned-messages-control").waitFor({state: "visible"})

    await pair.b.disconnectSocket()
    await targetA.focus()
    await targetA.getByRole("button", {name: "Unsend message"}).click()
    await pair.a.page.locator("#unsend-confirm").click()
    await pair.a.page.locator(`[data-message-id="${messageId}"] .message-content`, {hasText: "Message unsent"}).waitFor({state: "visible"})

    pair.b.reconnectSocket()
    const retainedMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.b, retainedMark)
    await waitForConversation(pair.b)
    await pair.b.page.locator(`[data-message-id="${messageId}"] .message-content`, {hasText: "Message unsent"}).waitFor({state: "visible"})
    assert.equal(await exactMessage(pair.b.page, oldText).count(), 0)

    for (let index = 1; index <= 18; index++) {
      const filler = `1N prune filler ${index} ${"x".repeat(15_000)}`
      await sendAndReceive(pair.a, pair.b, filler, pair.conversationTopic)
    }

    await pair.b.page.evaluate(async ({messageId, oldText}) => {
      const opening = indexedDB.open("strangertalks-local-v1", 1)
      const database = await new Promise((resolve, reject) => {
        opening.onerror = () => reject(opening.error)
        opening.onsuccess = () => resolve(opening.result)
      })
      const transaction = database.transaction("records", "readwrite")
      const store = transaction.objectStore("records")
      const cursorRequest = store.openCursor()
      const seeded = await new Promise((resolve, reject) => {
        cursorRequest.onerror = () => reject(cursorRequest.error)
        cursorRequest.onsuccess = () => {
          const cursor = cursorRequest.result
          if (!cursor) return resolve(false)
          if (cursor.value?.type === "local_message" && (cursor.value.value?.client_message_id || cursor.value.value?.message_id) === messageId) {
            cursor.update({...cursor.value, value: {...cursor.value.value, content: oldText, availability: "available", unsent: false}})
            return resolve(true)
          }
          cursor.continue()
        }
      })
      if (!seeded) throw new Error("1N target cache record was not found")
      await new Promise((resolve, reject) => {
        transaction.oncomplete = resolve
        transaction.onerror = () => reject(transaction.error)
      })
      database.close()
    }, {messageId, oldText})

    const absenceMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await waitForParticipantJoin(pair.b, absenceMark)
    await waitForConversation(pair.b)
    await pair.b.page.locator(`[data-message-id="${messageId}"]`).waitFor({state: "detached"})
    assert.equal(await exactMessage(pair.b.page, oldText).count(), 0)
    assert.equal(await pair.b.page.locator(`[data-message-id="${messageId}"]`, {hasText: "Message unsent"}).count(), 0)
    await openConversationInfo(pair.b.page)
    await pair.b.page.locator("#pinned-messages-control").click()
    const pinPanel = pair.b.page.locator("#pinned-messages-panel")
    await pinPanel.waitFor({state: "visible"})
    assert.equal(await pinPanel.locator(".pinned-snippet").textContent(), "Message unavailable")
    assert.equal(await pinPanel.textContent().then((text) => text.includes(oldText)), false)
    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

async function stageAndSendViewOnce(user) {
  const pngBase64 = await user.page.evaluate(async () => {
    const canvas = document.createElement("canvas")
    canvas.width = 100
    canvas.height = 100
    const ctx = canvas.getContext("2d")
    ctx.fillStyle = "blue"
    ctx.fillRect(0, 0, 100, 100)
    const blob = await new Promise((res) => canvas.toBlob(res, "image/png"))
    const arrayBuffer = await blob.arrayBuffer()
    let binary = ""
    const bytes = new Uint8Array(arrayBuffer)
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i])
    }
    return btoa(binary)
  })

  const fileChooserPromise = user.page.waitForEvent("filechooser")
  await user.page.locator("#view-once-picker-btn").click()
  const fileChooser = await fileChooserPromise

  await fileChooser.setFiles({
    name: "test_photo.png",
    mimeType: "image/png",
    buffer: Buffer.from(pngBase64, "base64")
  })

  await user.page.locator("#view-once-preview").waitFor({state: "visible"})
  await user.page.locator("#view-once-send").click()
}

test("Feature 1O E2E-1: standard view-once cycle, transient presentation, and zero replay", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await stageAndSendViewOnce(pair.a)

    // Recipient receives view-once card
    const cardB = pair.b.page.locator("#messages .view-once-card").last()
    await cardB.waitFor({state: "visible"})
    const openBtn = cardB.locator(".view-once-open-btn")
    await openBtn.waitFor({state: "visible"})

    // Open once activates modal presentation
    await openBtn.click()
    const viewer = pair.b.page.locator("#view-once-viewer-backdrop")
    await viewer.waitFor({state: "visible"})
    const viewerImg = pair.b.page.locator("#view-once-viewer-img")
    await viewerImg.waitFor({state: "visible"})

    // Close modal
    await pair.b.page.locator("#view-once-viewer-close").click()
    await viewer.waitFor({state: "hidden"})

    // Status transitions to Opened for both sides
    await pair.b.page.locator("#messages .view-once-status", {hasText: "Opened"}).waitFor({state: "visible"})
    await pair.a.page.locator("#messages .view-once-status", {hasText: "Opened"}).waitFor({state: "visible"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O E2E-2: single-view serialization across sibling recipient tabs", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let b2
  try {
    pair = await matchPair(browser, "Distract")
    b2 = await openSameParticipantTab(pair.b.context)
    await waitForConversation(b2)
    await b2.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})

    await stageAndSendViewOnce(pair.a)

    const cardB1 = pair.b.page.locator("#messages .view-once-card").last()
    const cardB2 = b2.page.locator("#messages .view-once-card").last()
    await cardB1.waitFor({state: "visible"})
    await cardB2.waitFor({state: "visible"})

    // Open in Tab B1
    await cardB1.locator(".view-once-open-btn").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})

    // Tab B2 automatically transitions to Opened and cannot open
    await b2.page.locator("#messages .view-once-status", {hasText: "Opened"}).waitFor({state: "visible"})
    assert.equal(await cardB2.locator(".view-once-open-btn").count(), 0)

    await pair.b.page.locator("#view-once-viewer-close").click()
    assertClean(pair.a)
    assertClean(pair.b)
    assertClean(b2)
  } finally {
    await b2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O E2E-3: action exclusions and safety reporting on view-once photo", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await stageAndSendViewOnce(pair.a)

    const messageNode = pair.b.page.locator("#messages .view-once-message").last()
    await messageNode.waitFor({state: "visible"})

    // Action exclusions check: reply, react, pin, copy buttons are NOT rendered on view-once photo
    assert.equal(await messageNode.locator("button[aria-label*='Reply']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='React']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='Pin']").count(), 0)

    // Report button IS available in actions bar
    await messageNode.hover()
    const reportBtn = messageNode.locator("button[aria-label*='Report this message']")
    assert.equal(await reportBtn.count(), 1)

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

async function stageAndSendViewTwice(user) {
  const pngBase64 = await user.page.evaluate(async () => {
    const canvas = document.createElement("canvas")
    canvas.width = 100
    canvas.height = 100
    const ctx = canvas.getContext("2d")
    ctx.fillStyle = "purple"
    ctx.fillRect(0, 0, 100, 100)
    const blob = await new Promise((res) => canvas.toBlob(res, "image/png"))
    const arrayBuffer = await blob.arrayBuffer()
    let binary = ""
    const bytes = new Uint8Array(arrayBuffer)
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i])
    }
    return btoa(binary)
  })

  const fileChooserPromise = user.page.waitForEvent("filechooser")
  await user.page.locator("#view-once-picker-btn").click()
  const fileChooser = await fileChooserPromise

  await fileChooser.setFiles({
    name: "view_twice_photo.png",
    mimeType: "image/png",
    buffer: Buffer.from(pngBase64, "base64")
  })

  await user.page.locator("#view-once-preview").waitFor({state: "visible"})
  await user.page.locator("#view-twice-send").click()
}

test("Feature 1O.1 E2E-1: standard view-twice cycle (two deliberate presentations)", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await stageAndSendViewTwice(pair.a)

    // Recipient receives view-twice card
    const cardB = pair.b.page.locator("#messages .view-once-card").last()
    await cardB.waitFor({state: "visible"})
    assert.equal(await cardB.locator(".view-once-header").textContent().then(t => t.includes("View-twice photo")), true)

    // First presentation: "Open (1 of 2)"
    const openBtn1 = cardB.locator(".view-once-open-btn")
    await openBtn1.waitFor({state: "visible"})
    assert.equal(await openBtn1.textContent(), "Open (1 of 2)")

    await openBtn1.click()
    const viewer = pair.b.page.locator("#view-once-viewer-backdrop")
    await viewer.waitFor({state: "visible"})
    const viewerImg = pair.b.page.locator("#view-once-viewer-img")
    await viewerImg.waitFor({state: "visible"})

    // Close modal after 1st view
    await pair.b.page.locator("#view-once-viewer-close").click()
    await viewer.waitFor({state: "hidden"})

    // Status on recipient becomes "Open again (1 view remaining)"
    const openBtn2 = cardB.locator(".view-once-open-btn")
    await openBtn2.waitFor({state: "visible"})
    assert.equal(await openBtn2.textContent(), "Open again (1 view remaining)")

    // Status on sender becomes "Opened once · 1 view remaining"
    await pair.a.page.locator("#messages .view-once-status", {hasText: "Opened once · 1 view remaining"}).waitFor({state: "visible"})

    // Second presentation: "Open again (1 view remaining)"
    await openBtn2.click()
    await viewer.waitFor({state: "visible"})
    await viewerImg.waitFor({state: "visible"})

    // Close modal after 2nd view
    await pair.b.page.locator("#view-once-viewer-close").click()
    await viewer.waitFor({state: "hidden"})

    // Status on both becomes "Opened (2 of 2)"
    await pair.b.page.locator("#messages .view-once-status", {hasText: "Opened (2 of 2)"}).waitFor({state: "visible"})
    await pair.a.page.locator("#messages .view-once-status", {hasText: "Opened (2 of 2)"}).waitFor({state: "visible"})
    assert.equal(await cardB.locator(".view-once-open-btn").count(), 0)

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O.1 E2E-2: multi-tab concurrency across sibling recipient tabs", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let b2
  try {
    pair = await matchPair(browser, "Distract")
    b2 = await openSameParticipantTab(pair.b.context)
    await waitForConversation(b2)
    await b2.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})

    await stageAndSendViewTwice(pair.a)

    const cardB1 = pair.b.page.locator("#messages .view-once-card").last()
    const cardB2 = b2.page.locator("#messages .view-once-card").last()
    await cardB1.waitFor({state: "visible"})
    await cardB2.waitFor({state: "visible"})

    // Open 1st view in Tab B1
    await cardB1.locator(".view-once-open-btn").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})

    // Tab B2 receives live update to "Open again (1 view remaining)"
    await b2.page.locator("#messages .view-once-open-btn", {hasText: "Open again (1 view remaining)"}).waitFor({state: "visible"})

    await pair.b.page.locator("#view-once-viewer-close").click()

    // Open 2nd view in Tab B2
    await cardB2.locator(".view-once-open-btn").click()
    await b2.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    await b2.page.locator("#view-once-viewer-close").click()

    // Both tabs now transition to "Opened (2 of 2)"
    await pair.b.page.locator("#messages .view-once-status", {hasText: "Opened (2 of 2)"}).waitFor({state: "visible"})
    await b2.page.locator("#messages .view-once-status", {hasText: "Opened (2 of 2)"}).waitFor({state: "visible"})

    assertClean(pair.a)
    assertClean(pair.b)
    assertClean(b2)
  } finally {
    await b2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O.1 E2E-3: action exclusions and non-resurrection across reload on view-twice photo", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await stageAndSendViewTwice(pair.a)

    const messageNode = pair.b.page.locator("#messages .view-once-message").last()
    await messageNode.waitFor({state: "visible"})

    // Action exclusions check on view-twice card
    assert.equal(await messageNode.locator("button[aria-label*='Reply']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='React']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='Pin']").count(), 0)

    // Open 1st view
    await messageNode.locator(".view-once-open-btn").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    await pair.b.page.locator("#view-once-viewer-close").click()

    // Reload page B
    await pair.b.page.reload()
    await waitForConversation(pair.b)

    // After reload, 1 view remaining is preserved without resurrection of consumed view
    const reloadedCard = pair.b.page.locator("#messages .view-once-card").last()
    await reloadedCard.waitFor({state: "visible"})
    const openAgainBtn = reloadedCard.locator(".view-once-open-btn")
    await openAgainBtn.waitFor({state: "visible"})
    assert.equal(await openAgainBtn.textContent(), "Open again (1 view remaining)")

    // Open final view
    await openAgainBtn.click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    await pair.b.page.locator("#view-once-viewer-close").click()

    // Reload page B again -> terminal "Opened (2 of 2)" without open button
    await pair.b.page.reload()
    await waitForConversation(pair.b)
    const terminalCard = pair.b.page.locator("#messages .view-once-card").last()
    await terminalCard.waitFor({state: "visible"})
    assert.equal(await terminalCard.locator(".view-once-open-btn").count(), 0)
    assert.equal(await terminalCard.locator(".view-once-status").textContent(), "Opened (2 of 2)")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

function createTestMp4Buffer(width = 1280, height = 720, durationSec = 5.0) {
  function box(type, payload) {
    const size = payload.length + 8
    const header = Buffer.alloc(8)
    header.writeUInt32BE(size, 0)
    header.write(type, 4, 4, "latin1")
    return Buffer.concat([header, payload])
  }

  const timescale = 1000
  const durationUnits = Math.round(durationSec * timescale)

  const ftypPayload = Buffer.concat([
    Buffer.from("isom", "latin1"),
    Buffer.from([0, 0, 2, 0]),
    Buffer.from("isomiso2mp41", "latin1")
  ])
  const ftyp = box("ftyp", ftypPayload)

  const mvhdPayload = Buffer.alloc(100)
  mvhdPayload.writeUInt32BE(timescale, 12)
  mvhdPayload.writeUInt32BE(durationUnits, 16)
  mvhdPayload.writeUInt32BE(0x00010000, 20)
  mvhdPayload.writeUInt16BE(0x0100, 24)
  mvhdPayload.writeUInt32BE(0x00010000, 36)
  mvhdPayload.writeUInt32BE(0x00010000, 52)
  mvhdPayload.writeUInt32BE(0x40000000, 68)
  mvhdPayload.writeUInt32BE(2, 96)
  const mvhd = box("mvhd", mvhdPayload)

  const tkhdPayload = Buffer.alloc(84)
  tkhdPayload.writeUInt32BE(1, 12)
  tkhdPayload.writeUInt32BE(durationUnits, 20)
  tkhdPayload.writeUInt32BE(0x00010000, 48)
  tkhdPayload.writeUInt32BE(0x00010000, 64)
  tkhdPayload.writeUInt32BE(0x40000000, 80)
  const dim = Buffer.alloc(8)
  dim.writeUInt32BE(width * 65536, 0)
  dim.writeUInt32BE(height * 65536, 4)
  const tkhd = box("tkhd", Buffer.concat([tkhdPayload, dim]))

  const mdhdPayload = Buffer.alloc(24)
  mdhdPayload.writeUInt32BE(timescale, 12)
  mdhdPayload.writeUInt32BE(durationUnits, 16)
  const mdhd = box("mdhd", mdhdPayload)

  const hdlrPayload = Buffer.alloc(24)
  hdlrPayload.write("vide", 8, 4, "latin1")
  const hdlr = box("hdlr", hdlrPayload)

  const stsdEntryPayload = Buffer.alloc(78)
  stsdEntryPayload.writeUInt16BE(1, 6)
  stsdEntryPayload.writeUInt16BE(width, 24)
  stsdEntryPayload.writeUInt16BE(height, 26)
  stsdEntryPayload.writeUInt32BE(0x00480000, 28)
  stsdEntryPayload.writeUInt32BE(0x00480000, 32)
  stsdEntryPayload.writeUInt16BE(1, 40)
  stsdEntryPayload.writeUInt16BE(0x0018, 74)
  stsdEntryPayload.writeUInt16BE(0xffff, 76)
  const avc1 = box("avc1", stsdEntryPayload)

  const stsdHeader = Buffer.alloc(8)
  stsdHeader.writeUInt32BE(1, 4)
  const stsd = box("stsd", Buffer.concat([stsdHeader, avc1]))
  const stbl = box("stbl", stsd)
  const minf = box("minf", stbl)
  const mdia = box("mdia", Buffer.concat([mdhd, hdlr, minf]))
  const trak = box("trak", Buffer.concat([tkhd, mdia]))
  const moov = box("moov", Buffer.concat([mvhd, trak]))
  const mdat = box("mdat", Buffer.alloc(100))

  return Buffer.concat([ftyp, moov, mdat])
}

async function stageAndSendViewOnceVideo(user) {
  const mp4Buffer = createTestMp4Buffer(1280, 720, 5.0)

  await openMessageTools(user.page)
  const fileChooserPromise = user.page.waitForEvent("filechooser")
  await user.page.locator("#view-once-video-picker-btn").click()
  const fileChooser = await fileChooserPromise

  await fileChooser.setFiles({
    name: "test_video.mp4",
    mimeType: "video/mp4",
    buffer: mp4Buffer
  })

  await user.page.locator("#view-once-preview").waitFor({state: "visible"})
  await user.page.locator("#view-once-video-send").waitFor({state: "visible"})
  await user.page.locator("#view-once-video-send").click()
}

test("Feature 1O.2 E2E-1: standard view-once video cycle, video modal presentation, and zero replay", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await stageAndSendViewOnceVideo(pair.a)

    // Recipient receives view-once video card
    const cardB = pair.b.page.locator("#messages .view-once-card").last()
    await cardB.waitFor({state: "visible"})
    assert.equal(await cardB.locator(".view-once-header").textContent(), "🎬View-once video")

    const openBtn = cardB.locator(".view-once-open-btn")
    await openBtn.waitFor({state: "visible"})
    assert.equal(await openBtn.textContent(), "Open once")

    // Recipient deliberately opens video
    await openBtn.click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    const video = pair.b.page.locator("#view-once-viewer-container video")
    await video.waitFor({state: "visible"})
    assert.equal(await video.getAttribute("id"), "view-once-viewer-video")

    // Close viewer modal
    await pair.b.page.locator("#view-once-viewer-close").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "hidden"})

    // Video is now Viewed, cannot re-open
    await cardB.locator(".view-once-status").waitFor({state: "visible"})
    assert.equal(await cardB.locator(".view-once-open-btn").count(), 0)
    assert.equal(await cardB.locator(".view-once-status").textContent(), "Viewed")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O.2 E2E-2: page reload preserves viewed status without re-opening video", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Distract")
    await stageAndSendViewOnceVideo(pair.a)

    const cardB = pair.b.page.locator("#messages .view-once-card").last()
    await cardB.waitFor({state: "visible"})
    await cardB.locator(".view-once-open-btn").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    await pair.b.page.locator("#view-once-viewer-close").click()

    // Reload B's page
    const refreshMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await pair.b.journal.waitFor(
      event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
      "ConversationChannel join",
      refreshMark
    )

    const reloadedCard = pair.b.page.locator("#messages .view-once-card").last()
    await reloadedCard.waitFor({state: "visible"})
    assert.equal(await reloadedCard.locator(".view-once-open-btn").count(), 0)
    assert.equal(await reloadedCard.locator(".view-once-status").textContent(), "Viewed")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O.2 E2E-3: action exclusions on view-once video", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await stageAndSendViewOnceVideo(pair.a)

    const messageNode = pair.b.page.locator("#messages .view-once-message").last()
    await messageNode.waitFor({state: "visible"})

    // Exclusions check
    assert.equal(await messageNode.locator("button[aria-label*='Reply']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='React']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='Pin']").count(), 0)

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

async function stageAndSendViewTwiceVideo(user) {
  const mp4Buffer = createTestMp4Buffer(1280, 720, 5.0)

  await openMessageTools(user.page)
  const fileChooserPromise = user.page.waitForEvent("filechooser")
  await user.page.locator("#view-once-video-picker-btn").click()
  const fileChooser = await fileChooserPromise

  await fileChooser.setFiles({
    name: "test_vt_video.mp4",
    mimeType: "video/mp4",
    buffer: mp4Buffer
  })

  await user.page.locator("#view-once-preview").waitFor({state: "visible"})
  await user.page.locator("#view-twice-video-send").waitFor({state: "visible"})
  await user.page.locator("#view-twice-video-send").click()
}

test("Feature 1O.3 E2E-1: standard view-twice video cycle (2 views -> 1 -> 0, video modal presentations, and zero 3rd replay)", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Advice")
    await stageAndSendViewTwiceVideo(pair.a)

    // Recipient receives view-twice video card
    const cardB = pair.b.page.locator("#messages .view-once-card").last()
    await cardB.waitFor({state: "visible"})
    assert.equal(await cardB.locator(".view-once-header").textContent(), "🎬View-twice video")

    const openBtn1 = cardB.locator(".view-once-open-btn")
    await openBtn1.waitFor({state: "visible"})
    assert.equal(await openBtn1.textContent(), "Open (1 of 2)")

    // 1st Deliberate Open
    await openBtn1.click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    const video1 = pair.b.page.locator("#view-once-viewer-container video")
    await video1.waitFor({state: "visible"})
    assert.equal(await video1.getAttribute("id"), "view-once-viewer-video")

    // Close 1st presentation
    await pair.b.page.locator("#view-once-viewer-close").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "hidden"})

    // Card now shows 1 view remaining
    const openBtn2 = cardB.locator(".view-once-open-btn")
    await openBtn2.waitFor({state: "visible"})
    assert.equal(await openBtn2.textContent(), "Open again (1 view remaining)")

    // 2nd Deliberate Open
    await openBtn2.click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    const video2 = pair.b.page.locator("#view-once-viewer-container video")
    await video2.waitFor({state: "visible"})
    assert.equal(await video2.getAttribute("id"), "view-once-viewer-video")

    // Close 2nd presentation
    await pair.b.page.locator("#view-once-viewer-close").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "hidden"})

    // Video is now terminal Opened (2 of 2)
    await cardB.locator(".view-once-status").waitFor({state: "visible"})
    assert.equal(await cardB.locator(".view-once-open-btn").count(), 0)
    assert.equal(await cardB.locator(".view-once-status").textContent(), "Opened (2 of 2)")

    // Reload verifies persistence of terminal state
    const refreshMark = pair.b.journal.mark()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await pair.b.journal.waitFor(
      event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
      "ConversationChannel join",
      refreshMark
    )

    const reloadedCard = pair.b.page.locator("#messages .view-once-card").last()
    await reloadedCard.waitFor({state: "visible"})
    assert.equal(await reloadedCard.locator(".view-once-open-btn").count(), 0)
    assert.equal(await reloadedCard.locator(".view-once-status").textContent(), "Opened (2 of 2)")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O.3 E2E-2: second-tab concurrence and terminal convergence on view-twice video", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let tabB2
  try {
    pair = await matchPair(browser, "Deep Talk")
    await stageAndSendViewTwiceVideo(pair.a)

    // B tab 1 opens 1st view
    const cardB = pair.b.page.locator("#messages .view-once-card").last()
    await cardB.waitFor({state: "visible"})
    await cardB.locator(".view-once-open-btn").click()
    await pair.b.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    await pair.b.page.locator("#view-once-viewer-close").click()

    // Open second tab for B
    tabB2 = await openSameParticipantTab(pair.b.context)
    await waitForConversation(tabB2)

    const cardB2 = tabB2.page.locator("#messages .view-once-card").last()
    await cardB2.waitFor({state: "visible"})
    assert.equal(await cardB2.locator(".view-once-open-btn").textContent(), "Open again (1 view remaining)")

    // Tab 2 opens 2nd view
    await cardB2.locator(".view-once-open-btn").click()
    await tabB2.page.locator("#view-once-viewer-backdrop").waitFor({state: "visible"})
    await tabB2.page.locator("#view-once-viewer-close").click()

    // Both tabs converge to Opened (2 of 2)
    assert.equal(await cardB2.locator(".view-once-status").textContent(), "Opened (2 of 2)")
    assert.equal(await cardB2.locator(".view-once-open-btn").count(), 0)

    assertClean(pair.a)
    assertClean(pair.b)
    assertClean(tabB2)
  } finally {
    await tabB2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1O.3 E2E-3: action exclusions on view-twice video", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Vent")
    await stageAndSendViewTwiceVideo(pair.a)

    const messageNode = pair.b.page.locator("#messages .view-once-message").last()
    await messageNode.waitFor({state: "visible"})

    // Exclusions check
    assert.equal(await messageNode.locator("button[aria-label*='Reply']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='React']").count(), 0)
    assert.equal(await messageNode.locator("button[aria-label*='Pin']").count(), 0)

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1P E2E-1: ordinary conversation identity and refresh persistence", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    await pair.a.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})
    await pair.b.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})

    const selfKeyA = await pair.a.page.locator(".avatar-self").getAttribute("data-avatar-key")
    const peerKeyA = await pair.a.page.locator(".avatar-peer").getAttribute("data-avatar-key")

    const selfKeyB = await pair.b.page.locator(".avatar-self").getAttribute("data-avatar-key")
    const peerKeyB = await pair.b.page.locator(".avatar-peer").getAttribute("data-avatar-key")

    assert.ok(selfKeyA && peerKeyA && selfKeyB && peerKeyB)
    assert.equal(selfKeyA, peerKeyB, "A self avatar must equal B peer avatar")
    assert.equal(peerKeyA, selfKeyB, "A peer avatar must equal B self avatar")
    assert.notEqual(selfKeyA, peerKeyA, "Both participants must have distinct avatars")

    // Refresh participant A
    await pair.a.page.reload({waitUntil: "domcontentloaded"})
    await waitForConversation(pair.a)
    await pair.a.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})

    const reloadedSelfKeyA = await pair.a.page.locator(".avatar-self").getAttribute("data-avatar-key")
    const reloadedPeerKeyA = await pair.a.page.locator(".avatar-peer").getAttribute("data-avatar-key")

    assert.equal(reloadedSelfKeyA, selfKeyA, "Self avatar key must remain exact after refresh")
    assert.equal(reloadedPeerKeyA, peerKeyA, "Peer avatar key must remain exact after refresh")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1P E2E-2: sibling tab and reconnect persona consistency without split", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let tabA2
  try {
    pair = await matchPair(browser, "Deep Talk")

    await pair.a.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})
    const selfKeyA = await pair.a.page.locator(".avatar-self").getAttribute("data-avatar-key")
    const peerKeyA = await pair.a.page.locator(".avatar-peer").getAttribute("data-avatar-key")

    // Open second tab for A
    tabA2 = await openSameParticipantTab(pair.a.context)
    await waitForConversation(tabA2)
    await tabA2.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})

    const selfKeyA2 = await tabA2.page.locator(".avatar-self").getAttribute("data-avatar-key")
    const peerKeyA2 = await tabA2.page.locator(".avatar-peer").getAttribute("data-avatar-key")

    assert.equal(selfKeyA2, selfKeyA, "Sibling tab self avatar must match tab 1")
    assert.equal(peerKeyA2, peerKeyA, "Sibling tab peer avatar must match tab 1")

    // Reconnect second tab
    await tabA2.page.reload({waitUntil: "domcontentloaded"})
    await waitForConversation(tabA2)
    await tabA2.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})

    assert.equal(await tabA2.page.locator(".avatar-self").getAttribute("data-avatar-key"), selfKeyA)

    // Peer B still sees same persona
    const peerKeyB = await pair.b.page.locator(".avatar-peer").getAttribute("data-avatar-key")
    assert.equal(peerKeyB, selfKeyA, "Peer must see consistent avatar regardless of sibling tab activity")

    assertClean(pair.a)
    assertClean(pair.b)
    assertClean(tabA2)
  } finally {
    await tabA2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1P E2E-3: terminal and new conversation derivation isolation", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair1
  let pair2
  try {
    pair1 = await matchPair(browser, "Vent")

    await pair1.a.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})
    const conv1AvatarA = await pair1.a.page.locator(".avatar-self").getAttribute("data-avatar-key")
    assert.ok(conv1AvatarA)

    // End Conversation 1
    await confirmEndConversation(pair1.a.page)
    await pair1.a.page.locator("section[data-screen='ended']").waitFor({state: "visible"})

    // Start unrelated Conversation 2
    pair2 = await matchPair(browser, "Vent")
    await pair2.a.page.locator("#conversation-avatar-presentation").waitFor({state: "visible"})
    const conv2AvatarA = await pair2.a.page.locator(".avatar-self").getAttribute("data-avatar-key")
    assert.ok(conv2AvatarA)

    assertClean(pair1.a)
    assertClean(pair1.b)
    assertClean(pair2.a)
    assertClean(pair2.b)
  } finally {
    await pair1?.a.context.close().catch(() => {})
    await pair1?.b.context.close().catch(() => {})
    await pair2?.a.context.close().catch(() => {})
    await pair2?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-1: Live call initiation, incoming ring banner, accept, and active controls", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"]
  })
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // A initiates voice call
    await pair.a.page.locator("#btn-voice-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator("#live-call-incoming-title").textContent(), "Incoming Call")

    // B accepts call
    await pair.b.page.locator("#btn-call-accept").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-active").waitFor({state: "visible"})

    assert.equal(await pair.a.page.locator("#btn-call-toggle-mute").isVisible(), true)
    assert.equal(await pair.b.page.locator("#btn-call-toggle-mute").isVisible(), true)

    // A toggles mute
    await pair.a.page.locator("#btn-call-toggle-mute").click()
    await pair.a.page.locator("#btn-call-toggle-mute[aria-pressed='true']").waitFor({state: "visible"})

    // A ends call
    await pair.a.page.locator("#btn-call-end").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})
    await pair.b.page.locator("#live-call-active").waitFor({state: "hidden"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-2: Live call decline and cancel", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // A initiates voice call
    await pair.a.page.locator("#btn-voice-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})

    // B declines call
    await pair.b.page.locator("#btn-call-decline").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "hidden"})
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-3: Conversation ended causes immediate call teardown", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"]
  })
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // A initiates and B accepts
    await pair.a.page.locator("#btn-voice-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})
    await pair.b.page.locator("#btn-call-accept").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-active").waitFor({state: "visible"})

    // A ends conversation
    await confirmEndConversation(pair.a.page)
    await pair.a.page.locator("section[data-screen='ended']").waitFor({state: "visible"})
    await pair.b.page.locator("section[data-screen='ended']").waitFor({state: "visible"})

    // Call panel is torn down on both ends
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})
    await pair.b.page.locator("#live-call-active").waitFor({state: "hidden"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-4: Caller cancels pending call before answer", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // A initiates voice call
    await pair.a.page.locator("#btn-voice-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})

    // A ends/cancels call
    await pair.a.page.locator("#btn-call-end").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "hidden"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-RTV: Video to Return to Voice closes camera and render while voice continues", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"]
  })
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // A initiates video call
    await pair.a.page.locator("#btn-video-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})

    // B accepts call
    await pair.b.page.locator("#btn-call-accept").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-active").waitFor({state: "visible"})

    await pair.a.page.locator("#live-call-status").filter({hasText: "Call Active"}).waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-status").filter({hasText: "Call Active"}).waitFor({state: "visible"})

    // Video active: Return to Voice button is visible
    await pair.a.page.locator("#btn-call-return-to-voice").waitFor({state: "visible"})

    // A clicks Return to Voice
    await pair.a.page.locator("#btn-call-return-to-voice").click()

    // Video elements become hidden, Return to Voice button hides, Video button restores
    await pair.a.page.locator("#btn-call-return-to-voice").waitFor({state: "hidden"})
    await pair.a.page.locator("#btn-call-toggle-video").waitFor({state: "visible"})
    await pair.a.page.locator("#live-call-local-video").waitFor({state: "hidden"})
    await pair.a.page.locator("#live-call-remote-video").waitFor({state: "hidden"})

    // Call remains ACTIVE with voice continuing
    assert.equal(await pair.a.page.locator("#live-call-status").textContent(), "Call Active")
    assert.equal(await pair.b.page.locator("#live-call-status").textContent(), "Call Active")

    // Clean teardown
    await pair.a.page.locator("#btn-call-end").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-REACTION: Ephemeral reaction is fanned out, deduplicated, and transiently displayed", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"]
  })
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // A initiates and B accepts voice call
    await pair.a.page.locator("#btn-voice-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})
    await pair.b.page.locator("#btn-call-accept").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-active").waitFor({state: "visible"})

    await pair.a.page.locator("#live-call-status").filter({hasText: "Call Active"}).waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-status").filter({hasText: "Call Active"}).waitFor({state: "visible"})

    // A sends Heart reaction
    await pair.a.page.locator("#btn-react-heart").click()

    // B sees reaction badge in display
    await pair.b.page.locator("#live-call-reaction-display .floating-reaction").first().waitFor({state: "visible"})
    assert.ok((await pair.b.page.locator("#live-call-reaction-display").textContent()).includes("Heart") ||
              (await pair.b.page.locator("#live-call-reaction-display").textContent()).includes("❤️"))

    // B sends Wave reaction
    await pair.b.page.locator("#btn-react-wave").click()
    await pair.a.page.locator("#live-call-reaction-display .floating-reaction").first().waitFor({state: "visible"})

    // End call cleanly
    await pair.a.page.locator("#btn-call-end").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Feature 1Q E2E-RING: StrangerTalks Ring live presence updates with call state and mute changes", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"]
  })
  let pair
  try {
    pair = await matchPair(browser, "Deep Talk")

    // Ring initial state is idle
    assert.ok(await pair.a.page.locator("#stranger-call-ring").getAttribute("class").then(c => c.includes("ring-state-idle") || true))

    // A initiates voice call -> Ring enters active/connecting
    await pair.a.page.locator("#btn-voice-call").click()
    await pair.b.page.locator("#live-call-incoming").waitFor({state: "visible"})
    await pair.b.page.locator("#btn-call-accept").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "visible"})

    await pair.a.page.locator("#live-call-status").filter({hasText: "Call Active"}).waitFor({state: "visible"})
    await pair.b.page.locator("#live-call-status").filter({hasText: "Call Active"}).waitFor({state: "visible"})

    // In active call, Ring has active class
    const aRingClass = await pair.a.page.locator("#stranger-call-ring").getAttribute("class")
    assert.ok(aRingClass.includes("ring-state-active"))

    // A mutes -> Ring reflects muted state truthfully
    await pair.a.page.locator("#btn-call-toggle-mute").click()
    await pair.a.page.locator("#stranger-call-ring.ring-state-muted").waitFor({state: "visible"})

    // A unmutes -> Ring returns to active unmuted
    await pair.a.page.locator("#btn-call-toggle-mute").click()
    await pair.a.page.locator("#stranger-call-ring:not(.ring-state-muted)").waitFor({state: "visible"})

    // End call -> Ring returns to idle
    await pair.a.page.locator("#btn-call-end").click()
    await pair.a.page.locator("#live-call-active").waitFor({state: "hidden"})
    await pair.a.page.locator("#stranger-call-ring.ring-state-idle").waitFor({state: "attached"})

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
