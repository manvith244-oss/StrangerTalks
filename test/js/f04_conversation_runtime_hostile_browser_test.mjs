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
window.__f04ConversationChannels = {
  created: 0,
  left: 0,
  active: 0,
  maxActive: 0,
  topics: [],
  channels: {},
  listenerOn: 0,
  listenerOff: 0,
  activeListeners: 0,
  maxActiveListeners: 0,
  listenerRefs: {}
}
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
    metrics.listenerRefs[topic] = {}

    const isApplicationListenerEvent = (event) => {
      const name = String(event)
      return !name.startsWith("phx_") && !name.startsWith("chan_reply_")
    }

    const originalOn = channel.on.bind(channel)
    channel.on = function(event, callback) {
      const ref = originalOn(event, callback)
      if (!isApplicationListenerEvent(event)) return ref
      const key = String(event) + ":" + String(ref)
      if (!metrics.listenerRefs[topic][key]) {
        metrics.listenerRefs[topic][key] = true
        metrics.listenerOn += 1
        metrics.activeListeners += 1
        metrics.maxActiveListeners = Math.max(metrics.maxActiveListeners, metrics.activeListeners)
      }
      return ref
    }

    const originalOff = channel.off.bind(channel)
    channel.off = function(event, ref) {
      if (!isApplicationListenerEvent(event)) return originalOff(event, ref)
      const key = String(event) + ":" + String(ref)
      if (metrics.listenerRefs[topic][key]) {
        delete metrics.listenerRefs[topic][key]
        metrics.listenerOff += 1
        metrics.activeListeners -= 1
      }
      return originalOff(event, ref)
    }

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
  },
  release(conversationId, topic) {
    const channel = window.__f04ConversationChannels?.channels?.[topic] || null
    return releaseConversationRuntime({conversationId, channel})
  },
  async voiceRecord(conversationId, voiceNoteId) {
    return (await getRecord("voice:" + conversationId + ":" + voiceNoteId)) ?? null
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
    const listenerActiveByTopic = Object.fromEntries(
      Object.entries(metrics.listenerRefs).map(([topic, refs]) => [topic, Object.keys(refs).length])
    )
    return {
      created: metrics.created,
      left: metrics.left,
      active: metrics.active,
      maxActive: metrics.maxActive,
      topics: [...metrics.topics],
      runtime,
      listenerOn: metrics.listenerOn,
      listenerOff: metrics.listenerOff,
      activeListeners: metrics.activeListeners,
      maxActiveListeners: metrics.maxActiveListeners,
      listenerActiveByTopic
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

async function assertCanonicalEviction(page, canonicalSnapshot, expectedScreen) {
  const before = await channelMetrics(page)
  const topic = lastTopic(before)
  assert.ok(topic, "active Conversation topic is observable")
  assert.equal(before.active, 1, "one Conversation runtime is active before canonical correction")
  assert.ok(before.listenerActiveByTopic[topic] > 0, "active Conversation owns realtime listener bindings")

  const beforeState = await page.evaluate(() => window.__f04RuntimeProbe.state())
  assert.ok(beforeState.conversationId, "client believes it has a Conversation before canonical correction")
  assert.equal(beforeState.topic, topic, "probe and channel instrumentation observe the same runtime")

  await page.evaluate((snapshot) => window.__f04RuntimeProbe.reconcile(snapshot), canonicalSnapshot)

  const after = await channelMetrics(page)
  const afterState = await page.evaluate(() => window.__f04RuntimeProbe.state())
  assert.equal(afterState.conversationId, null, "canonical non-Conversation truth clears stale Conversation id authority")
  assert.equal(afterState.currentEpochId, null, "canonical non-Conversation truth clears stale Conversation epoch authority")
  assert.equal(afterState.topic, null, "canonical non-Conversation truth clears stale Conversation channel authority")
  assert.equal(after.left, 1, "canonical non-Conversation truth explicitly leaves the stale Conversation channel")
  assert.equal(after.active, 0, "canonical non-Conversation truth leaves zero active Conversation channels")
  assert.equal(after.runtime[topic]?.socketHasChannel, false, "stale Conversation is absent from socket membership")
  assert.equal(after.listenerActiveByTopic[topic], 0, "canonical non-Conversation truth removes stale Conversation listener bindings")
  assert.equal(await page.locator(`section[data-screen="${expectedScreen}"].active`).count(), 1, `canonical truth presents ${expectedScreen}`)
}

test("F04 canonical AVAILABLE evicts stale Conversation runtime authority", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  const peer = await boot(browser)
  try {
    await matchPair(user.page, peer.page)
    await assertCanonicalEviction(user.page, {canonical_state: "AVAILABLE"}, "doors")
  } finally {
    await Promise.all([user.context, peer.context].map((context) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 canonical QUEUED evicts stale Conversation runtime before queue presentation", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  const peer = await boot(browser)
  try {
    await matchPair(user.page, peer.page)
    await assertCanonicalEviction(user.page, {
      canonical_state: "QUEUED",
      queue: {queue_attempt_id: "f04-canonical-queue", door_type: "EXPLORE", conversation_language: "en"}
    }, "queue")
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
    const topicA = lastTopic(await channelMetrics(user.page))
    assert.ok(topicA, "Conversation A topic is observable")
    await endAndFade(user.page, peerA.page)

    peerB = await boot(browser)
    await matchPair(user.page, peerB.page)
    const topicB = lastTopic(await channelMetrics(user.page))
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

test("F04 repeated and stale cleanup is idempotent and cannot release Conversation B", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  let peerA = null
  let peerB = null
  try {
    peerA = await boot(browser)
    await matchPair(user.page, peerA.page)
    const stateA = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const topicA = lastTopic(await channelMetrics(user.page))
    assert.ok(stateA.conversationId && topicA, "Conversation A identity is captured")

    await endAndFade(user.page, peerA.page)
    const releasedA = await channelMetrics(user.page)
    assert.equal(releasedA.left, 1, "first A cleanup leaves its channel once")
    assert.equal(releasedA.active, 0, "first A cleanup leaves no active channel")
    assert.equal(releasedA.listenerActiveByTopic[topicA], 0, "first A cleanup removes A listener bindings")

    await user.page.evaluate(({conversationId, topic}) => window.__f04RuntimeProbe.release(conversationId, topic), {conversationId: stateA.conversationId, topic: topicA})
    const repeatedA = await channelMetrics(user.page)
    assert.equal(repeatedA.left, 1, "repeating A cleanup does not leave A twice")
    assert.equal(repeatedA.listenerActiveByTopic[topicA], 0, "repeating A cleanup cannot recreate listeners")

    peerB = await boot(browser)
    await matchPair(user.page, peerB.page)
    const stateB = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const metricsB = await channelMetrics(user.page)
    const topicB = lastTopic(metricsB)
    assert.ok(stateB.conversationId && topicB, "Conversation B identity is captured")
    assert.notEqual(stateA.conversationId, stateB.conversationId, "A and B ids are distinct")
    assert.notEqual(topicA, topicB, "A and B channels are distinct")

    await user.page.evaluate(({conversationId, topic}) => window.__f04RuntimeProbe.release(conversationId, topic), {conversationId: stateA.conversationId, topic: topicA})
    const afterState = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const afterMetrics = await channelMetrics(user.page)
    assert.deepEqual(afterState, stateB, "late cleanup for A cannot replace or clear B runtime identity")
    assert.equal(afterMetrics.active, 1, "late A cleanup leaves exactly one active Conversation runtime")
    assert.equal(afterMetrics.runtime[topicB]?.socketHasChannel, true, "B remains subscribed after stale A cleanup")
    assert.ok(afterMetrics.listenerActiveByTopic[topicB] > 0, "B listener bindings remain active after stale A cleanup")
    assert.equal(afterMetrics.left, 1, "late A cleanup does not leave B or double-leave A")
  } finally {
    await Promise.all([user, peerA, peerB].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 stale terminal event from released A is inert after Conversation B begins", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  let peerA = null
  let peerB = null
  try {
    peerA = await boot(browser)
    await matchPair(user.page, peerA.page)
    const topicA = lastTopic(await channelMetrics(user.page))
    await endAndFade(user.page, peerA.page)

    peerB = await boot(browser)
    await matchPair(user.page, peerB.page)
    const beforeB = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const draft = "B remains authoritative after stale A terminal traffic"
    await user.page.locator("#message-input").fill(draft)

    assert.equal(await triggerStaleChannelDirectly(user.page, topicA, "conversation:ended", {}), true, "hostile proof triggers released A terminal callback directly")
    await user.page.waitForTimeout(50)
    assert.deepEqual(await user.page.evaluate(() => window.__f04RuntimeProbe.state()), beforeB, "stale A terminal event cannot alter B runtime identity")
    assert.equal(await user.page.locator("#message-input").inputValue(), draft, "stale A terminal event cannot clear B draft")
    assert.equal(await user.page.locator('section[data-screen="conversation"].active').count(), 1, "B remains the active Conversation surface")
    assert.equal(await user.page.locator('section[data-screen="ended"].active').count(), 0, "stale A terminal event cannot present B as ended")
  } finally {
    await Promise.all([user, peerA, peerB].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 async work begun by A cannot resume into Conversation B", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  let peerA = null
  let peerB = null
  const voiceNoteId = `f04-stale-async-${Date.now()}`
  let releaseVoiceFetch
  let markVoiceFetchStarted
  const voiceFetchStarted = new Promise((resolve) => { markVoiceFetchStarted = resolve })
  const voiceFetchBarrier = new Promise((resolve) => { releaseVoiceFetch = resolve })

  try {
    peerA = await boot(browser)
    await matchPair(user.page, peerA.page)
    const topicA = lastTopic(await channelMetrics(user.page))

    await user.page.route(`**/voice-notes/${voiceNoteId}`, async (route) => {
      markVoiceFetchStarted()
      await voiceFetchBarrier
      await route.fulfill({status: 200, contentType: "audio/webm", body: Buffer.from([1, 2, 3, 4])})
    })

    assert.equal(await triggerStaleChannelDirectly(user.page, topicA, "voice_note:new", {
      voice_note_id: voiceNoteId,
      timestamp: new Date().toISOString(),
      sequence: 777,
      duration_ms: 250,
      byte_size: 4,
      media_type: "audio/webm"
    }), true, "Conversation A async voice callback starts while A is current")
    await voiceFetchStarted

    await endAndFade(user.page, peerA.page)
    peerB = await boot(browser)
    await matchPair(user.page, peerB.page)
    const stateB = await user.page.evaluate(() => window.__f04RuntimeProbe.state())

    releaseVoiceFetch()
    await user.page.waitForTimeout(150)
    assert.deepEqual(await user.page.evaluate(() => window.__f04RuntimeProbe.state()), stateB, "resumed A async work cannot alter B runtime identity")
    assert.equal(await user.page.locator(`[data-voice-note-id="${voiceNoteId}"]`).count(), 0, "resumed A voice callback cannot render a voice note into B")
    assert.equal(await user.page.evaluate(({conversationId, noteId}) => window.__f04RuntimeProbe.voiceRecord(conversationId, noteId), {conversationId: stateB.conversationId, noteId: voiceNoteId}), null, "resumed A async callback cannot persist its voice record under B")
  } finally {
    releaseVoiceFetch?.()
    await Promise.all([user, peerA, peerB].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})

test("F04 foreground and background visibility do not replace Conversation runtime", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const user = await boot(browser, {instrument: true})
  const peer = await boot(browser)
  try {
    await matchPair(user.page, peer.page)
    const beforeState = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const beforeMetrics = await channelMetrics(user.page)
    const topic = lastTopic(beforeMetrics)

    await user.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {configurable: true, get: () => "hidden"})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await user.page.waitForTimeout(50)
    const hiddenState = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const hiddenMetrics = await channelMetrics(user.page)
    assert.deepEqual(hiddenState, beforeState, "background visibility preserves Conversation identity")
    assert.equal(hiddenMetrics.created, beforeMetrics.created, "background visibility creates no new channel")
    assert.equal(hiddenMetrics.active, 1, "background visibility keeps one active Conversation runtime")
    assert.equal(hiddenMetrics.runtime[topic]?.socketHasChannel, true, "background visibility keeps current channel subscribed")

    await user.page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {configurable: true, get: () => "visible"})
      document.dispatchEvent(new Event("visibilitychange"))
    })
    await user.page.waitForTimeout(50)
    const visibleState = await user.page.evaluate(() => window.__f04RuntimeProbe.state())
    const visibleMetrics = await channelMetrics(user.page)
    assert.deepEqual(visibleState, beforeState, "foreground recovery preserves Conversation identity")
    assert.equal(visibleMetrics.created, beforeMetrics.created, "foreground recovery creates no duplicate channel")
    assert.equal(visibleMetrics.active, 1, "foreground recovery keeps exactly one active runtime")
    assert.equal(visibleMetrics.listenerOn, beforeMetrics.listenerOn, "visibility transitions do not register duplicate realtime listeners")
  } finally {
    await Promise.all([user.context, peer.context].map((context) => context.close().catch(() => {})))
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
    assert.ok(before.listenerActiveByTopic[topic] > 0, "one active listener set exists before reconnect")

    await disconnectAndReconnectConversationSocket(user.page, topic)
    await user.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})
    const after = await channelMetrics(user.page)
    assert.equal(after.created, 1, "reconnect does not create another Conversation channel")
    assert.equal(after.active, 1, "reconnect leaves exactly one active Conversation channel")
    assert.equal(after.maxActive, 1, "reconnect never overlaps duplicate Conversation channels")
    assert.equal(after.runtime[topic]?.socketHasChannel, true, "same Conversation channel remains socket-authoritative after reconnect")
    assert.equal(after.listenerOn, before.listenerOn, "reconnect does not register a second application listener set")
    assert.equal(after.listenerActiveByTopic[topic], before.listenerActiveByTopic[topic], "reconnect preserves exactly the original listener set")

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
    const topicBefore = lastTopic(await channelMetrics(user.page))
    assert.ok(topicBefore, "Conversation topic is observable before reload")

    await user.page.reload({waitUntil: "domcontentloaded"})
    await user.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT})
    const after = await channelMetrics(user.page)
    const topicAfter = lastTopic(after)
    assert.equal(topicAfter, topicBefore, "reload recovers the same canonical Conversation id")
    assert.equal(after.created, 1, "new page creates exactly one Conversation channel for recovery")
    assert.equal(after.active, 1, "new page has exactly one active Conversation runtime")
    assert.equal(after.maxActive, 1, "reload recovery never creates duplicate page-local Conversation runtime")
    assert.ok(after.listenerActiveByTopic[topicAfter] > 0, "reloaded runtime owns one active realtime listener set")
  } finally {
    await Promise.all([user.context, peer.context].map((context) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})
