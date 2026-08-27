import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"

function assertOk(result, label) {
  assert.equal(result.kind, "ok", `${label}: ${JSON.stringify(result)}`)
  return result.value
}

async function rawBootstrap(page, identity = null) {
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

    const joinResult = (channel) => new Promise((resolve) => {
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
    const events = {match: [], ended: [], incoming: [], messages: []}
    socket.connect()
    const participant = socket.channel(`participant:${identity.participant_id}`, {})
    participant.on("match_found", (payload) => events.match.push(payload))
    const participantJoin = await joinResult(participant)
    if (participantJoin.kind !== "ok") throw new Error(`participant join failed: ${JSON.stringify(participantJoin)}`)
    window.__terminal = {identity, socket, participant, conversation: null, conversationId: null, events, joinResult}
    return {identity, participantJoin: participantJoin.value}
  }, identity)
}

async function rawParticipantPush(page, event, payload = {}) {
  return assertOk(await page.evaluate(({event, payload}) => new Promise((resolve) => {
    window.__terminal.participant.push(event, payload, 5000)
      .receive("ok", (value) => resolve({kind: "ok", value}))
      .receive("error", (value) => resolve({kind: "error", value}))
      .receive("timeout", () => resolve({kind: "timeout", value: {event}}))
  }), {event, payload}), `participant ${event}`)
}

async function rawConversationJoinResult(page, conversationId, epochId = null, lastAppliedSequence = 0) {
  return page.evaluate(async ({conversationId, epochId, lastAppliedSequence}) => {
    const channel = window.__terminal.socket.channel(`conversation:${conversationId}`, {
      epoch_id: epochId,
      last_applied_sequence: lastAppliedSequence
    })
    channel.on("conversation:ended", (payload) => window.__terminal.events.ended.push(payload))
    channel.on("call:incoming", (payload) => window.__terminal.events.incoming.push(payload))
    channel.on("message:new", (payload) => window.__terminal.events.messages.push(payload))
    window.__terminal.conversation = channel
    window.__terminal.conversationId = conversationId
    const result = await window.__terminal.joinResult(channel)
    if (result.kind === "ok") window.__terminal.sync = result.value
    return result
  }, {conversationId, epochId, lastAppliedSequence})
}

async function rawConversationJoin(page, conversationId, epochId = null, lastAppliedSequence = 0) {
  return assertOk(await rawConversationJoinResult(page, conversationId, epochId, lastAppliedSequence), `conversation join ${conversationId}`)
}

async function rawConversationPushResult(page, event, payload = {}) {
  return page.evaluate(({event, payload}) => new Promise((resolve) => {
    window.__terminal.conversation.push(event, payload, 5000)
      .receive("ok", (value) => resolve({kind: "ok", value}))
      .receive("error", (value) => resolve({kind: "error", value}))
      .receive("timeout", () => resolve({kind: "timeout", value: {event}}))
  }), {event, payload})
}

async function rawConversationPush(page, event, payload = {}) {
  return assertOk(await rawConversationPushResult(page, event, payload), `conversation ${event}`)
}

async function rawWaitForMatch(page) {
  await page.waitForFunction(() => window.__terminal.events.match.length > 0, null, {timeout: 10_000})
  return page.evaluate(() => window.__terminal.events.match.at(-1))
}

async function rawWaitForEnded(page, count = 1) {
  await page.waitForFunction((wanted) => window.__terminal.events.ended.length >= wanted, count, {timeout: 10_000})
  return page.evaluate(() => window.__terminal.events.ended.at(-1))
}

