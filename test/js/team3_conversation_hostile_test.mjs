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
  mark() { return this.events.length }
  waitFor(predicate, label, from = 0, timeout = WAIT_MS) {
    const found = this.events.slice(from).find(predicate)
    if (found) return Promise.resolve(found)
    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, timer: null}
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter)
        reject(new Error(`Timed out waiting for ${label}; recent=${JSON.stringify(this.events.slice(-20))}`))
      }, timeout)
      this.waiters.add(waiter)
    })
  }
}

async function observe(context, page) {
  const journal = new Journal()
  const pageErrors = []
  const consoleErrors = []
  const failedRequests = []
  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  page.on("requestfailed", request => failedRequests.push({
    url: request.url(),
    reason: request.failure()?.errorText || "unknown"
  }))
  page.on("response", response => {
    const path = new URL(response.url()).pathname
    if (path === "/api/participants") journal.add({type: "participant_bootstrap", status: response.status()})
    if (response.status() >= 400) journal.add({type: "http_error", path, status: response.status()})
  })
  page.on("websocket", socket => {
    journal.add({type: "websocket_open", url: socket.url()})
    socket.on("framesent", ({payload}) => {
      const frame = phoenixMessage(payload)
      if (frame) journal.add({type: "frame_sent", ...frame})
    })
    socket.on("framereceived", ({payload}) => {
      const frame = phoenixMessage(payload)
      if (frame) journal.add({type: "frame_received", ...frame})
    })
    socket.on("close", () => journal.add({type: "websocket_close"}))
  })
  return {page, journal, pageErrors, consoleErrors, failedRequests}
}

