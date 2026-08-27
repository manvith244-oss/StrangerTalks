import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"
const WAIT = 15_000

async function instrumentRuntime(page) {
  await page.route("**/assets/expression_runtime.mjs*", async (route) => {
    const response = await route.fetch()
    const original = await response.text()
    const instrumentation = String.raw`
import {Socket as __F04Socket} from "/vendor/phoenix.mjs"
window.__f04ConversationChannels = {created: 0, left: 0, active: 0, maxActive: 0, topics: [], channels: {}}
const __f04OriginalChannel = __F04Socket.prototype.channel
__F04Socket.prototype.channel = function(topic, params) {
  const channel = __f04OriginalChannel.call(this, topic, params)
  if (typeof topic === "string" && topic.startsWith("conversation:")) {
    const metrics = window.__f04ConversationChannels
    metrics.created += 1
    metrics.active += 1
    metrics.maxActive = Math.max(metrics.maxActive, metrics.active)
    metrics.topics.push(topic)
    metrics.channels[topic] = channel
    const originalLeave = channel.leave.bind(channel)
    let counted = false
    channel.leave = function(...args) {
      if (!counted) {
        counted = true
        metrics.left += 1
        metrics.active -= 1
      }
      return originalLeave(...args)
    }
  }
  return channel
}
`
    await route.fulfill({response, body: `${instrumentation}\n${original}`})
  })

  await page.route("**/assets/app.js*", async (route) => {
    const response = await route.fetch()
    const original = await response.text()
    const probe = String.raw`
window.__f04RuntimeProbe = {
  state() {
    return {
      conversationId: app.conversationId,
      currentEpochId: app.currentEpochId,
      topic: app.conversation?.topic || null
    }
  },
  reconcile(snapshot) {
    return reconcileWithServer(snapshot)
  }
}
`
    await route.fulfill({response, body: `${original}\n${probe}`})
  })
}

async function boot(browser, {instrument = false} = {}) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  if (instrument) await instrumentRuntime(page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
  await page.waitForFunction(() => document.querySelectorAll("#doors .door").length > 0, null, {timeout: WAIT})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page}
}

async function startMatching(page, door = "Advice") {
  await page.locator(`button.door:has-text("${door}")`).click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: WAIT})
}

async function waitForConversation(page) {
  await page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})
}

async function matchPair(left, right, door = "Advice") {
  await startMatching(left, door)
  await startMatching(right, door)
  await Promise.all([waitForConversation(left), waitForConversation(right)])
}

async function endConversation(page) {
  const actions = page.locator("details.overflow")
  if ((await actions.getAttribute("open")) === null) await actions.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible", timeout: WAIT})
  await page.locator("#end-confirm").click()
}

async function endAndFade(user, peer) {
  await endConversation(user)
  await Promise.all([
    user.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT}),
    peer.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT})
  ])
  await user.locator("#fade-conversation").click()
  await user.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
}

async function channelMetrics(page) {
  return page.evaluate(() => {
    const metrics = window.__f04ConversationChannels
    const runtime = Object.fromEntries(Object.entries(metrics.channels).map(([topic, channel]) => [topic, {
      socketHasChannel: Boolean(channel?.socket?.channels?.includes(channel)),
      state: channel?.state || null,
      joined: typeof channel?.isJoined === "function" ? channel.isJoined() : null
    }]))
    return {
      created: metrics.created,
      left: metrics.left,
      active: metrics.active,
      maxActive: metrics.maxActive,
      topics: [...metrics.topics],
      runtime
    }
  })
}

function lastTopic(metrics) {
  return metrics.topics.at(-1)
}

async function triggerStaleChannelDirectly(page, topic, event, payload) {
  return page.evaluate(({staleTopic, staleEvent, stalePayload}) => {
    const channel = window.__f04ConversationChannels?.channels?.[staleTopic]
    if (!channel) return false
    channel.trigger(staleEvent, stalePayload)
    return true
  }, {staleTopic: topic, staleEvent: event, stalePayload: payload})
}

async function disconnectAndReconnectConversationSocket(page, topic) {
  await page.evaluate((currentTopic) => {
    const channel = window.__f04ConversationChannels?.channels?.[currentTopic]
    if (!channel?.socket) throw new Error("missing Conversation socket")
    channel.socket.disconnect()
  }, topic)
  await page.waitForFunction((currentTopic) => {
    const channel = window.__f04ConversationChannels?.channels?.[currentTopic]
    return Boolean(channel) && !channel.socket?.isConnected()
  }, topic, {timeout: WAIT})
  await page.evaluate((currentTopic) => {
    const channel = window.__f04ConversationChannels?.channels?.[currentTopic]
    channel.socket.connect()
  }, topic)
  await page.waitForFunction((currentTopic) => {
    const channel = window.__f04ConversationChannels?.channels?.[currentTopic]
    return Boolean(channel?.socket?.isConnected()) && channel.isJoined()
  }, topic, {timeout: WAIT})
}