async function rawEstablish(pageA, pageB) {
  const a = await rawBootstrap(pageA)
  const b = await rawBootstrap(pageB)
  assert.notEqual(a.identity.participant_id, b.identity.participant_id)
  const payload = {door_type: "JUST_TALK", conversation_language: "en"}
  await rawParticipantPush(pageA, "queue:join", payload)
  await rawParticipantPush(pageB, "queue:join", payload)
  const [matchA, matchB] = await Promise.all([rawWaitForMatch(pageA), rawWaitForMatch(pageB)])
  assert.equal(matchA.conversation_id, matchB.conversation_id)
  const conversationId = matchA.conversation_id
  const syncA = await rawConversationJoin(pageA, conversationId)
  const syncB = await rawConversationJoin(pageB, conversationId)
  assert.ok(syncA.epoch_id)
  assert.equal(syncA.epoch_id, syncB.epoch_id)
  return {a, b, conversationId, epochId: syncA.epoch_id}
}

async function rawDisconnect(page) {
  await page.evaluate(() => window.__terminal.socket.disconnect())
  await page.waitForFunction(() => window.__terminal.socket.isConnected() === false)
}

async function assertNoCanonicalConversation(page) {
  const reconcile = await rawParticipantPush(page, "session:reconcile", {})
  assert.equal(reconcile.snapshot?.conversation ?? null, null)
}

async function prepareUiPage(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForSelector("#conversation-language")
  await page.waitForFunction(() => document.querySelectorAll(".door").length >= 4)
  await page.selectOption("#conversation-language", "en")
}

async function uiJoinQueue(page) {
  await page.click('.door[data-door="JUST_TALK"]')
}

async function uiWaitForConversation(page) {
  await page.waitForSelector('section[data-screen="conversation"].active', {timeout: 15_000})
}

async function uiWaitForEnded(page) {
  await page.waitForSelector('section[data-screen="ended"].active', {timeout: 15_000})
}

async function uiOpenMessageTools(page) {
  await page.click(".ig-compose-plus")
  await page.waitForFunction(() => {
    const form = document.querySelector("#message-form")
    const tray = document.querySelector("#ig-message-tools")
    return form?.classList.contains("ig-tray-open") && tray && getComputedStyle(tray).display !== "none"
  })
}

async function uiOpenConversationInfo(page) {
  await page.click(".conversation-head-actions .overflow summary")
  await page.waitForFunction(() => document.querySelector(".conversation-head-actions .overflow")?.open === true)
}

async function uiMatch(pageA, pageB) {
  await Promise.all([prepareUiPage(pageA), prepareUiPage(pageB)])
  await Promise.all([uiJoinQueue(pageA), uiJoinQueue(pageB)])
  await Promise.all([uiWaitForConversation(pageA), uiWaitForConversation(pageB)])
}

test("Block is terminal authority for blocker, peer, sibling tab, stale actions, reconnect, and ringing media", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()
  let sibling = null

  try {
    const {a, conversationId, epochId} = await rawEstablish(pageA, pageB)
    sibling = await contextA.newPage()
    await rawBootstrap(sibling, a.identity)
    await rawConversationJoin(sibling, conversationId, epochId, 0)

    const call = await rawConversationPush(pageA, "call:initiate", {call_type: "voice"})
    assert.ok(call.call_attempt_id)
    await pageB.waitForFunction(() => window.__terminal.events.incoming.length > 0, null, {timeout: 10_000})

    const blocked = await rawConversationPush(sibling, "conversation:block", {})
    assert.equal(blocked.status, "blocked")

    const terminalEvents = await Promise.all([
      rawWaitForEnded(pageA),
      rawWaitForEnded(sibling),
      rawWaitForEnded(pageB)
    ])
    for (const event of terminalEvents) {
      assert.deepEqual(event, {status: "ended", reason: "blocked"})
    }

    for (const [page, event, payload] of [
      [pageA, "message:send", {client_message_id: crypto.randomUUID(), content: "stale"}],
      [pageB, "typing:start", {}],
      [sibling, "call:initiate", {call_type: "voice"}],
      [pageA, "message:reply_target", {reply_to_client_message_id: crypto.randomUUID()}]
    ]) {
      const result = await rawConversationPushResult(page, event, payload)
      assert.notEqual(result.kind, "ok", `${event} regained terminal authority: ${JSON.stringify(result)}`)
    }

    const freshJoin = await rawConversationJoinResult(pageB, conversationId, epochId, 0)
    assert.notEqual(freshJoin.kind, "ok")
    await Promise.all([assertNoCanonicalConversation(pageA), assertNoCanonicalConversation(pageB)])
  } finally {
    if (sibling) await sibling.close()
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})

