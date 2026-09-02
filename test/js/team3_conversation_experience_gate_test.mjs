import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT_MS = 15_000

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

  waitFor(predicate, label, from = 0, timeout = WAIT_MS) {
    const existing = this.events.slice(from).find(predicate)
    if (existing) return Promise.resolve(existing)
    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, timer: null}
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter)
        reject(new Error(`Timed out waiting for ${label}; recent=${JSON.stringify(this.events.slice(-18))}`))
      }, timeout)
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

  return {page, journal, pageErrors, consoleErrors, failedRequests, cdp}
}

async function waitParticipantJoin(observed, from = 0) {
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
  const socket = {offline: false, routes: new Set()}

  if (controllableSocket) {
    await context.routeWebSocket(/\/socket\/websocket/, route => {
      if (socket.offline) {
        route.close({code: 1001, reason: "intentional Team 3 outage"})
        return
      }
      const server = route.connectToServer()
      server.onMessage(payload => route.send(payload))
      socket.routes.add({page: route, server})
    })
  }

  const page = await context.newPage()
  const observed = await observePage(context, page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  const bootstrap = await observed.journal.waitFor(event => event.type === "participant_bootstrap", "participant bootstrap")
  assert.ok(bootstrap.status >= 200 && bootstrap.status < 300)
  const joined = await waitParticipantJoin(observed)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("#conversation-language").selectOption("en")

  return {
    ...observed,
    context,
    socket,
    participantTopic: joined.topic,
    participantId: joined.topic.split(":")[1],
    disconnectSocket: async () => {
      socket.offline = true
      for (const routes of [...socket.routes]) {
        await routes.page.close({code: 1001, reason: "intentional Team 3 outage"}).catch(() => {})
        await routes.server.close({code: 1001, reason: "intentional Team 3 outage"}).catch(() => {})
      }
      socket.routes.clear()
    },
    reconnectSocket: () => { socket.offline = false },
    injectServerFrame: frame => {
      const routes = [...socket.routes]
      assert.ok(routes.length > 0, "controllable WebSocket route exists")
      routes.at(-1).page.send(JSON.stringify(frame))
    }
  }
}

async function sameParticipantTab(context) {
  const page = await context.newPage()
  const observed = await observePage(context, page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok())
  const joined = await waitParticipantJoin(observed)
  return {...observed, participantTopic: joined.topic, participantId: joined.topic.split(":")[1]}
}

async function queue(page) {
  const door = page.locator('button.door:has-text("Advice")')
  await door.waitFor({state: "visible"})
  assert.equal(await door.isEnabled(), true)
  await door.click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
}

async function waitConversation(observed, from = 0) {
  await observed.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
  return observed.journal.waitFor(
    event => event.type === "frame_sent" && event.topic?.startsWith("conversation:") && event.event === "phx_join",
    "ConversationChannel join",
    from
  )
}

async function matchPair(browser, options = {}) {
  const a = await bootFresh(browser, {
    controllableSocket: options.controllableA,
    viewport: options.viewportA,
    mobile: options.mobileA,
    touch: options.touchA
  })
  const b = await bootFresh(browser, {
    controllableSocket: options.controllableB,
    viewport: options.viewportB,
    mobile: options.mobileB,
    touch: options.touchB
  })
  await queue(a.page)
  await b.page.locator('button.door:has-text("Advice")').click()
  const [joinA, joinB] = await Promise.all([waitConversation(a), waitConversation(b)])
  assert.equal(joinA.topic, joinB.topic, "same authoritative Conversation")
  return {a, b, conversationTopic: joinA.topic}
}

function message(page, text) {
  return page.locator("#messages li", {hasText: text})
}

async function send(observed, text) {
  await observed.page.getByRole("textbox", {name: "Message"}).fill(text)
  await observed.page.getByRole("button", {name: "Send message"}).click()
  const row = message(observed.page, text)
  await row.waitFor({state: "visible"})
  return row
}

async function sendReceive(sender, receiver, text, topic) {
  const senderMark = sender.journal.mark()
  const receiverMark = receiver.journal.mark()
  const own = await send(sender, text)
  await sender.journal.waitFor(
    event => event.type === "frame_sent" && event.topic === topic && event.event === "message:send" && event.body?.content === text,
    `send ${text}`,
    senderMark
  )
  await receiver.journal.waitFor(
    event => event.type === "frame_received" && event.topic === topic && event.event === "message:new" && event.body?.content === text,
    `receive ${text}`,
    receiverMark
  )
  const peer = message(receiver.page, text)
  await peer.waitFor({state: "visible"})
  assert.equal(await own.count(), 1)
  assert.equal(await peer.count(), 1)
  return {own, peer}
}

async function openActions(page) {
  const details = page.locator(".conversation-head-actions details.overflow")
  if ((await details.getAttribute("open")) === null) await details.locator("summary").click()
  await details.locator("#end-conversation").waitFor({state: "visible"})
  return details
}

async function endConversation(page) {
  await openActions(page)
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
}

async function terminalFrame(observed, topic, label, from = 0) {
  return observed.journal.waitFor(
    event => event.type === "frame_received" && event.topic === topic && event.event === "conversation:ended",
    `${label} conversation:ended frame`,
    from,
    12_000
  )
}

async function terminalUI(page, label) {
  await page.waitForFunction(
    () => !document.querySelector('[data-screen="conversation"]')?.classList.contains("active"),
    null,
    {timeout: 12_000}
  ).catch(error => {
    throw new Error(`${label} did not leave active Conversation UI: ${error.message}`)
  })
  assert.equal(await page.locator('[data-screen="conversation"].active').count(), 0)
  assert.equal(await page.locator("#message-input").isVisible(), false)
  for (const selector of ["#report-form", "#prompt-helper", "#expressive-picker", "#voice-warning", "#voice-preview", "#view-once-preview", "#end-confirmation-backdrop"]) {
    if (await page.locator(selector).count()) assert.equal(await page.locator(selector).isVisible(), false, `${label}: ${selector} remains live`)
  }
}

async function noUuid(observed) {
  assert.equal((await observed.page.locator("body").innerText()).includes(observed.participantId), false)
}

function clean(observed, {allowSocketFailure = false} = {}) {
  assert.deepEqual(observed.pageErrors, [], "no page errors")
  assert.deepEqual(observed.consoleErrors, [], "no console errors")
  const failed = observed.failedRequests.filter(request => {
    if (!allowSocketFailure) return true
    return new URL(request.url).pathname !== "/socket/websocket"
  })
  assert.deepEqual(failed, [], "no critical failed requests")
  assert.deepEqual(observed.journal.events.filter(event => event.type === "http_error"), [], "no HTTP errors")
}

async function closePair(pair) {
  await pair?.a.context.close().catch(() => {})
  await pair?.b.context.close().catch(() => {})
}

test("Team 3: 320x568 dismisses tray from physically exposed Conversation header", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {viewportA: {width: 320, height: 568}, mobileA: true, touchA: true})
    const page = pair.a.page
    await page.locator(".ig-compose-plus").click()
    await page.waitForFunction(() => document.querySelector("#message-form")?.classList.contains("ig-tray-open"))
    const geometry = await page.locator(".conversation-identity").evaluate(node => {
      const rect = node.getBoundingClientRect()
      const x = rect.left + rect.width / 2
      const y = rect.top + rect.height / 2
      const hit = document.elementFromPoint(x, y)
      return {top: rect.top, bottom: rect.bottom, hitInsideComposer: Boolean(hit?.closest("#message-form"))}
    })
    assert.ok(geometry.top >= -1 && geometry.bottom <= 569)
    assert.equal(geometry.hitInsideComposer, false)
    await page.locator(".conversation-identity").click()
    await page.waitForFunction(() => !document.querySelector("#message-form")?.classList.contains("ig-tray-open"))
    assert.equal(await page.locator(".ig-compose-plus").getAttribute("aria-expanded"), "false")
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3: isolated two-browser Conversation journey sends, mutates, types, and ends", {timeout: 100_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a, b, conversationTopic} = pair
    assert.match(conversationTopic.replace("conversation:", ""), /^[0-9a-f-]{36}$/i)
    await noUuid(a)
    await noUuid(b)

    const first = await sendReceive(a, b, "T3 journey A", conversationTopic)
    assert.equal(await first.own.evaluate(node => node.classList.contains("mine")), true)
    assert.equal(await first.peer.evaluate(node => node.classList.contains("mine")), false)

    await first.peer.hover()
    await first.peer.locator("button.reply-action-btn").click()
    await b.page.locator("#reply-staging").waitFor({state: "visible"})
    assert.equal(await b.page.locator("#reply-staging-author").textContent(), "Replying to Stranger")
    await b.page.getByRole("textbox", {name: "Message"}).fill("T3 journey reply")
    await b.page.getByRole("button", {name: "Send message"}).click()
    const replyA = message(a.page, "T3 journey reply")
    await replyA.waitFor({state: "visible"})
    await replyA.locator(".reply-quote").waitFor({state: "visible"})

    await replyA.hover()
    await replyA.locator("button.react-action-btn").click()
    await replyA.locator(".reaction-picker button.reaction-btn[data-emoji='❤️']").click()
    const replyB = message(b.page, "T3 journey reply")
    await replyB.locator(".reaction-pill.peer").waitFor({state: "visible"})

    await replyB.focus()
    await replyB.getByRole("button", {name: "Edit message"}).click()
    await replyB.getByLabel("Edit message text").fill("T3 journey reply edited")
    await replyB.getByRole("button", {name: "Save"}).click()
    await message(a.page, "T3 journey reply edited").waitFor({state: "visible"})

    await a.page.getByRole("textbox", {name: "Message"}).fill("typing only")
    await b.page.locator("#typing").filter({hasText: "The other person is typing"}).waitFor({state: "visible"})
    await b.page.waitForFunction(() => document.querySelector("#typing")?.textContent === "", null, {timeout: 5_500})
    await a.page.getByRole("textbox", {name: "Message"}).fill("")
    await sendReceive(a, b, "T3 final message", conversationTopic)
    assert.equal(await message(a.page, "T3 final message").count(), 1)
    assert.equal(await message(b.page, "T3 final message").count(), 1)

    const markA = a.journal.mark()
    const markB = b.journal.mark()
    await endConversation(a.page)
    await Promise.all([
      terminalFrame(a, conversationTopic, "ender", markA),
      terminalFrame(b, conversationTopic, "peer", markB)
    ])
    await terminalUI(a.page, "ender")
    await terminalUI(b.page, "peer")
    clean(a)
    clean(b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3: Report, Block, and End remain reachable and truthful", {timeout: 130_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let reportPair
  let blockPair
  let endPair
  try {
    reportPair = await matchPair(browser, {viewportA: {width: 844, height: 390}, mobileA: true, touchA: true})
    await openActions(reportPair.a.page)
    await reportPair.a.page.locator("#report-open").click()
    await reportPair.a.page.locator("#report-form").waitFor({state: "visible"})
    await reportPair.a.page.locator("#report-category").selectOption("HARASSMENT")
    await reportPair.a.page.locator("#report-evidence").fill("Team 3 safety-access proof")
    const reportMark = reportPair.a.journal.mark()
    await reportPair.a.page.getByRole("button", {name: "Submit Report"}).click()
    await reportPair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === reportPair.conversationTopic && event.event === "conversation:report",
      "Report request",
      reportMark
    )
    await reportPair.a.page.getByRole("status").filter({hasText: "Report submitted for pending review"}).waitFor({state: "visible"})
    assert.equal(await reportPair.a.page.locator('[data-screen="conversation"].active').count(), 1)
    await openActions(reportPair.a.page)
    await reportPair.a.page.locator("#report-open").click()
    await reportPair.a.page.locator("#report-form").waitFor({state: "visible"})
    await reportPair.a.page.locator("#report-cancel").scrollIntoViewIfNeeded()
    await reportPair.a.page.locator("#report-cancel").click()
    assert.equal(await reportPair.a.page.locator("#report-form").isVisible(), false)

    blockPair = await matchPair(browser, {viewportA: {width: 390, height: 844}, mobileA: true, touchA: true})
    await openActions(blockPair.a.page)
    blockPair.a.page.once("dialog", dialog => dialog.accept())
    const blockMarkA = blockPair.a.journal.mark()
    const blockMarkB = blockPair.b.journal.mark()
    await blockPair.a.page.locator("#block").click()
    await blockPair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === blockPair.conversationTopic && event.event === "conversation:block",
      "Block request",
      blockMarkA
    )
    await terminalFrame(blockPair.a, blockPair.conversationTopic, "blocker", blockMarkA)
    await terminalFrame(blockPair.b, blockPair.conversationTopic, "blocked peer", blockMarkB)
    await terminalUI(blockPair.a.page, "blocker")
    await terminalUI(blockPair.b.page, "blocked peer")

    endPair = await matchPair(browser, {viewportA: {width: 360, height: 740}, mobileA: true, touchA: true})
    const endMarkA = endPair.a.journal.mark()
    const endMarkB = endPair.b.journal.mark()
    await endConversation(endPair.a.page)
    await Promise.all([
      terminalFrame(endPair.a, endPair.conversationTopic, "mobile ender", endMarkA),
      terminalFrame(endPair.b, endPair.conversationTopic, "mobile peer", endMarkB)
    ])
    await terminalUI(endPair.a.page, "mobile ender")
    await terminalUI(endPair.b.page, "mobile peer")

    for (const observed of [reportPair.a, reportPair.b, blockPair.a, blockPair.b, endPair.a, endPair.b]) clean(observed)
  } finally {
    await closePair(reportPair)
    await closePair(blockPair)
    await closePair(endPair)
    await browser.close().catch(() => {})
  }
})

