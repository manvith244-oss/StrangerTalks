import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT_TIMEOUT_MS = 15_000

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
        reject(new Error(`Timed out waiting for ${label}; recent events: ${JSON.stringify(this.events.slice(-20))}`))
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
  page.on("websocket", websocket => {
    journal.add({type: "websocket_open", url: websocket.url()})
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

async function bootFresh(browser, {
  controllableSocket = false,
  viewport = {width: 1280, height: 800},
  mobile = false,
  touch = false
} = {}) {
  const context = await browser.newContext({
    viewport,
    isMobile: mobile,
    hasTouch: touch,
    deviceScaleFactor: mobile ? 2 : 1
  })
  const socketControl = {
    offline: false,
    routes: new Set()
  }

  if (controllableSocket) {
    await context.routeWebSocket(/\/socket\/websocket/, route => {
      if (socketControl.offline) {
        route.close({code: 1001, reason: "intentional Team 3 browser outage"})
        return
      }
      const serverRoute = route.connectToServer()
      serverRoute.onMessage(payload => route.send(payload))
      socketControl.routes.add({page: route, server: serverRoute})
    })
  }

  const page = await context.newPage()
  const observed = await observePage(context, page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")

  const bootstrap = await observed.journal.waitFor(
    event => event.type === "participant_bootstrap",
    "participant bootstrap"
  )
  assert.ok(bootstrap.status >= 200 && bootstrap.status < 300, "participant bootstrap succeeds")

  const joined = await waitForParticipantJoin(observed)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("#conversation-language").selectOption("en")

  return {
    context,
    socketControl,
    participantTopic: joined.topic,
    participantId: joined.topic.split(":")[1],
    disconnectSocket: async () => {
      socketControl.offline = true
      await Promise.all([...socketControl.routes].flatMap(routes => [
        routes.page.close({code: 1001, reason: "intentional Team 3 browser outage"}),
        routes.server.close({code: 1001, reason: "intentional Team 3 browser outage"})
      ]))
      socketControl.routes.clear()
    },
    reconnectSocket: () => {
      socketControl.offline = false
    },
    injectServerFrame: frame => {
      const routes = [...socketControl.routes]
      assert.ok(routes.length > 0, "controllable WebSocket route exists")
      routes.at(-1).page.send(JSON.stringify(frame))
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
  return {
    ...observed,
    participantTopic: joined.topic,
    participantId: joined.topic.split(":")[1]
  }
}

async function clickDoorAndQueue(page, label = "Advice") {
  const door = page.locator(`button.door:has-text("${label}")`)
  await door.waitFor({state: "visible"})
  assert.equal(await door.isEnabled(), true, `${label} is enabled`)
  await door.click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
}

async function waitForConversation(observed, from = 0) {
  await observed.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
  return observed.journal.waitFor(
    event => event.type === "frame_sent" &&
      event.topic?.startsWith("conversation:") &&
      event.event === "phx_join",
    "ConversationChannel join",
    from
  )
}

async function matchPair(browser, {
  controllableA = false,
  controllableB = false,
  viewportA = {width: 1280, height: 800},
  viewportB = {width: 1280, height: 800},
  mobileA = false,
  mobileB = false,
  touchA = false,
  touchB = false
} = {}) {
  const a = await bootFresh(browser, {
    controllableSocket: controllableA,
    viewport: viewportA,
    mobile: mobileA,
    touch: touchA
  })
  const b = await bootFresh(browser, {
    controllableSocket: controllableB,
    viewport: viewportB,
    mobile: mobileB,
    touch: touchB
  })

  await clickDoorAndQueue(a.page)
  await b.page.locator('button.door:has-text("Advice")').click()
  const [joinA, joinB] = await Promise.all([waitForConversation(a), waitForConversation(b)])
  assert.equal(joinA.topic, joinB.topic, "both isolated participants join the same authoritative Conversation")
  return {a, b, conversationTopic: joinA.topic}
}

function exactMessage(page, text) {
  return page.locator("#messages li", {hasText: text})
}

async function sendMessage(observed, text) {
  await observed.page.locator("#message-input").fill(text)
  await observed.page.locator("#message-form button.primary").click()
  const message = exactMessage(observed.page, text)
  await message.waitFor({state: "visible"})
  return message
}

async function sendAndReceive(sender, receiver, text, conversationTopic) {
  const senderMark = sender.journal.mark()
  const receiverMark = receiver.journal.mark()
  const own = await sendMessage(sender, text)

  const sent = await sender.journal.waitFor(
    event => event.type === "frame_sent" &&
      event.topic === conversationTopic &&
      event.event === "message:send" &&
      event.body?.content === text,
    `send ${text}`,
    senderMark
  )
  assert.ok(sent.ref, "message send is result-bearing")

  await receiver.journal.waitFor(
    event => event.type === "frame_received" &&
      event.topic === conversationTopic &&
      event.event === "message:new" &&
      event.body?.content === text,
    `receive ${text}`,
    receiverMark
  )

  const peer = exactMessage(receiver.page, text)
  await peer.waitFor({state: "visible"})
  assert.equal(await own.count(), 1, "sender renders message once")
  assert.equal(await peer.count(), 1, "recipient renders message once")
  return {own, peer}
}

async function openActions(page) {
  const details = page.locator(".conversation-head-actions details.overflow")
  if ((await details.getAttribute("open")) === null) {
    await details.locator("summary").click()
  }
  await details.locator("#end-conversation").waitFor({state: "visible"})
  return details
}

async function endConversation(page) {
  await openActions(page)
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
}

async function waitTerminal(page) {
  await page.waitForFunction(() => !document.querySelector('[data-screen="conversation"]')?.classList.contains("active"))
  assert.equal(await page.locator('[data-screen="conversation"].active').count(), 0)
  assert.equal(await page.locator("#message-input").isVisible(), false)
  for (const selector of [
    "#report-form",
    "#prompt-helper",
    "#expressive-picker",
    "#voice-warning",
    "#voice-preview",
    "#view-once-preview",
    "#end-confirmation-backdrop"
  ]) {
    if (await page.locator(selector).count()) {
      assert.equal(await page.locator(selector).isVisible(), false, `${selector} is not left live after terminal state`)
    }
  }
}

async function assertNoVisibleUuid(observed) {
  const text = await observed.page.locator("body").innerText()
  assert.equal(text.includes(observed.participantId), false, "own participant UUID is not visible")
}

function assertClean(observed, {allowSocketFailure = false} = {}) {
  assert.deepEqual(observed.pageErrors, [], "no uncaught page errors")
  assert.deepEqual(observed.consoleErrors, [], "no console errors")
  const failed = observed.failedRequests.filter(request => {
    if (!allowSocketFailure) return true
    return new URL(request.url).pathname !== "/socket/websocket"
  })
  assert.deepEqual(failed, [], "no critical failed requests")
  assert.deepEqual(
    observed.journal.events.filter(event => event.type === "http_error"),
    [],
    "no HTTP error responses"
  )
}

test("Team 3: 320x568 tray dismisses from a genuinely exposed outside surface", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, {
      viewportA: {width: 320, height: 568},
      mobileA: true,
      touchA: true
    })

    const page = pair.a.page
    await page.locator(".ig-compose-plus").click()
    await page.waitForFunction(() => document.querySelector("#message-form")?.classList.contains("ig-tray-open"))

    const exposed = await page.locator(".conversation-identity").evaluate(node => {
      const rect = node.getBoundingClientRect()
      const x = rect.left + Math.min(Math.max(rect.width / 2, 4), Math.max(rect.width - 4, 4))
      const y = rect.top + Math.min(Math.max(rect.height / 2, 4), Math.max(rect.height - 4, 4))
      const hit = document.elementFromPoint(x, y)
      return {
        top: rect.top,
        bottom: rect.bottom,
        x,
        y,
        hitInsideComposer: Boolean(hit?.closest("#message-form")),
        hitTag: hit?.tagName || null
      }
    })

    assert.ok(exposed.top >= -1 && exposed.bottom <= 569, "Conversation identity remains physically exposed")
    assert.equal(exposed.hitInsideComposer, false, "chosen outside surface is not covered by composer/tray")

    await page.locator(".conversation-identity").click()
    await page.waitForFunction(() => !document.querySelector("#message-form")?.classList.contains("ig-tray-open"))
    assert.equal(await page.locator(".ig-compose-plus").getAttribute("aria-expanded"), "false")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 3: complete isolated two-browser Conversation journey converges terminally", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair
    const conversationId = conversationTopic.replace("conversation:", "")

    assert.match(conversationId, /^[0-9a-f-]{36}$/i)
    await assertNoVisibleUuid(a)
    await assertNoVisibleUuid(b)

    const first = await sendAndReceive(a, b, "T3 journey message A", conversationTopic)
    assert.equal(await first.own.evaluate(node => node.classList.contains("mine")), true, "sender sees own presentation")
    assert.equal(await first.peer.evaluate(node => node.classList.contains("mine")), false, "recipient sees peer presentation")

    await first.peer.hover()
    await first.peer.locator("button.reply-action-btn").click()
    await b.page.locator("#reply-staging").waitFor({state: "visible"})
    assert.equal(await b.page.locator("#reply-staging-author").textContent(), "Replying to Stranger")
    await b.page.locator("#message-input").fill("T3 journey reply B")
    await b.page.locator("#message-form button.primary").click()

    const replyOnA = exactMessage(a.page, "T3 journey reply B")
    await replyOnA.waitFor({state: "visible"})
    await replyOnA.locator(".reply-quote").waitFor({state: "visible"})
    assert.match(await replyOnA.locator(".reply-snippet").textContent(), /T3 journey message A/)

    await replyOnA.hover()
    await replyOnA.locator("button.react-action-btn").click()
    await replyOnA.locator(".reaction-picker button.reaction-btn[data-emoji='❤️']").click()
    const replyOnB = exactMessage(b.page, "T3 journey reply B")
    await replyOnB.locator(".reaction-pill.peer").waitFor({state: "visible"})
    assert.equal(await replyOnB.locator(".reaction-pill.peer").textContent(), "❤️")

    await replyOnB.focus()
    await replyOnB.getByRole("button", {name: "Edit message"}).click()
    await replyOnB.getByLabel("Edit message text").fill("T3 journey reply B edited")
    await replyOnB.getByRole("button", {name: "Save"}).click()
    await exactMessage(a.page, "T3 journey reply B edited").waitFor({state: "visible"})
    assert.equal(await exactMessage(a.page, "T3 journey reply B").filter({hasNotText: "edited"}).count(), 0)

    await a.page.locator("#message-input").fill("typing only")
    await b.page.locator("#typing").filter({hasText: "The other person is typing"}).waitFor({state: "visible"})
    await b.page.waitForFunction(() => document.querySelector("#typing")?.textContent === "", null, {timeout: 5_000})
    await a.page.locator("#message-input").fill("")
    await sendAndReceive(a, b, "T3 journey final message", conversationTopic)

    assert.equal(await exactMessage(a.page, "T3 journey final message").count(), 1)
    assert.equal(await exactMessage(b.page, "T3 journey final message").count(), 1)
    await assertNoVisibleUuid(a)
    await assertNoVisibleUuid(b)

    await endConversation(a.page)
    await Promise.all([waitTerminal(a.page), waitTerminal(b.page)])

    assertClean(a)
    assertClean(b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 3: Report, Block, and End are physically usable and terminalize truthfully", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let reportPair
  let blockPair
  let endPair

  try {
    reportPair = await matchPair(browser, {
      viewportA: {width: 844, height: 390},
      mobileA: true,
      touchA: true
    })

    await openActions(reportPair.a.page)
    await reportPair.a.page.locator("#report-open").click()
    await reportPair.a.page.locator("#report-form").waitFor({state: "visible"})
    await reportPair.a.page.locator("#report-category").selectOption("HARASSMENT")
    await reportPair.a.page.locator("#report-evidence").fill("Team 3 browser safety-access proof")
    const reportMark = reportPair.a.journal.mark()
    await reportPair.a.page.getByRole("button", {name: "Submit Report"}).click()
    await reportPair.a.journal.waitFor(
      event => event.type === "frame_sent" &&
        event.topic === reportPair.conversationTopic &&
        event.event === "conversation:report" &&
        event.body?.category === "HARASSMENT",
      "Report request",
      reportMark
    )
    await reportPair.a.page.getByRole("status").filter({hasText: "Report submitted for pending review"}).waitFor({state: "visible"})
    assert.equal(await reportPair.a.page.locator("#report-form").isVisible(), false)
    assert.equal(await reportPair.a.page.locator('[data-screen="conversation"].active').count(), 1)

    await openActions(reportPair.a.page)
    await reportPair.a.page.locator("#report-open").click()
    await reportPair.a.page.locator("#report-form").waitFor({state: "visible"})
    await reportPair.a.page.locator("#report-cancel").scrollIntoViewIfNeeded()
    await reportPair.a.page.locator("#report-cancel").click()
    assert.equal(await reportPair.a.page.locator("#report-form").isVisible(), false)

    blockPair = await matchPair(browser, {
      viewportA: {width: 390, height: 844},
      mobileA: true,
      touchA: true
    })
    await openActions(blockPair.a.page)
    blockPair.a.page.once("dialog", dialog => dialog.accept())
    const blockMark = blockPair.a.journal.mark()
    await blockPair.a.page.locator("#block").click()
    await blockPair.a.journal.waitFor(
      event => event.type === "frame_sent" &&
        event.topic === blockPair.conversationTopic &&
        event.event === "conversation:block",
      "Block request",
      blockMark
    )
    await Promise.all([waitTerminal(blockPair.a.page), waitTerminal(blockPair.b.page)])

    endPair = await matchPair(browser, {
      viewportA: {width: 360, height: 740},
      mobileA: true,
      touchA: true
    })
    await endConversation(endPair.a.page)
    await Promise.all([waitTerminal(endPair.a.page), waitTerminal(endPair.b.page)])

    for (const participant of [
      reportPair.a, reportPair.b,
      blockPair.a, blockPair.b,
      endPair.a, endPair.b
    ]) {
      assertClean(participant)
    }
  } finally {
    await reportPair?.a.context.close().catch(() => {})
    await reportPair?.b.context.close().catch(() => {})
    await blockPair?.a.context.close().catch(() => {})
    await blockPair?.b.context.close().catch(() => {})
    await endPair?.a.context.close().catch(() => {})
    await endPair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 3: same-participant tabs and reconnect converge to one terminal Conversation UX", {timeout: 105_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let a2

  try {
    pair = await matchPair(browser, {controllableB: true})
    a2 = await openSameParticipantTab(pair.a.context)
    const a2Join = await waitForConversation(a2)
    assert.equal(a2Join.topic, pair.conversationTopic)
    assert.equal(a2.participantId, pair.a.participantId, "same browser context reuses participant identity")

    await sendAndReceive(pair.a, pair.b, "T3 multi-tab seed", pair.conversationTopic)
    await exactMessage(a2.page, "T3 multi-tab seed").waitFor({state: "visible"})
    assert.equal(await exactMessage(a2.page, "T3 multi-tab seed").count(), 1)

    const seedA2 = exactMessage(a2.page, "T3 multi-tab seed")
    await seedA2.focus()
    await seedA2.getByRole("button", {name: "Edit message"}).click()
    await seedA2.getByLabel("Edit message text").fill("T3 multi-tab edited")
    await seedA2.getByRole("button", {name: "Save"}).click()
    await exactMessage(pair.a.page, "T3 multi-tab edited").waitFor({state: "visible"})
    await exactMessage(pair.b.page, "T3 multi-tab edited").waitFor({state: "visible"})

    await pair.b.disconnectSocket()
    await pair.b.page.locator("#presence").filter({hasText: /Reconnecting|Disconnected/}).waitFor({state: "visible"})
    await sendMessage(pair.a, "T3 reconnect catchup")
    assert.equal(await exactMessage(pair.b.page, "T3 reconnect catchup").count(), 0)

    const reconnectMark = pair.b.journal.mark()
    pair.b.reconnectSocket()
    await waitForParticipantJoin(pair.b, reconnectMark)
    await exactMessage(pair.b.page, "T3 reconnect catchup").waitFor({state: "visible"})
    assert.equal(await exactMessage(pair.b.page, "T3 reconnect catchup").count(), 1)

    await endConversation(a2.page)
    await Promise.all([
      waitTerminal(pair.a.page),
      waitTerminal(a2.page),
      waitTerminal(pair.b.page)
    ])

    assertClean(pair.a)
    assertClean(a2)
    assertClean(pair.b, {allowSocketFailure: true})
  } finally {
    await a2?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 3: late Conversation A frames cannot contaminate Conversation B UI", {timeout: 105_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, {controllableA: true})
    const conversationA = pair.conversationTopic

    await sendAndReceive(pair.a, pair.b, "T3 old conversation sentinel", conversationA)
    await endConversation(pair.a.page)
    await Promise.all([
      pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      pair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    ])

    await Promise.all([
      pair.a.page.locator("#fade-conversation").click(),
      pair.b.page.locator("#fade-conversation").click()
    ])
    await Promise.all([
      pair.a.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"}),
      pair.b.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    ])

    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await clickDoorAndQueue(pair.a.page)
    await pair.b.page.locator('button.door:has-text("Advice")').click()
    const [joinA, joinB] = await Promise.all([
      waitForConversation(pair.a, markA),
      waitForConversation(pair.b, markB)
    ])
    assert.equal(joinA.topic, joinB.topic)
    assert.notEqual(joinA.topic, conversationA)

    await sendAndReceive(pair.a, pair.b, "T3 new conversation control", joinA.topic)
    const staleId = crypto.randomUUID()
    pair.a.injectServerFrame([null, "t3-stale-message", conversationA, "message:new", {
      client_message_id: staleId,
      message_id: staleId,
      content: "T3 STALE OLD CONVERSATION SHOULD NEVER RENDER",
      sender_id: pair.b.participantId,
      sequence_id: 999
    }])
    pair.a.injectServerFrame([null, "t3-stale-typing", conversationA, "typing:status", {typing: true}])
    pair.a.injectServerFrame([null, "t3-stale-end", conversationA, "conversation:ended", {}])

    await pair.a.page.waitForTimeout(750)
    assert.equal(await pair.a.page.locator('[data-screen="conversation"].active').count(), 1, "Conversation B remains active")
    assert.equal(await exactMessage(pair.a.page, "T3 new conversation control").count(), 1)
    assert.equal(await exactMessage(pair.a.page, "T3 STALE OLD CONVERSATION SHOULD NEVER RENDER").count(), 0)
    assert.equal((await pair.a.page.locator("#typing").textContent()).trim(), "")
    assert.equal(
      pair.a.journal.events.slice(markA).some(event =>
        event.type === "frame_sent" &&
        event.topic === conversationA &&
        ["message:send", "message:edit", "message:unsend"].includes(event.event)
      ),
      false,
      "Conversation B UI emits no mutation back to old Conversation A"
    )

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 3: accessibility stress keeps critical Conversation controls operable", {timeout: 105_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser, {
      viewportA: {width: 720, height: 450}
    })
    const page = pair.a.page

    await page.emulateMedia({reducedMotion: "reduce", forcedColors: "active"})
    await page.addStyleTag({content: "html { font-size: 200% !important; }"})

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    assert.ok(overflow <= 1, `large-text layout has horizontal overflow: ${overflow}px`)

    const composer = page.locator("#message-form")
    await composer.scrollIntoViewIfNeeded()
    assert.equal(await page.getByRole("textbox", {name: "Message"}).isVisible(), true)
    assert.equal(await page.locator("#message-form button.primary").isVisible(), true)

    const actionsSummary = page.locator(".conversation-head-actions details.overflow summary")
    await actionsSummary.focus()
    assert.equal(await actionsSummary.evaluate(node => node === document.activeElement), true)
    assert.equal(await actionsSummary.getAttribute("aria-label"), "Conversation actions")

    await actionsSummary.press("Enter")
    const details = page.locator(".conversation-head-actions details.overflow")
    assert.notEqual(await details.getAttribute("open"), null)
    for (const id of ["#report-open", "#block", "#end-conversation"]) {
      await page.locator(id).scrollIntoViewIfNeeded()
      assert.equal(await page.locator(id).isVisible(), true, `${id} remains reachable`)
    }

    await page.locator("#report-open").click()
    const report = page.locator("#report-form")
    await report.waitFor({state: "visible"})
    assert.equal(await report.getByRole("heading", {name: "About this report"}).count(), 1)
    assert.equal(await page.locator("#report-cancel").isVisible(), true)
    await page.locator("#report-cancel").click()

    await openActions(page)
    await page.locator("#end-conversation").click()
    const dialog = page.locator("#end-confirmation-dialog")
    await dialog.waitFor({state: "visible"})
    assert.equal(await dialog.getByRole("button", {name: /Cancel|Keep talking/i}).count() >= 1, true)
    await page.keyboard.press("Escape")
    await dialog.waitFor({state: "hidden"})
    assert.equal(await page.locator("#end-conversation").evaluate(node => node === document.activeElement), true, "Escape restores focus")

    assert.equal(await page.locator("#typing").getAttribute("aria-live"), "polite")
    assert.equal(await page.locator("#status").getAttribute("role"), "status")

    const focusVisible = await actionsSummary.evaluate(node => {
      node.focus()
      return node.matches(":focus-visible")
    })
    assert.equal(focusVisible, true, "keyboard focus remains visibly addressable in forced colors")

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 3: terminal event while local surfaces are active leaves no live mutation UI", {timeout: 105_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    await sendAndReceive(pair.a, pair.b, "T3 terminal combination seed", pair.conversationTopic)

    const peerBubble = exactMessage(pair.b.page, "T3 terminal combination seed")
    await peerBubble.hover()
    await peerBubble.locator("button.reply-action-btn").click()
    await pair.b.page.locator("#reply-staging").waitFor({state: "visible"})

    await pair.b.page.locator("#prompt-control").click()
    await pair.b.page.locator("#prompt-helper").waitFor({state: "visible"})
    await pair.b.page.locator("#prompt-close").click()

    await pair.b.page.locator("#expressive-open").click()
    await pair.b.page.locator("#expressive-picker").waitFor({state: "visible"})

    await endConversation(pair.a.page)
    await waitTerminal(pair.b.page)
    assert.equal(await pair.b.page.locator("#reply-staging").isVisible(), false)
    assert.equal(await pair.b.page.locator("#expressive-picker").isVisible(), false)
    assert.equal(await pair.b.page.locator("#message-form").isVisible(), false)

    assertClean(pair.a)
    assertClean(pair.b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