test("disconnected peer recovers terminal End and cannot recreate runtime", {timeout: 35_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()

  try {
    const {b, conversationId, epochId} = await rawEstablish(pageA, pageB)
    await rawDisconnect(pageB)
    const ended = await rawConversationPush(pageA, "conversation:end", {})
    assert.equal(ended.status, "ended")
    assert.deepEqual(await rawWaitForEnded(pageA), {status: "ended", reason: "participant_completed"})

    await rawBootstrap(pageB, b.identity)
    await assertNoCanonicalConversation(pageB)
    const resurrect = await rawConversationJoinResult(pageB, conversationId, epochId, 0)
    assert.notEqual(resurrect.kind, "ok")
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})

test("Block wins while peer is reconnecting; Report cannot weaken or resurrect terminal truth", {timeout: 40_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()

  try {
    const {b, conversationId, epochId} = await rawEstablish(pageA, pageB)
    const report = await rawConversationPush(pageA, "conversation:report", {
      category: "SPAM",
      evidence: "Team 2 report-before-block browser proof"
    })
    assert.ok(report.status)

    await rawDisconnect(pageB)
    const blocked = await rawConversationPush(pageA, "conversation:block", {})
    assert.equal(blocked.status, "blocked")
    assert.deepEqual(await rawWaitForEnded(pageA), {status: "ended", reason: "blocked"})

    await rawBootstrap(pageB, b.identity)
    await assertNoCanonicalConversation(pageB)
    const reconnect = await rawConversationJoinResult(pageB, conversationId, epochId, 0)
    assert.notEqual(reconnect.kind, "ok")

    const reportRetry = await rawConversationPushResult(pageA, "conversation:report", {
      category: "SPAM",
      evidence: "must not resurrect"
    })
    assert.notEqual(reportRetry.kind, "ok")
    const sendRetry = await rawConversationPushResult(pageA, "message:send", {
      client_message_id: crypto.randomUUID(),
      content: "must stay dead"
    })
    assert.notEqual(sendRetry.kind, "ok")
  } finally {
    await contextA.close()
    await contextB.close()
    await browser.close()
  }
})

test("real UI Block collapses local transient authority and stale Conversation A cannot terminate new Conversation B", {timeout: 80_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const contextC = await browser.newContext()
  const a1 = await contextA.newPage()
  const b = await contextB.newPage()
  let a2 = null
  let a3 = null
  let a4 = null
  let c = null

  try {
    await uiMatch(a1, b)

    a2 = await contextA.newPage()
    a3 = await contextA.newPage()
    a4 = await contextA.newPage()
    await Promise.all([a2, a3, a4].map(async (page) => {
      await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
      await uiWaitForConversation(page)
    }))

    await b.fill("#message-input", "terminal surface seed")
    await b.press("#message-input", "Enter")
    await Promise.all([a1, a2, a3, a4].map((page) => page.waitForSelector("#messages .message:not(.mine)")))

    await a1.fill("#message-input", "draft must lose send authority")
    await a1.hover("#messages .message:not(.mine)")
    await a1.click("#messages .message:not(.mine) .reply-action-btn")
    await a1.waitForSelector("#reply-staging:not([hidden])")

    await a2.hover("#messages .message:not(.mine)")
    await a2.click("#messages .message:not(.mine) .react-action-btn")
    await a2.waitForSelector(".reaction-picker")

    await uiOpenMessageTools(a3)
    await a3.click("#expressive-open")
    await a3.waitForSelector("#expressive-picker:not([hidden])")
    await a3.click("#prompt-control")
    await a3.waitForSelector("#prompt-helper:not([hidden])")

    await uiOpenConversationInfo(a4)
    await a4.click("#report-open")
    await a4.waitForSelector("#report-form:not([hidden])")
    await a4.selectOption("#report-category", "SPAM")
    await a4.fill("#report-evidence", "report then block")
    await a4.click('#report-form button[type="submit"], #report-form .primary')
    await a4.waitForFunction(() => document.querySelector("#status")?.textContent.includes("Report submitted"), null, {timeout: 10_000})

    const secondReportState = await a4.evaluate(() => {
      const overflow = document.querySelector(".conversation-head-actions .overflow")
      const reportOpen = document.querySelector("#report-open")
      const reportForm = document.querySelector("#report-form")
      const activeScreen = document.querySelector("[data-screen].active")
      const reportStyle = reportOpen ? getComputedStyle(reportOpen) : null
      return {
        overflowOpen: overflow?.open ?? null,
        reportOpenVisible: Boolean(
          reportOpen &&
          reportOpen.getClientRects().length > 0 &&
          reportStyle?.display !== "none" &&
          reportStyle?.visibility !== "hidden"
        ),
        activeScreen: activeScreen?.dataset.screen ?? null,
        reportFormHidden: reportForm?.hidden ?? null
      }
    })
    console.log("TEAM2_SECOND_REPORT_STATE", JSON.stringify(secondReportState))
    assert.deepEqual(secondReportState, {
      overflowOpen: false,
      reportOpenVisible: false,
      activeScreen: "conversation",
      reportFormHidden: true
    })

    await uiOpenConversationInfo(a4)
    await a4.click("#report-open")
    await a4.waitForSelector("#report-form:not([hidden])")

    await uiOpenConversationInfo(a1)
    a1.once("dialog", (dialog) => dialog.accept())
    await a1.click("#block")
    await Promise.all([a1, a2, a3, a4, b].map(uiWaitForEnded))

    assert.equal(await a1.inputValue("#message-input"), "")
    assert.equal(await a1.locator("#reply-staging").isHidden(), true)
    assert.equal(await a2.locator(".reaction-picker").count(), 0)
    assert.equal(await a3.locator("#expressive-picker").isHidden(), true)
    assert.equal(await a3.locator("#prompt-helper").isHidden(), true)
    assert.equal(await a4.locator("#report-form").isHidden(), true)
    assert.equal(await a1.evaluate(() => document.activeElement?.id), "consent")

    // A now enters a completely new Conversation with C.
    await a1.click("#fade-conversation")
    await a1.waitForSelector('section[data-screen="doors"].active')
    await a1.selectOption("#conversation-language", "en")
    c = await contextC.newPage()
    await prepareUiPage(c)
    await Promise.all([uiJoinQueue(a1), uiJoinQueue(c)])
    await Promise.all([uiWaitForConversation(a1), uiWaitForConversation(c)])
    await a1.fill("#message-input", "NEW-CONVERSATION-B-DRAFT")

    // B is still subscribed to the old terminal Conversation. A duplicate Block on
    // that old topic re-broadcasts terminal authority. A's stale A-handler must ignore it.
    b.once("dialog", (dialog) => dialog.accept())
    await b.evaluate(() => document.querySelector("#block").click())
    await b.waitForTimeout(500)

    assert.equal(await a1.locator('section[data-screen="conversation"]').evaluate((node) => node.classList.contains("active")), true)
    assert.equal(await a1.inputValue("#message-input"), "NEW-CONVERSATION-B-DRAFT")
    assert.equal(await c.locator('section[data-screen="conversation"]').evaluate((node) => node.classList.contains("active")), true)
  } finally {
    if (a2) await a2.close()
    if (a3) await a3.close()
    if (a4) await a4.close()
    if (c) await c.close()
    await contextA.close()
    await contextB.close()
    await contextC.close()
    await browser.close()
  }
})