test("Team 3: same-participant tabs and reconnect converge", {timeout: 110_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let a2
  try {
    pair = await matchPair(browser, {controllableB: true})
    a2 = await sameParticipantTab(pair.a.context)
    const a2Join = await waitConversation(a2)
    assert.equal(a2Join.topic, pair.conversationTopic)
    assert.equal(a2.participantId, pair.a.participantId)

    await sendReceive(pair.a, pair.b, "T3 multitab seed", pair.conversationTopic)
    await message(a2.page, "T3 multitab seed").waitFor({state: "visible"})
    const seedA2 = message(a2.page, "T3 multitab seed")
    await seedA2.focus()
    await seedA2.getByRole("button", {name: "Edit message"}).click()
    await seedA2.getByLabel("Edit message text").fill("T3 multitab edited")
    await seedA2.getByRole("button", {name: "Save"}).click()
    await message(pair.a.page, "T3 multitab edited").waitFor({state: "visible"})
    await message(pair.b.page, "T3 multitab edited").waitFor({state: "visible"})

    await pair.b.disconnectSocket()
    await pair.b.page.locator("#presence").filter({hasText: /Reconnecting|Disconnected/}).waitFor({state: "visible"})
    await send(pair.a, "T3 reconnect catchup")
    assert.equal(await message(pair.b.page, "T3 reconnect catchup").count(), 0)
    const reconnectMark = pair.b.journal.mark()
    pair.b.reconnectSocket()
    await waitParticipantJoin(pair.b, reconnectMark)
    await message(pair.b.page, "T3 reconnect catchup").waitFor({state: "visible"})
    assert.equal(await message(pair.b.page, "T3 reconnect catchup").count(), 1)

    const markA1 = pair.a.journal.mark()
    const markA2 = a2.journal.mark()
    const markB = pair.b.journal.mark()
    await endConversation(a2.page)
    await Promise.all([
      terminalFrame(pair.a, pair.conversationTopic, "A1", markA1),
      terminalFrame(a2, pair.conversationTopic, "A2", markA2),
      terminalFrame(pair.b, pair.conversationTopic, "B", markB)
    ])
    await terminalUI(pair.a.page, "A1")
    await terminalUI(a2.page, "A2")
    await terminalUI(pair.b.page, "B")
    clean(pair.a)
    clean(a2)
    clean(pair.b, {allowSocketFailure: true})
  } finally {
    await a2?.page.close().catch(() => {})
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3: late Conversation A frames cannot contaminate Conversation B", {timeout: 110_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {controllableA: true})
    const oldTopic = pair.conversationTopic
    await sendReceive(pair.a, pair.b, "T3 old sentinel", oldTopic)
    await endConversation(pair.a.page)
    await Promise.all([
      pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"}),
      pair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    ])
    await Promise.all([pair.a.page.locator("#fade-conversation").click(), pair.b.page.locator("#fade-conversation").click()])
    await Promise.all([
      pair.a.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"}),
      pair.b.page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
    ])

    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await queue(pair.a.page)
    await pair.b.page.locator('button.door:has-text("Advice")').click()
    const [joinA, joinB] = await Promise.all([waitConversation(pair.a, markA), waitConversation(pair.b, markB)])
    assert.equal(joinA.topic, joinB.topic)
    assert.notEqual(joinA.topic, oldTopic)
    await sendReceive(pair.a, pair.b, "T3 new control", joinA.topic)

    const staleId = crypto.randomUUID()
    pair.a.injectServerFrame([null, "stale-message", oldTopic, "message:new", {
      client_message_id: staleId,
      message_id: staleId,
      content: "T3 STALE SHOULD NOT RENDER",
      sender_id: pair.b.participantId,
      sequence_id: 999
    }])
    pair.a.injectServerFrame([null, "stale-typing", oldTopic, "typing:status", {typing: true}])
    pair.a.injectServerFrame([null, "stale-end", oldTopic, "conversation:ended", {}])
    await pair.a.page.waitForTimeout(750)
    assert.equal(await pair.a.page.locator('[data-screen="conversation"].active').count(), 1)
    assert.equal(await message(pair.a.page, "T3 new control").count(), 1)
    assert.equal(await message(pair.a.page, "T3 STALE SHOULD NOT RENDER").count(), 0)
    assert.equal((await pair.a.page.locator("#typing").textContent()).trim(), "")
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3: accessibility stress preserves critical Conversation operation", {timeout: 110_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {viewportA: {width: 720, height: 450}})
    const {page, cdp} = pair.a
    await page.emulateMedia({reducedMotion: "reduce", forcedColors: "active"})
    await cdp.send("Emulation.setPageScaleFactor", {pageScaleFactor: 2})
    const scale = await page.evaluate(() => window.visualViewport?.scale || 1)
    assert.ok(scale >= 1.9, `expected ~200% page scale, got ${scale}`)
    assert.equal(await page.getByRole("textbox", {name: "Message"}).isVisible(), true)
    assert.equal(await page.getByRole("button", {name: "Send message"}).isVisible(), true)

    await cdp.send("Emulation.setPageScaleFactor", {pageScaleFactor: 1})
    await page.addStyleTag({content: "html { font-size: 200% !important; }"})
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    assert.ok(overflow <= 1, `large-text horizontal overflow: ${overflow}px`)

    const summary = page.locator(".conversation-head-actions details.overflow summary")
    await summary.focus()
    assert.equal(await summary.evaluate(node => node === document.activeElement), true)
    assert.equal(await summary.getAttribute("aria-label"), "Conversation actions")
    await summary.press("Enter")
    for (const selector of ["#report-open", "#block", "#end-conversation"]) {
      await page.locator(selector).scrollIntoViewIfNeeded()
      assert.equal(await page.locator(selector).isVisible(), true, `${selector} reachable`)
    }
    await page.locator("#report-open").click()
    await page.locator("#report-form").waitFor({state: "visible"})
    assert.equal(await page.locator("#report-cancel").isVisible(), true)
    await page.locator("#report-cancel").click()

    await openActions(page)
    await page.locator("#end-conversation").click()
    await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
    await page.keyboard.press("Escape")
    await page.locator("#end-confirmation-dialog").waitFor({state: "hidden"})
    assert.equal(await page.locator("#end-conversation").evaluate(node => node === document.activeElement), true)
    assert.equal(await page.locator("#typing").getAttribute("aria-live"), "polite")
    assert.equal(await page.locator("#status").getAttribute("role"), "status")
    assert.equal(await summary.evaluate(node => { node.focus(); return node.matches(":focus-visible") }), true)
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3: terminal state clears staged reply and open expressive surface", {timeout: 100_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await sendReceive(pair.a, pair.b, "T3 terminal seed", pair.conversationTopic)
    const peer = message(pair.b.page, "T3 terminal seed")
    await peer.hover()
    await peer.locator("button.reply-action-btn").click()
    await pair.b.page.locator("#reply-staging").waitFor({state: "visible"})
    await pair.b.page.locator("#expressive-open").click()
    await pair.b.page.locator("#expressive-picker").waitFor({state: "visible"})

    const markB = pair.b.journal.mark()
    await endConversation(pair.a.page)
    await terminalFrame(pair.b, pair.conversationTopic, "peer with local surfaces", markB)
    await terminalUI(pair.b.page, "peer with local surfaces")
    assert.equal(await pair.b.page.locator("#reply-staging").isVisible(), false)
    assert.equal(await pair.b.page.locator("#expressive-picker").isVisible(), false)
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})