test("F04 canonical AVAILABLE evicts stale Conversation runtime authority", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  const peer = await boot(browser)

  try {
    await matchPair(user.page, peer.page)
    const before = await channelMetrics(user.page)
    const topic = lastTopic(before)
    assert.ok(topic, "active Conversation topic is observable")
    assert.equal(before.active, 1, "one Conversation runtime is active before canonical correction")

    const beforeState = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    assert.ok(beforeState.conversationId, "client believes it has a Conversation before canonical correction")
    assert.equal(beforeState.topic, topic, "probe and channel instrumentation observe the same runtime")

    await user.page.evaluate(() => window.__f04RuntimeProbe.reconcile({canonical_state: "AVAILABLE"}))

    const after = await channelMetrics(user.page)
    const afterState = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    assert.equal(afterState.conversationId, null, "canonical AVAILABLE clears stale Conversation id authority")
    assert.equal(afterState.currentEpochId, null, "canonical AVAILABLE clears stale Conversation epoch authority")
    assert.equal(afterState.topic, null, "canonical AVAILABLE clears stale Conversation channel authority")
    assert.equal(after.left, 1, "canonical AVAILABLE explicitly leaves the stale Conversation channel")
    assert.equal(after.active, 0, "canonical AVAILABLE leaves zero active Conversation channels")
    assert.equal(after.runtime[topic]?.socketHasChannel, false, "stale Conversation is absent from socket membership")
  } finally {
    await Promise.all([user.context, peer.context].map((context) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 released Conversation A callbacks are inert after Conversation B becomes current", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  let peerA = null
  let peerB = null

  try {
    peerA = await boot(browser)
    await matchPair(user.page, peerA.page)
    const conversationA = await channelMetrics(user.page)
    const topicA = lastTopic(conversationA)
    assert.ok(topicA, "Conversation A topic is observable")

    await endAndFade(user.page, peerA.page)

    peerB = await boot(browser)
    await matchPair(user.page, peerB.page)
    const conversationB = await channelMetrics(user.page)
    const topicB = lastTopic(conversationB)
    assert.ok(topicB, "Conversation B topic is observable")
    assert.notEqual(topicA, topicB, "A and B are distinct Conversation runtimes")

    const draft = "Conversation B must survive a queued callback from A"
    await user.page.locator("#message-input").fill(draft)
    assert.equal(await user.page.locator("#typing").textContent(), "", "B starts without stale typing UI")

    assert.equal(await triggerStaleChannelDirectly(user.page, topicA, "typing:status", {typing: true}), true, "hostile proof executes a queued callback on released A")

    assert.equal(await user.page.locator("#message-input").inputValue(), draft, "late A callback cannot alter B draft")
    assert.equal(await user.page.locator("#typing").textContent(), "", "late A typing callback cannot mutate B UI")
    assert.equal(await user.page.locator('section[data-screen="conversation"].active').count(), 1, "Conversation B remains visible after stale A callback")
  } finally {
    await Promise.all([user, peerA, peerB].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 socket reconnect reuses one Conversation channel and one listener set", {timeout: 150_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  const peer = await boot(browser)

  try {
    await matchPair(user.page, peer.page)
    const before = await channelMetrics(user.page)
    const topic = lastTopic(before)
    assert.ok(topic, "Conversation topic is observable before reconnect")
    assert.equal(before.created, 1, "one Conversation channel exists before reconnect")

    await disconnectAndReconnectConversationSocket(user.page, topic)
    await user.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})

    const after = await channelMetrics(user.page)
    assert.equal(after.created, 1, "reconnect does not create another Conversation channel")
    assert.equal(after.active, 1, "reconnect leaves exactly one active Conversation channel")
    assert.equal(after.maxActive, 1, "reconnect never overlaps duplicate Conversation channels")
    assert.equal(after.runtime[topic]?.socketHasChannel, true, "same Conversation channel remains socket-authoritative after reconnect")

    const message = `F04 reconnect exactly once ${Date.now()}`
    await peer.page.locator("#message-input").fill(message)
    await peer.page.locator("#message-form").evaluate((form) => form.requestSubmit())
    await user.page.locator("#messages").getByText(message, {exact: true}).waitFor({state: "visible", timeout: WAIT})
    assert.equal(await user.page.locator("#messages").getByText(message, {exact: true}).count(), 1, "reconnect listener set renders peer message exactly once")
  } finally {
    await Promise.all([user.context, peer.context].map((context) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 reload restores the same recoverable Conversation with one fresh page runtime", {timeout: 150_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  const peer = await boot(browser)

  try {
    await matchPair(user.page, peer.page)
    const before = await channelMetrics(user.page)
    const topicBefore = lastTopic(before)
    assert.ok(topicBefore, "Conversation topic is observable before reload")

    await user.page.reload({waitUntil: "domcontentloaded"})
    await user.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})

    const after = await channelMetrics(user.page)
    const topicAfter = lastTopic(after)
    assert.equal(topicAfter, topicBefore, "reload recovers the same canonical Conversation id")
    assert.equal(after.created, 1, "new page creates exactly one Conversation channel for recovery")
    assert.equal(after.active, 1, "new page has exactly one active Conversation runtime")
    assert.equal(after.maxActive, 1, "reload recovery never creates duplicate page-local Conversation runtime")
  } finally {
    await Promise.all([user.context, peer.context].map((context) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})
