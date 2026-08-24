import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"

function assertOkResult(result, label) {
  assert.equal(result.kind, "ok", `${label}: ${JSON.stringify(result)}`)
  return result.value
}

async function bootstrapParticipant(page, identity = null) {
  await page.goto(`${BASE_URL}/health/live`, {waitUntil: "domcontentloaded"})

  return page.evaluate(async (providedIdentity) => {
    const {Socket} = await import("/vendor/phoenix.mjs")

    const identity = providedIdentity || await fetch("/api/participants", {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: "{}"
    }).then(async (response) => {
      if (!response.ok) throw new Error(`participant bootstrap failed: ${response.status}`)
      return response.json()
    })

    const joinChannelResult = (channel) => new Promise((resolve) => {
      channel.join(5000)
        .receive("ok", (value) => resolve({kind: "ok", value}))
        .receive("error", (value) => resolve({kind: "error", value}))
        .receive("timeout", () => resolve({kind: "timeout", value: {reason: "join_timeout"}}))
    })

    const socket = new Socket("/socket", {
      authToken: () => identity.token,
      timeout: 5000,
      reconnectAfterMs: () => 100,
      rejoinAfterMs: () => 100
    })

    const events = {
      match: [],
      messages: [],
      statuses: [],
      ended: [],
      presence: [],
      typing: []
    }

    socket.connect()
    const participant = socket.channel(`participant:${identity.participant_id}`, {})
    participant.on("match_found", (payload) => events.match.push(payload))
    const participantJoinResult = await joinChannelResult(participant)
    if (participantJoinResult.kind !== "ok") {
      throw new Error(`ParticipantChannel join failed: ${JSON.stringify(participantJoinResult)}`)
    }

    window.__t5 = {
      identity,
      socket,
      participant,
      conversation: null,
      conversationId: null,
      events,
      participantJoin: participantJoinResult.value,
      joinChannelResult
    }

    return {identity, participantJoin: participantJoinResult.value}
  }, identity)
}

async function pushParticipant(page, event, payload) {
  const result = await page.evaluate(({event, payload}) => new Promise((resolve) => {
    window.__t5.participant.push(event, payload, 5000)
      .receive("ok", (value) => resolve({kind: "ok", value}))
      .receive("error", (value) => resolve({kind: "error", value}))
      .receive("timeout", () => resolve({kind: "timeout", value: {reason: "push_timeout", event}}))
  }), {event, payload})
  return assertOkResult(result, `participant push ${event}`)
}

async function joinConversationResult(page, conversationId, epochId = null, lastAppliedSequence = 0) {
  return page.evaluate(async ({conversationId, epochId, lastAppliedSequence}) => {
    const channel = window.__t5.socket.channel(`conversation:${conversationId}`, {
      epoch_id: epochId,
      last_applied_sequence: lastAppliedSequence
    })

    const events = window.__t5.events
    channel.on("message:new", (payload) => events.messages.push(payload))
    channel.on("message:status", (payload) => events.statuses.push(payload))
    channel.on("conversation:ended", (payload) => events.ended.push(payload))
    channel.on("conversation:presence", (payload) => events.presence.push(payload))
    channel.on("typing:status", (payload) => events.typing.push(payload))

    window.__t5.conversation = channel
    window.__t5.conversationId = conversationId

    const result = await window.__t5.joinChannelResult(channel)
    if (result.kind === "ok") window.__t5.sync = result.value
    return result
  }, {conversationId, epochId, lastAppliedSequence})
}

async function joinConversation(page, conversationId, epochId = null, lastAppliedSequence = 0) {
  const result = await joinConversationResult(page, conversationId, epochId, lastAppliedSequence)
  return assertOkResult(result, `ConversationChannel join ${conversationId}`)
}

async function pushConversationResult(page, event, payload) {
  return page.evaluate(({event, payload}) => new Promise((resolve) => {
    window.__t5.conversation.push(event, payload, 5000)
      .receive("ok", (value) => resolve({kind: "ok", value}))
      .receive("error", (value) => resolve({kind: "error", value}))
      .receive("timeout", () => resolve({kind: "timeout", value: {reason: "push_timeout", event}}))
  }), {event, payload})
}

async function pushConversation(page, event, payload) {
  const result = await pushConversationResult(page, event, payload)
  return assertOkResult(result, `conversation push ${event}`)
}

async function disconnect(page) {
  await page.evaluate(() => {
    window.__t5.socket.disconnect()
  })
  await page.waitForFunction(() => window.__t5.socket.isConnected() === false)
}

async function waitForMatch(page) {
  await page.waitForFunction(() => window.__t5.events.match.length > 0, null, {timeout: 10_000})
  return page.evaluate(() => window.__t5.events.match.at(-1))
}

async function waitForMessage(page, clientMessageId) {
  await page.waitForFunction(
    (id) => window.__t5.events.messages.some((entry) => entry.client_message_id === id),
    clientMessageId,
    {timeout: 10_000}
  )

  return page.evaluate(
    (id) => window.__t5.events.messages.find((entry) => entry.client_message_id === id),
    clientMessageId
  )
}

async function waitForEnded(page) {
  await page.waitForFunction(() => window.__t5.events.ended.length > 0, null, {timeout: 10_000})
  return page.evaluate(() => window.__t5.events.ended.at(-1))
}

function uniqueByClientMessageId(messages) {
  const unique = new Map()
  for (const message of messages) {
    if (message?.client_message_id) unique.set(message.client_message_id, message)
  }
  return [...unique.values()]
}

