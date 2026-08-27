import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"
const WAIT = 15_000

async function instrumentConversationChannels(page) {
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
}

async function boot(browser, {instrument = false} = {}) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  if (instrument) await instrumentConversationChannels(page)
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

async function endAndRetain(user, peer) {
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

async function waitForRuntimeReleased(page, topic) {
  await page.waitForFunction((releasedTopic) => {
    const channel = window.__f04ConversationChannels?.channels?.[releasedTopic]
    return Boolean(channel) && !channel.socket?.channels?.includes(channel)
  }, topic, {timeout: WAIT})
}

async function dispatchStaleTopic(page, topic, event, payload) {
  return page.evaluate(({topic: staleTopic, event: staleEvent, payload: stalePayload}) => {
    const source = window.__f04ConversationChannels?.channels?.[staleTopic]
    const socket = source?.socket
    if (!socket) return 0
    const targets = socket.channels.filter((channel) => channel.topic === staleTopic)
    for (const channel of targets) channel.trigger(staleEvent, stalePayload)
    return targets.length
  }, {topic, event, payload})
}

function lastTopic(metrics) {
  return metrics.topics.at(-1)
}

test("F04 P0 terminal retention releases obsolete runtime across A -> B -> C", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  let peerA = null
  let peerB = null
  let peerC = null

  try {
    const beforeFirstMatch = await channelMetrics(user.page)
    assert.equal(beforeFirstMatch.created, 0, "F04-P0-01 starts with zero Conversation channels")
    assert.equal(beforeFirstMatch.active, 0, "F04-P0-01 active Conversation count is zero before first match")
    assert.equal(beforeFirstMatch.maxActive, 0, "no Conversation channel has existed before first match")

    peerA = await boot(browser)
    await matchPair(user.page, peerA.page)

    const conversationA = await channelMetrics(user.page)
    const topicA = lastTopic(conversationA)
    assert.ok(topicA, "Conversation A topic is observable")
    assert.equal(conversationA.created, 1, "F04-P0-02 Conversation A creates exactly one channel")
    assert.equal(conversationA.active, 1, "F04-P0-02 Conversation A active count is one")
    assert.equal(conversationA.runtime[topicA]?.socketHasChannel, true, "Conversation A is present in the socket runtime")
    assert.equal(conversationA.maxActive, 1, "Conversation A never creates duplicate active runtime")

    await endAndRetain(user.page, peerA.page)
    await waitForRuntimeReleased(user.page, topicA)

    const afterA = await channelMetrics(user.page)
    assert.equal(afterA.left, 1, "F04-P0-04 retention leaves Conversation A channel")
    assert.equal(afterA.active, 0, "F04-P0-04 post-retention active count returns to zero")
    assert.equal(afterA.runtime[topicA]?.socketHasChannel, false, "Conversation A runtime is removed from socket membership")
    assert.equal(afterA.maxActive, 1, "Conversation A retention never overlaps another Conversation runtime")

    peerB = await boot(browser)
    await matchPair(user.page, peerB.page)

    const conversationB = await channelMetrics(user.page)
    const topicB = lastTopic(conversationB)
    assert.ok(topicB, "Conversation B topic is observable")
    assert.equal(conversationB.created, 2, "F04-P0-06 Conversation B creates one replacement channel")
    assert.equal(conversationB.active, 1, "F04-P0-06 Conversation B active count is one")
    assert.notEqual(topicA, topicB, "F04-P0-07 Conversation A and B identities are distinct")
    assert.equal(conversationB.runtime[topicA]?.socketHasChannel, false, "Conversation A remains absent while B is active")
    assert.equal(conversationB.runtime[topicB]?.socketHasChannel, true, "only Conversation B is subscribed")
    assert.equal(conversationB.maxActive, 1, "active Conversation-channel count never reaches two")

    const draft = "B runtime must survive stale A traffic"
    await user.page.locator("#message-input").fill(draft)
    const staleMessage = "F04_STALE_A_MESSAGE_MUST_NOT_RENDER"
    assert.equal(await dispatchStaleTopic(user.page, topicA, "typing:status", {typing: true}), 0, "stale A typing event routes to zero channels")
    assert.equal(await dispatchStaleTopic(user.page, topicA, "message:new", {
      client_message_id: "f04-stale-a-message",
      message_id: "f04-stale-a-message",
      content: staleMessage,
      epoch_id: "f04-stale-a-epoch",
      sequence: 999999
    }), 0, "stale A message event routes to zero channels")
    assert.equal(await user.page.locator("#message-input").inputValue(), draft, "F04-P0-09 stale A traffic cannot mutate B draft")
    assert.equal(await user.page.locator("#typing").textContent(), "", "F04-P0-09 stale A typing cannot mutate B UI")
    assert.equal(await user.page.locator("#messages").getByText(staleMessage, {exact: true}).count(), 0, "F04-P0-09 stale A message cannot render in B")
    assert.equal(await user.page.locator('section[data-screen="conversation"].active').count(), 1, "Conversation B remains the active surface after stale A traffic")

    await endAndRetain(user.page, peerB.page)
    await waitForRuntimeReleased(user.page, topicB)

    const afterB = await channelMetrics(user.page)
    assert.equal(afterB.left, 2, "multi-cycle proof leaves Conversation B channel")
    assert.equal(afterB.active, 0, "multi-cycle proof returns to zero after B retention")
    assert.equal(afterB.runtime[topicB]?.socketHasChannel, false, "Conversation B runtime is removed before C")
    assert.equal(afterB.maxActive, 1, "A -> B cycles never accumulate active Conversation channels")

    peerC = await boot(browser)
    await matchPair(user.page, peerC.page)

    const conversationC = await channelMetrics(user.page)
    const topicC = lastTopic(conversationC)
    assert.ok(topicC, "Conversation C topic is observable")
    assert.equal(conversationC.created, 3, "multi-cycle proof creates exactly three Conversation channels total")
    assert.equal(conversationC.active, 1, "Conversation C active count is one")
    assert.notEqual(topicB, topicC, "Conversation B and C identities are distinct")
    assert.equal(new Set([topicA, topicB, topicC]).size, 3, "A, B and C use distinct Conversation identities")
    assert.equal(conversationC.runtime[topicA]?.socketHasChannel, false, "Conversation A remains released during C")
    assert.equal(conversationC.runtime[topicB]?.socketHasChannel, false, "Conversation B remains released during C")
    assert.equal(conversationC.runtime[topicC]?.socketHasChannel, true, "only Conversation C remains subscribed")
    assert.equal(conversationC.maxActive, 1, "multi-cycle hostile proof never observes 2+ active Conversation channels")
  } finally {
    await Promise.all([user, peerA, peerB, peerC].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})
