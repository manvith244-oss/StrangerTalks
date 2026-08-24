import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"

async function boot(page, identity = null) {
  await page.goto(`${BASE_URL}/health/live`, {waitUntil: "domcontentloaded"})

  return page.evaluate(async (providedIdentity) => {
    const {Socket} = await import("/vendor/phoenix.mjs")
    const identity = providedIdentity || await fetch("/api/participants", {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: "{}"
    }).then((response) => response.json())

    const socket = new Socket("/socket", {
      authToken: () => identity.token,
      timeout: 5000,
      reconnectAfterMs: () => 100,
      rejoinAfterMs: () => 100
    })
    socket.connect()

    const participant = socket.channel(`participant:${identity.participant_id}`, {})
    const matches = []
    participant.on("match_found", (payload) => matches.push(payload))

    const join = (channel) => new Promise((resolve) => {
      channel.join(5000)
        .receive("ok", (value) => resolve({kind: "ok", value}))
        .receive("error", (value) => resolve({kind: "error", value}))
        .receive("timeout", () => resolve({kind: "timeout"}))
    })

    const participantJoin = await join(participant)
    if (participantJoin.kind !== "ok") throw new Error(`participant join failed: ${JSON.stringify(participantJoin)}`)

    window.__team3 = {identity, socket, participant, matches, join, conversation: null, conversationId: null}
    return identity
  }, identity)
}

async function push(page, scope, event, payload) {
  return page.evaluate(({scope, event, payload}) => new Promise((resolve) => {
    window.__team3[scope].push(event, payload, 5000)
      .receive("ok", (value) => resolve({kind: "ok", value}))
      .receive("error", (value) => resolve({kind: "error", value}))
      .receive("timeout", () => resolve({kind: "timeout", value: {event}}))
  }), {scope, event, payload})
}

async function waitForNewMatch(page, previousConversationId = null) {
  await page.waitForFunction(
    (previous) => window.__team3.matches.some((match) => match.conversation_id !== previous),
    previousConversationId,
    {timeout: 10_000}
  )
  return page.evaluate(
    (previous) => window.__team3.matches.findLast((match) => match.conversation_id !== previous),
    previousConversationId
  )
}

async function joinConversation(page, conversationId, epochId = null, lastAppliedSequence = 0) {
  return page.evaluate(async ({conversationId, epochId, lastAppliedSequence}) => {
    const channel = window.__team3.socket.channel(`conversation:${conversationId}`, {
      epoch_id: epochId,
      last_applied_sequence: lastAppliedSequence
    })
    const events = {messages: [], ended: [], presence: [], typing: []}
    channel.on("message:new", (payload) => events.messages.push(payload))
    channel.on("conversation:ended", (payload) => events.ended.push(payload))
    channel.on("conversation:presence", (payload) => events.presence.push(payload))
    channel.on("typing:status", (payload) => events.typing.push(payload))
    window.__team3.conversation = channel
    window.__team3.conversationId = conversationId
    window.__team3.events = events
    const result = await window.__team3.join(channel)
    return result
  }, {conversationId, epochId, lastAppliedSequence})
}

async function establish(pageA, pageB) {
  const [a, b] = await Promise.all([boot(pageA), boot(pageB)])
  const queue = {door_type: "JUST_TALK", conversation_language: "en"}
  assert.equal((await push(pageA, "participant", "queue:join", queue)).kind, "ok")
  assert.equal((await push(pageB, "participant", "queue:join", queue)).kind, "ok")
  const [matchA, matchB] = await Promise.all([waitForNewMatch(pageA), waitForNewMatch(pageB)])
  assert.equal(matchA.conversation_id, matchB.conversation_id)
  const conversationId = matchA.conversation_id
  const [syncA, syncB] = await Promise.all([
    joinConversation(pageA, conversationId),
    joinConversation(pageB, conversationId)
  ])
  assert.equal(syncA.kind, "ok")
  assert.equal(syncB.kind, "ok")
  assert.equal(syncA.value.epoch_id, syncB.value.epoch_id)
  return {a, b, conversationId, epochId: syncA.value.epoch_id}
}