async function participantJoin(observed, from = 0) {
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

async function boot(browser, {controllable = false, viewport = {width: 1280, height: 800}} = {}) {
  const context = await browser.newContext({viewport})
  const control = {offline: false, routes: new Set()}
  if (controllable) {
    await context.routeWebSocket(/\/socket\/websocket/, route => {
      if (control.offline) {
        route.close({code: 1001, reason: "Team 3 hostile outage"})
        return
      }
      const server = route.connectToServer()
      server.onMessage(payload => route.send(payload))
      control.routes.add({route, server})
    })
  }
  const page = await context.newPage()
  const observed = await observe(context, page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root loads")
  const bootstrap = await observed.journal.waitFor(event => event.type === "participant_bootstrap", "participant bootstrap")
  assert.ok(bootstrap.status >= 200 && bootstrap.status < 300)
  const joined = await participantJoin(observed)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("#conversation-language").selectOption("en")
  return {
    ...observed,
    context,
    participantId: joined.topic.split(":")[1],
    disconnect: async () => {
      control.offline = true
      for (const pair of [...control.routes]) {
        await pair.route.close({code: 1001, reason: "Team 3 hostile outage"}).catch(() => {})
        await pair.server.close({code: 1001, reason: "Team 3 hostile outage"}).catch(() => {})
      }
      control.routes.clear()
    },
    reconnect: () => { control.offline = false }
  }
}

async function queue(page) {
  const door = page.locator('button.door:has-text("Advice")')
  await door.waitFor({state: "visible"})
  await door.click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
}

async function conversationJoin(observed, from = 0) {
  await observed.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
  return observed.journal.waitFor(
    event => event.type === "frame_sent" &&
      event.topic?.startsWith("conversation:") &&
      event.event === "phx_join",
    "ConversationChannel join",
    from
  )
}

async function matchPair(browser, options = {}) {
  const a = await boot(browser, {controllable: options.controllableA, viewport: options.viewportA})
  const b = await boot(browser, {controllable: options.controllableB, viewport: options.viewportB})
  await queue(a.page)
  await b.page.locator('button.door:has-text("Advice")').click()
  const [joinA, joinB] = await Promise.all([conversationJoin(a), conversationJoin(b)])
  assert.equal(joinA.topic, joinB.topic)
  return {a, b, topic: joinA.topic}
}

function row(page, text) {
  return page.locator("#messages li", {hasText: text})
}

async function send(observed, text) {
  await observed.page.getByRole("textbox", {name: "Message"}).fill(text)
  await observed.page.getByRole("button", {name: "Send message"}).click()
  const message = row(observed.page, text)
  await message.waitFor({state: "visible"})
  return message
}

async function sendReceive(sender, receiver, text, topic) {
  const receiverMark = receiver.journal.mark()
  const own = await send(sender, text)
  await receiver.journal.waitFor(
    event => event.type === "frame_received" &&
      event.topic === topic &&
      event.event === "message:new" &&
      event.body?.content === text,
    `peer receive ${text}`,
    receiverMark
  )
  const peer = row(receiver.page, text)
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

async function end(page) {
  await openActions(page)
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
}

async function terminalFrame(observed, topic, label, from = 0) {
  return observed.journal.waitFor(
    event => event.type === "frame_received" &&
      event.topic === topic &&
      event.event === "conversation:ended",
    `${label} conversation:ended`,
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
    throw new Error(`${label} remained in active Conversation UI: ${error.message}`)
  })
  assert.equal(await page.locator('[data-screen="conversation"].active').count(), 0)
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

test("Team 3 hostile: Report cancel returns to a fully usable Conversation", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {viewportA: {width: 844, height: 390}})
    await openActions(pair.a.page)
    await pair.a.page.locator("#report-open").click()
    await pair.a.page.locator("#report-form").waitFor({state: "visible"})
    await pair.a.page.locator("#report-cancel").scrollIntoViewIfNeeded()
    await pair.a.page.locator("#report-cancel").click()
    await pair.a.page.locator("#report-form").waitFor({state: "hidden"})
    await sendReceive(pair.a, pair.b, "T3 report-cancel still usable", pair.topic)
    assert.equal(await pair.a.page.locator('[data-screen="conversation"].active').count(), 1)
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3 hostile: reaction then unsend converges to one tombstone", {timeout: 100_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const sent = await sendReceive(pair.a, pair.b, "T3 reaction-unsend target", pair.topic)
    await sent.peer.hover()
    await sent.peer.locator("button.react-action-btn").click()
    await sent.peer.locator(".reaction-picker button.reaction-btn[data-emoji='❤️']").click()
    await sent.own.locator(".reaction-pill.peer").waitFor({state: "visible"})

    const id = await sent.own.getAttribute("data-message-id")
    assert.ok(id, "canonical message id exists")
    await sent.own.focus()
    await sent.own.getByRole("button", {name: "Unsend message"}).click()
    const dialog = pair.a.page.locator("#unsend-confirmation-dialog")
    await dialog.waitFor({state: "visible"})
    await dialog.getByRole("button", {name: "Unsend", exact: true}).click()

    const tombstoneA = pair.a.page.locator(`[data-message-id="${id}"] .message-content`, {hasText: "Message unsent"})
    const tombstoneB = pair.b.page.locator(`[data-message-id="${id}"] .message-content`, {hasText: "Message unsent"})
    await Promise.all([tombstoneA.waitFor({state: "visible"}), tombstoneB.waitFor({state: "visible"})])
    assert.equal(await pair.a.page.locator(`[data-message-id="${id}"]`).count(), 1)
    assert.equal(await pair.b.page.locator(`[data-message-id="${id}"]`).count(), 1)
    assert.equal(await pair.a.page.locator(`[data-message-id="${id}"] .reaction-pill`).count(), 0)
    assert.equal(await pair.b.page.locator(`[data-message-id="${id}"] .reaction-pill`).count(), 0)
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3 hostile: typing plus disconnect/reconnect clears stale typing and preserves messaging", {timeout: 110_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {controllableB: true})
    await pair.a.page.getByRole("textbox", {name: "Message"}).fill("typing across outage")
    await pair.b.page.locator("#typing").filter({hasText: "The other person is typing"}).waitFor({state: "visible"})
    await pair.b.disconnect()
    await pair.a.page.getByRole("textbox", {name: "Message"}).fill("")
    await send(pair.a, "T3 typing reconnect catchup")
    const mark = pair.b.journal.mark()
    pair.b.reconnect()
    await participantJoin(pair.b, mark)
    await row(pair.b.page, "T3 typing reconnect catchup").waitFor({state: "visible"})
    await pair.b.page.waitForFunction(() => (document.querySelector("#typing")?.textContent || "").trim() === "", null, {timeout: 8_000})
    assert.equal(await row(pair.b.page, "T3 typing reconnect catchup").count(), 1)
    await sendReceive(pair.b, pair.a, "T3 post-reconnect reply", pair.topic)
    clean(pair.a)
    clean(pair.b, {allowSocketFailure: true})
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3 hostile: End during peer disconnect reconciles terminal UX after reconnect", {timeout: 110_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {controllableB: true})
    await sendReceive(pair.a, pair.b, "T3 end-reconnect seed", pair.topic)
    await pair.b.disconnect()
    const markA = pair.a.journal.mark()
    await end(pair.a.page)
    await terminalFrame(pair.a, pair.topic, "ender", markA)
    await terminalUI(pair.a.page, "ender")
    const reconnectMark = pair.b.journal.mark()
    pair.b.reconnect()
    await pair.b.page.reload({waitUntil: "domcontentloaded"})
    await participantJoin(pair.b, reconnectMark)
    await pair.b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible"})
    assert.equal(await pair.b.page.locator('[data-screen="conversation"].active').count(), 0)
    clean(pair.a)
    clean(pair.b, {allowSocketFailure: true})
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3 hostile: Block with transient UI proves canonical result then requires terminal event", {timeout: 100_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await sendReceive(pair.b, pair.a, "T3 block-transient seed", pair.topic)
    const target = row(pair.a.page, "T3 block-transient seed")
    await target.hover()
    await target.locator("button.reply-action-btn").click()
    await pair.a.page.locator("#reply-staging").waitFor({state: "visible"})
    await pair.a.page.locator(".ig-compose-plus").click()
    await pair.a.page.waitForFunction(() => document.querySelector("#message-form")?.classList.contains("ig-tray-open"))
    await pair.a.page.getByRole("textbox", {name: "Message"}).focus()

    await openActions(pair.a.page)
    pair.a.page.once("dialog", dialog => dialog.accept())
    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await pair.a.page.locator("#block").click()
    const request = await pair.a.journal.waitFor(
      event => event.type === "frame_sent" && event.topic === pair.topic && event.event === "conversation:block",
      "Block request",
      markA
    )
    const reply = await pair.a.journal.waitFor(
      event => event.type === "frame_received" &&
        event.topic === pair.topic &&
        event.event === "phx_reply" &&
        event.ref === request.ref,
      "canonical Block reply",
      markA
    )
    assert.equal(reply.body?.status, "ok")
    assert.equal(reply.body?.response?.status, "blocked")

    await terminalFrame(pair.a, pair.topic, "blocker with transient UI", markA)
    await terminalFrame(pair.b, pair.topic, "blocked peer", markB)
    await terminalUI(pair.a.page, "blocker with transient UI")
    await terminalUI(pair.b.page, "blocked peer")
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("Team 3 hostile: terminal state cannot strand keyboard focus in removed Conversation UI", {timeout: 100_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {viewportA: {width: 720, height: 450}})
    const page = pair.a.page
    const summary = page.locator(".conversation-head-actions details.overflow summary")
    await summary.focus()
    assert.equal(await summary.evaluate(node => node.matches(":focus-visible")), true)
    await summary.press("Enter")

    const visited = []
    for (let index = 0; index < 8; index++) {
      await page.keyboard.press("Tab")
      visited.push(await page.evaluate(() => ({
        id: document.activeElement?.id || "",
        hiddenReport: Boolean(document.activeElement?.closest("#report-form") && !document.querySelector("#report-form")?.matches(":not([hidden])")),
        inActiveConversation: Boolean(document.activeElement?.closest('[data-screen="conversation"].active'))
      })))
    }
    assert.equal(visited.some(entry => entry.id === "report-open"), true, "Report is keyboard reachable")
    assert.equal(visited.some(entry => entry.id === "block"), true, "Block is keyboard reachable")
    assert.equal(visited.some(entry => entry.id === "end-conversation"), true, "End is keyboard reachable")
    assert.equal(visited.some(entry => entry.hiddenReport), false, "hidden Report controls are not entered")

    await page.getByRole("textbox", {name: "Message"}).focus()
    assert.equal(await page.getByRole("textbox", {name: "Message"}).evaluate(node => node === document.activeElement), true)
    const markA = pair.a.journal.mark()
    const markB = pair.b.journal.mark()
    await end(pair.b.page)
    await Promise.all([
      terminalFrame(pair.a, pair.topic, "focused peer", markA),
      terminalFrame(pair.b, pair.topic, "ender", markB)
    ])
    await terminalUI(page, "focused peer")
    await terminalUI(pair.b.page, "ender")
    const stranded = await page.evaluate(() => Boolean(document.activeElement?.closest('[data-screen="conversation"]')))
    assert.equal(stranded, false, "focus is not stranded inside inactive Conversation screen")
    clean(pair.a)
    clean(pair.b)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})
