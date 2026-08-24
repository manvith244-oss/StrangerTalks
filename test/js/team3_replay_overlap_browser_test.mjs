import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"

async function bootstrap(page, identity = null) {
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

    window.__team3_overlap = {identity, socket, participant, matches, join, conversation: null, events: []}
    return identity
  }, identity)
}

async function push(page, scope, event, payload) {
  return page.evaluate(({scope, event, payload}) => new Promise((resolve) => {
    window.__team3_overlap[scope].push(event, payload, 5000)
      .receive("ok", (value) => resolve({kind: "ok", value}))
      .receive("error", (value) => resolve({kind: "error", value}))
      .receive("timeout", () => resolve({kind: "timeout"}))
  }), {scope, event, payload})
}

async function waitForMatch(page) {
  await page.waitForFunction(() => window.__team3_overlap.matches.length > 0, null, {timeout: 10_000})
  return page.evaluate(() => window.__team3_overlap.matches.at(-1))
}

async function joinConversation(page, conversationId, epochId = null, lastAppliedSequence = 0) {
  return page.evaluate(async ({conversationId, epochId, lastAppliedSequence}) => {
    const channel = window.__team3_overlap.socket.channel(`conversation:${conversationId}`, {
      epoch_id: epochId,
      last_applied_sequence: lastAppliedSequence
    })
    window.__team3_overlap.events = []
    channel.on("message:new", (payload) => window.__team3_overlap.events.push(payload))
    window.__team3_overlap.conversation = channel
    return window.__team3_overlap.join(channel)
  }, {conversationId, epochId, lastAppliedSequence})
}

async function establish(pageA, pageB) {
  const [a, b] = await Promise.all([bootstrap(pageA), bootstrap(pageB)])
  const queue = {door_type: "JUST_TALK", conversation_language: "en"}
  assert.equal((await push(pageA, "participant", "queue:join", queue)).kind, "ok")
  assert.equal((await push(pageB, "participant", "queue:join", queue)).kind, "ok")

  const [matchA, matchB] = await Promise.all([waitForMatch(pageA), waitForMatch(pageB)])
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

test("live arrival overlapping replay is represented exactly once in canonical sequence", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()

  try {
    const {b, conversationId, epochId} = await establish(pageA, pageB)

    await pageB.evaluate(() => window.__team3_overlap.socket.disconnect())
    await pageB.waitForFunction(() => window.__team3_overlap.socket.isConnected() === false)

    const replayOne = crypto.randomUUID()
    const replayTwo = crypto.randomUUID()
    const sentOne = await push(pageA, "conversation", "message:send", {
      client_message_id: replayOne,
      content: "replay-one"
    })
    const sentTwo = await push(pageA, "conversation", "message:send", {
      client_message_id: replayTwo,
      content: "replay-two"
    })
    assert.deepEqual([sentOne.value.sequence, sentTwo.value.sequence], [1, 2])

    await bootstrap(pageB, b)

    const live = crypto.randomUUID()
    const rejoinPromise = joinConversation(pageB, conversationId, epochId, 0)
    const livePromise = push(pageA, "conversation", "message:send", {
      client_message_id: live,
      content: "overlap-live"
    })
    const [rejoin, liveAccepted] = await Promise.all([rejoinPromise, livePromise])
    assert.equal(rejoin.kind, "ok")
    assert.equal(liveAccepted.kind, "ok")
    assert.equal(liveAccepted.value.sequence, 3)

    await new Promise((resolve) => setTimeout(resolve, 300))
    const liveEvents = await pageB.evaluate(() => window.__team3_overlap.events)
    const combined = [...(rejoin.value.messages || []), ...liveEvents]

    for (const id of [replayOne, replayTwo, live]) {
      const occurrences = combined.filter((message) => message.client_message_id === id)
      assert.equal(occurrences.length, 1, `logical message ${id} appeared ${occurrences.length} times`)
    }

    const canonical = combined
      .slice()
      .sort((left, right) => left.sequence - right.sequence)
      .map((message) => [message.sequence, message.client_message_id])

    assert.deepEqual(canonical, [
      [1, replayOne],
      [2, replayTwo],
      [3, live]
    ])

    const progress = await push(pageB, "conversation", "delivery:progress", {
      epoch_id: rejoin.value.epoch_id,
      highest_contiguous_sequence: 3
    })
    assert.equal(progress.kind, "ok")
    assert.equal(progress.value.highest_contiguous_sequence, 3)
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})

test("replay resumes after a second disconnect without duplicating the already-applied prefix", {timeout: 35_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()

  try {
    const {b, conversationId, epochId} = await establish(pageA, pageB)

    await pageB.evaluate(() => window.__team3_overlap.socket.disconnect())
    await pageB.waitForFunction(() => window.__team3_overlap.socket.isConnected() === false)

    const first = crypto.randomUUID()
    const firstAccepted = await push(pageA, "conversation", "message:send", {
      client_message_id: first,
      content: "first replay generation"
    })
    assert.equal(firstAccepted.kind, "ok")
    assert.equal(firstAccepted.value.sequence, 1)

    await bootstrap(pageB, b)
    const firstReplay = await joinConversation(pageB, conversationId, epochId, 0)
    assert.equal(firstReplay.kind, "ok")
    assert.deepEqual(
      (firstReplay.value.messages || []).map((message) => [message.sequence, message.client_message_id]),
      [[1, first]]
    )

    const firstProgress = await push(pageB, "conversation", "delivery:progress", {
      epoch_id: firstReplay.value.epoch_id,
      highest_contiguous_sequence: 1
    })
    assert.equal(firstProgress.kind, "ok")
    assert.equal(firstProgress.value.highest_contiguous_sequence, 1)

    await pageB.evaluate(() => window.__team3_overlap.socket.disconnect())
    await pageB.waitForFunction(() => window.__team3_overlap.socket.isConnected() === false)

    const second = crypto.randomUUID()
    const secondAccepted = await push(pageA, "conversation", "message:send", {
      client_message_id: second,
      content: "second replay generation"
    })
    assert.equal(secondAccepted.kind, "ok")
    assert.equal(secondAccepted.value.sequence, 2)

    await bootstrap(pageB, b)
    const resumed = await joinConversation(pageB, conversationId, firstReplay.value.epoch_id, 1)
    assert.equal(resumed.kind, "ok")

    const replayed = resumed.value.messages || []
    assert.deepEqual(
      replayed.map((message) => [message.sequence, message.client_message_id]),
      [[2, second]]
    )
    assert.equal(replayed.filter((message) => message.client_message_id === first).length, 0)

    const secondProgress = await push(pageB, "conversation", "delivery:progress", {
      epoch_id: resumed.value.epoch_id,
      highest_contiguous_sequence: 2
    })
    assert.equal(secondProgress.kind, "ok")
    assert.equal(secondProgress.value.highest_contiguous_sequence, 2)
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})