test("malformed and stale Conversation events fail closed without killing the channel", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()
  const pageErrors = []
  pageA.on("pageerror", (error) => pageErrors.push(error.message))
  pageB.on("pageerror", (error) => pageErrors.push(error.message))

  try {
    const {conversationId, epochId} = await establish(pageA, pageB)

    const malformed = [
      await push(pageA, "conversation", "message:send", {}),
      await push(pageA, "conversation", "message:send", {client_message_id: "not-a-uuid", content: "bad"}),
      await push(pageA, "conversation", "delivery:progress", {epoch_id: epochId, highest_contiguous_sequence: "1"}),
      await push(pageA, "conversation", "delivery:progress", {epoch_id: "stale-epoch", highest_contiguous_sequence: 0}),
      await push(pageA, "conversation", "typing:start", {impossible: true}),
      await push(pageA, "conversation", "totally:unknown", {conversation_id: conversationId})
    ]

    for (const result of malformed) assert.equal(result.kind, "error", JSON.stringify(result))

    const messageId = crypto.randomUUID()
    const valid = await push(pageA, "conversation", "message:send", {
      client_message_id: messageId,
      content: "channel survived malformed inputs"
    })
    assert.equal(valid.kind, "ok")
    assert.equal(valid.value.sequence, 1)

    await pageB.waitForFunction(
      (id) => window.__team3.events.messages.some((message) => message.client_message_id === id),
      messageId,
      {timeout: 10_000}
    )
    const occurrences = await pageB.evaluate(
      (id) => window.__team3.events.messages.filter((message) => message.client_message_id === id).length,
      messageId
    )
    assert.equal(occurrences, 1)
    assert.deepEqual(pageErrors, [])
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})

test("old Conversation channel work cannot mutate the later Conversation", {timeout: 35_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()

  try {
    const {conversationId: oldId} = await establish(pageA, pageB)
    await pageA.evaluate(() => { window.__team3.oldConversation = window.__team3.conversation })
    await pageB.evaluate(() => { window.__team3.oldConversation = window.__team3.conversation })

    const oldMessageId = crypto.randomUUID()
    const oldSend = await push(pageA, "conversation", "message:send", {
      client_message_id: oldMessageId,
      content: "old Conversation pending retry"
    })
    assert.equal(oldSend.kind, "ok")

    const ended = await push(pageA, "conversation", "conversation:end", {})
    assert.equal(ended.kind, "ok")

    const queue = {door_type: "JUST_TALK", conversation_language: "en"}
    assert.equal((await push(pageA, "participant", "queue:join", queue)).kind, "ok")
    assert.equal((await push(pageB, "participant", "queue:join", queue)).kind, "ok")
    const [matchA, matchB] = await Promise.all([
      waitForNewMatch(pageA, oldId),
      waitForNewMatch(pageB, oldId)
    ])
    assert.equal(matchA.conversation_id, matchB.conversation_id)
    assert.notEqual(matchA.conversation_id, oldId)
    const newId = matchA.conversation_id

    const [newSyncA, newSyncB] = await Promise.all([
      joinConversation(pageA, newId),
      joinConversation(pageB, newId)
    ])
    assert.equal(newSyncA.kind, "ok")
    assert.equal(newSyncB.kind, "ok")
    assert.equal(newSyncA.value.latest_sequence, 0)
    assert.equal(newSyncB.value.latest_sequence, 0)

    const staleResults = await pageA.evaluate(({oldId}) => Promise.all([
      ["message:send", {client_message_id: crypto.randomUUID(), content: "must not reach B"}],
      ["typing:start", {}],
      ["delivery:progress", {epoch_id: "obsolete", highest_contiguous_sequence: 1}]
    ].map(([event, payload]) => new Promise((resolve) => {
      window.__team3.oldConversation.push(event, payload, 3000)
        .receive("ok", (value) => resolve({kind: "ok", value}))
        .receive("error", (value) => resolve({kind: "error", value}))
        .receive("timeout", () => resolve({kind: "timeout"}))
    }))), {oldId})
    for (const result of staleResults) assert.notEqual(result.kind, "ok", JSON.stringify(result))

    const freshMessageId = crypto.randomUUID()
    const fresh = await push(pageB, "conversation", "message:send", {
      client_message_id: freshMessageId,
      content: "new Conversation remains authoritative"
    })
    assert.equal(fresh.kind, "ok")
    assert.equal(fresh.value.sequence, 1)

    await pageA.waitForFunction(
      (id) => window.__team3.events.messages.some((message) => message.client_message_id === id),
      freshMessageId,
      {timeout: 10_000}
    )
    const newEvents = await pageA.evaluate(() => window.__team3.events)
    assert.equal(newEvents.messages.length, 1)
    assert.equal(newEvents.messages[0].client_message_id, freshMessageId)
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})