function messageIdsInSequence(messages) {
  return uniqueByClientMessageId(messages)
    .sort((a, b) => a.sequence - b.sequence)
    .map((message) => message.client_message_id)
}

test("two isolated browsers converge across disconnect, replay, reconnect and terminal end", async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()

  try {
    const a = await bootstrapParticipant(pageA)
    const b = await bootstrapParticipant(pageB)
    assert.notEqual(a.identity.participant_id, b.identity.participant_id)

    const queuePayload = {door_type: "JUST_TALK", conversation_language: "en"}
    const aQueued = await pushParticipant(pageA, "queue:join", queuePayload)
    const bQueued = await pushParticipant(pageB, "queue:join", queuePayload)
    assert.equal(aQueued.status, "queued")
    assert.equal(bQueued.status, "queued")

    const [matchA, matchB] = await Promise.all([waitForMatch(pageA), waitForMatch(pageB)])
    assert.equal(matchA.conversation_id, matchB.conversation_id)
    const conversationId = matchA.conversation_id
    assert.ok(conversationId)

    const reconcileA = await pushParticipant(pageA, "session:reconcile", {})
    const reconcileB = await pushParticipant(pageB, "session:reconcile", {})
    assert.equal(reconcileA.snapshot?.conversation?.conversation_id, conversationId)
    assert.equal(reconcileB.snapshot?.conversation?.conversation_id, conversationId)

    const syncA = await joinConversation(pageA, conversationId)
    const syncB = await joinConversation(pageB, conversationId)
    assert.ok(syncA.epoch_id)
    assert.equal(syncA.epoch_id, syncB.epoch_id)
    const firstEpoch = syncA.epoch_id

    const m1 = crypto.randomUUID()
    const accepted1 = await pushConversation(pageA, "message:send", {
      client_message_id: m1,
      content: "T5-M1"
    })
    assert.equal(accepted1.sequence, 1)
    const delivered1 = await waitForMessage(pageB, m1)
    assert.equal(delivered1.sequence, 1)
    assert.equal(delivered1.content, "T5-M1")

    const progress1 = await pushConversation(pageB, "delivery:progress", {
      epoch_id: firstEpoch,
      highest_contiguous_sequence: 1
    })
    const duplicateProgress1 = await pushConversation(pageB, "delivery:progress", {
      epoch_id: firstEpoch,
      highest_contiguous_sequence: 1
    })
    assert.equal(progress1.highest_contiguous_sequence, 1)
    assert.equal(duplicateProgress1.highest_contiguous_sequence, 1)

    await disconnect(pageB)

    const m2 = crypto.randomUUID()
    const m3 = crypto.randomUUID()
    const accepted2 = await pushConversation(pageA, "message:send", {
      client_message_id: m2,
      content: "T5-M2"
    })
    const accepted3 = await pushConversation(pageA, "message:send", {
      client_message_id: m3,
      content: "T5-M3"
    })
    assert.deepEqual([accepted2.sequence, accepted3.sequence], [2, 3])

    await bootstrapParticipant(pageB, b.identity)

    const m4 = crypto.randomUUID()
    const rejoinBPromise = joinConversation(pageB, conversationId, firstEpoch, 1)
    const accepted4Promise = pushConversation(pageA, "message:send", {
      client_message_id: m4,
      content: "T5-M4"
    })
    const [rejoinB, accepted4] = await Promise.all([rejoinBPromise, accepted4Promise])
    assert.equal(accepted4.sequence, 4)

    await waitForMessage(pageB, m4).catch(() => null)
    const liveAfterRejoinB = await pageB.evaluate(() => window.__t5.events.messages)
    const replayAndLiveB = [...(rejoinB.messages || []), ...liveAfterRejoinB]
    assert.deepEqual(messageIdsInSequence(replayAndLiveB), [m2, m3, m4])

    const m5 = crypto.randomUUID()
    const accepted5 = await pushConversation(pageB, "message:send", {
      client_message_id: m5,
      content: "T5-M5"
    })
    assert.equal(accepted5.sequence, 5)
    const delivered5 = await waitForMessage(pageA, m5)
    assert.equal(delivered5.sequence, 5)

    await disconnect(pageA)

    const m6 = crypto.randomUUID()
    const accepted6 = await pushConversation(pageB, "message:send", {
      client_message_id: m6,
      content: "T5-M6"
    })
    assert.equal(accepted6.sequence, 6)

    await bootstrapParticipant(pageA, a.identity)
    const rejoinA = await joinConversation(pageA, conversationId, firstEpoch, 5)
    const replayA = rejoinA.messages || []
    assert.deepEqual(messageIdsInSequence(replayA), [m6])

    const endResult = await pushConversation(pageA, "conversation:end", {})
    assert.ok(endResult)
    const [endedA, endedB] = await Promise.all([waitForEnded(pageA), waitForEnded(pageB)])
    assert.equal(endedA.conversation_id, conversationId)
    assert.equal(endedB.conversation_id, conversationId)

    const stalePostTerminalSend = await pushConversationResult(pageB, "message:send", {
      client_message_id: crypto.randomUUID(),
      content: "MUST-NOT-RESURRECT"
    })
    assert.notEqual(stalePostTerminalSend.kind, "ok")

    const freshRuntimeAttempt = await joinConversationResult(pageA, conversationId, firstEpoch, 6)
    assert.notEqual(freshRuntimeAttempt.kind, "ok")
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})
