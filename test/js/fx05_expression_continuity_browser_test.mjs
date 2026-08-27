import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_) {
    return null
  }
}

function observeConversationEndFrames(page) {
  const frames = []
  page.on("websocket", (socket) => {
    socket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message?.event === "conversation:end") frames.push(message)
    })
  })
  return frames
}

function observeConversationFrames(page) {
  const frames = []
  page.on("websocket", (socket) => {
    socket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message?.topic?.startsWith("conversation:")) frames.push(message)
    })
  })
  return frames
}

async function waitForObserved(predicate, {timeout = 10_000, message = "timed out waiting for observed state"} = {}) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const result = predicate()
    if (result) return result
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  throw new Error(message)
}

async function preparePage(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
}

async function bootFresh(browser) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  const conversationEndFrames = observeConversationEndFrames(page)
  const conversationFrames = observeConversationFrames(page)
  await preparePage(page)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page, conversationEndFrames, conversationFrames}
}

async function queue(page) {
  await page.locator('button.door:has-text("Advice")').click()
}

async function waitForExpressionSurface(page, timeout = 15_000) {
  await page.locator("#expressive-composer:not([hidden])").waitFor({state: "attached", timeout})
  await Promise.all([
    page.locator("#message-input").waitFor({state: "visible", timeout}),
    page.locator(".ig-compose-plus").waitFor({state: "attached", timeout}),
    page.locator("#emoji-open").waitFor({state: "attached", timeout}),
    page.locator("#expressive-open").waitFor({state: "attached", timeout}),
    page.locator("#gif-open").waitFor({state: "attached", timeout})
  ])
}

async function openExpressionTools(page, timeout = 10_000) {
  const plus = page.locator(".ig-compose-plus")
  await plus.waitFor({state: "visible", timeout})
  if (await plus.getAttribute("aria-expanded") !== "true") await plus.click()
  await page.locator("#message-form.ig-tray-open").waitFor({state: "attached", timeout})
  await Promise.all([
    page.locator("#emoji-open").waitFor({state: "visible", timeout}),
    page.locator("#expressive-open").waitFor({state: "visible", timeout}),
    page.locator("#gif-open").waitFor({state: "visible", timeout})
  ])
}

async function matchPair(browser) {
  const a = await bootFresh(browser)
  const b = await bootFresh(browser)
  try {
    await queue(a.page)
    await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
    await queue(b.page)
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
    ])
    await Promise.all([
      waitForExpressionSurface(a.page),
      waitForExpressionSurface(b.page)
    ])
    return {a, b}
  } catch (error) {
    await a.context.close().catch(() => {})
    await b.context.close().catch(() => {})
    throw error
  }
}

async function closePair(pair) {
  if (!pair) return
  await pair.a?.context.close().catch(() => {})
  await pair.b?.context.close().catch(() => {})
}

async function sendText(page, text) {
  await page.locator("#message-input").fill(text)
  await page.locator("#message-form").evaluate((form) => form.requestSubmit())
}

async function stageReplyToPeerMessage(sender, receiver, text = "reply-target") {
  await sendText(sender, text)
  const peerMessage = receiver.locator("#messages .message:not(.mine)", {hasText: text}).last()
  await peerMessage.waitFor({state: "visible", timeout: 10_000})
  await peerMessage.hover()
  await peerMessage.locator(".reply-action-btn").waitFor({state: "visible", timeout: 10_000})
  await peerMessage.locator(".reply-action-btn").click()
  await receiver.locator("#reply-staging").waitFor({state: "visible", timeout: 10_000})
}

async function stageEdit(page, text, attemptedEdit) {
  await sendText(page, text)
  const ownMessage = page.locator("#messages .message.mine", {hasText: text}).last()
  await ownMessage.waitFor({state: "visible", timeout: 10_000})
  await ownMessage.hover()
  await ownMessage.locator(".edit-action-btn").waitFor({state: "visible", timeout: 10_000})
  await ownMessage.locator(".edit-action-btn").click()
  const editor = ownMessage.locator(".message-edit-form textarea")
  await editor.waitFor({state: "visible", timeout: 10_000})
  await editor.fill(attemptedEdit)
  return editor
}

async function navigateAway(page, destination = "chats") {
  await page.evaluate((screen) => {
    const control = document.querySelector(`#bottom-nav [data-go="${screen}"]`)
    if (!control) throw new Error(`missing presentation control for ${screen}`)
    control.click()
  }, destination)
  await page.locator(`section[data-screen="${destination}"].active`).waitFor({state: "visible", timeout: 10_000})
}

async function showPresentation(page, destination) {
  await page.evaluate((screen) => {
    const id = `fx05-present-${screen}`
    let control = document.querySelector(`#${id}`)
    if (!control) {
      control = document.createElement("button")
      control.id = id
      control.type = "button"
      control.dataset.go = screen
      control.textContent = `Present ${screen}`
      document.body.append(control)
    }
    control.click()
  }, destination)
  await page.locator(`section[data-screen="${destination}"].active`).waitFor({state: "visible", timeout: 10_000})
}

async function returnToSameConversationPresentation(page) {
  await showPresentation(page, "conversation")
  await waitForExpressionSurface(page, 10_000)
}

async function endConversation(page) {
  await page.evaluate(() => {
    const details = document.querySelector(".conversation-head-actions details.overflow")
    if (details) details.open = true
    document.querySelector("#end-conversation")?.click()
  })
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
}

test("HARNESS-01/02/03 single pair establishes, closes, and a second pair establishes", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let first
  let second
  try {
    first = await matchPair(browser)
    assert.equal(await first.a.page.locator('section[data-screen="conversation"].active').isVisible(), true)
    assert.equal(await first.b.page.locator('section[data-screen="conversation"].active').isVisible(), true)

    await closePair(first)
    first = null
    assert.equal(browser.contexts().length, 0, "closing the pair must release both browser contexts")

    second = await matchPair(browser)
    assert.equal(await second.a.page.locator('section[data-screen="conversation"].active').isVisible(), true)
    assert.equal(await second.b.page.locator('section[data-screen="conversation"].active').isVisible(), true)
  } finally {
    await closePair(first)
    await closePair(second)
    await browser.close().catch(() => {})
  }
})

test("X05-01 text draft survives presentation-away and same-Conversation return", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await pair.a.page.locator("#message-input").fill("draft survives away and return")

    await navigateAway(pair.a.page, "chats")
    assert.equal(await pair.a.page.locator("#message-input").inputValue(), "draft survives away and return")

    await returnToSameConversationPresentation(pair.a.page)
    assert.equal(await pair.a.page.locator("#message-input").inputValue(), "draft survives away and return")
    assert.equal(pair.a.conversationEndFrames.length, 0, "navigation must not emit Conversation End")
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-02 valid reply target survives presentation-away and same-Conversation return", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await stageReplyToPeerMessage(pair.b.page, pair.a.page, "reply-target-x05")

    await navigateAway(pair.a.page, "chats")
    await returnToSameConversationPresentation(pair.a.page)

    assert.equal(await pair.a.page.locator("#reply-staging").isHidden(), false, "valid reply target must remain staged")
    assert.equal(pair.a.conversationEndFrames.length, 0, "navigation must not emit Conversation End")
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-03 picker UI resets safely while Expression authority survives same-Conversation hide/return", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await openExpressionTools(pair.a.page)
    await pair.a.page.locator("#emoji-open").click()
    await pair.a.page.locator("#emoji-composer-picker").waitFor({state: "visible", timeout: 10_000})

    await navigateAway(pair.a.page, "chats")
    assert.equal(await pair.a.page.locator("#emoji-composer-picker").isHidden(), true, "picker presentation may reset while hidden")

    await returnToSameConversationPresentation(pair.a.page)
    await openExpressionTools(pair.a.page)
    await pair.a.page.locator("#emoji-open").click()
    await pair.a.page.locator("#emoji-composer-picker").waitFor({state: "visible", timeout: 10_000})
    assert.equal(pair.a.conversationEndFrames.length, 0)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-04 rapid away/back does not destroy same-Conversation expression continuity", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await pair.a.page.locator("#message-input").fill("rapid continuity")

    for (let i = 0; i < 5; i++) {
      await navigateAway(pair.a.page, i % 2 === 0 ? "chats" : "settings")
      await returnToSameConversationPresentation(pair.a.page)
    }

    assert.equal(await pair.a.page.locator("#message-input").inputValue(), "rapid continuity")
    await pair.a.page.locator("#message-input").fill("")
    await openExpressionTools(pair.a.page)
    await pair.a.page.locator("#emoji-open").click()
    await pair.a.page.locator("#emoji-composer-picker").waitFor({state: "visible", timeout: 10_000})
    assert.equal(pair.a.conversationEndFrames.length, 0)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-05 terminalization while away clears valid A composition instead of resurrecting it", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await stageReplyToPeerMessage(pair.b.page, pair.a.page, "terminal-reply-target")
    await pair.a.page.locator("#message-input").fill("must not resurrect after terminal")
    await navigateAway(pair.a.page, "chats")

    await endConversation(pair.b.page)
    await pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: 15_000})

    assert.equal(await pair.a.page.locator("#message-input").inputValue(), "")
    assert.equal(await pair.a.page.locator("#reply-staging").isHidden(), true)
    assert.equal(await pair.a.page.locator("#expressive-composer").isHidden(), true)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-06 edit staging survives presentation-away and same-Conversation return", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const editor = await stageEdit(pair.a.page, "edit-source-x05", "attempted edit survives away")

    await navigateAway(pair.a.page, "chats")
    assert.equal(await editor.inputValue(), "attempted edit survives away")

    await returnToSameConversationPresentation(pair.a.page)
    await editor.waitFor({state: "visible", timeout: 10_000})
    assert.equal(await editor.inputValue(), "attempted edit survives away")
    assert.equal(pair.a.conversationEndFrames.length, 0, "navigation must not emit Conversation End")
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-07 sticker authority survives presentation-away and same-Conversation return", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    await navigateAway(pair.a.page, "chats")
    await returnToSameConversationPresentation(pair.a.page)
    await openExpressionTools(pair.a.page)
    await pair.a.page.locator("#expressive-open").click()
    const sticker = pair.a.page.locator("#expressive-results button").first()
    await sticker.waitFor({state: "visible", timeout: 10_000})
    await sticker.click()

    const expressiveSend = await waitForObserved(
      () => pair.a.conversationFrames.find((frame) => frame.event === "message:send" && typeof frame.body?.expressive_id === "string"),
      {message: "same-Conversation sticker selection was blocked after presentation return"}
    )
    assert.match(expressiveSend.topic, /^conversation:/)
    assert.equal(pair.a.conversationEndFrames.length, 0)
  } finally {
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})

test("X05-08 delayed A GIF callback cannot mutate B after accepted Conversation transition", {timeout: 150_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let nextPeer
  let firstStatusRoute = null
  let statusRequests = 0
  try {
    pair = await matchPair(browser)
    await pair.a.page.route("**/api/gifs/status", async (route) => {
      statusRequests += 1
      if (statusRequests === 1) {
        firstStatusRoute = route
        return
      }
      await route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({available: true})})
    })

    await openExpressionTools(pair.a.page)
    await pair.a.page.locator("#gif-open").click()
    await waitForObserved(() => firstStatusRoute, {message: "A GIF status request was not captured"})

    await endConversation(pair.b.page)
    await pair.a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: 15_000})

    await showPresentation(pair.a.page, "doors")
    await pair.a.page.locator("#conversation-language").selectOption("en")
    nextPeer = await bootFresh(browser)
    await queue(pair.a.page)
    await pair.a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
    await queue(nextPeer.page)
    await Promise.all([
      pair.a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
      nextPeer.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
    ])
    await Promise.all([
      waitForExpressionSurface(pair.a.page),
      waitForExpressionSurface(nextPeer.page)
    ])

    const beforeStatus = await pair.a.page.locator("#gif-status").textContent()
    const beforeDisabled = await pair.a.page.locator("#gif-search").isDisabled()
    assert.equal(beforeDisabled, true, "B must not inherit an enabled GIF search from A")

    await firstStatusRoute.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({available: true})})
    await pair.a.page.waitForTimeout(250)

    assert.equal(await pair.a.page.locator("#gif-status").textContent(), beforeStatus, "stale A callback must not rewrite B status")
    assert.equal(await pair.a.page.locator("#gif-search").isDisabled(), true, "stale A callback must not enable B search")

    await openExpressionTools(pair.a.page)
    await pair.a.page.locator("#gif-open").click()
    await pair.a.page.locator("#gif-search").waitFor({state: "visible", timeout: 10_000})
    await waitForObserved(() => statusRequests >= 2, {message: "B did not request fresh GIF authority"})
    await pair.a.page.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
    assert.equal(await pair.a.page.locator("#gif-status").textContent(), "Search for a GIF.")
  } finally {
    await nextPeer?.context.close().catch(() => {})
    await closePair(pair)
    await browser.close().catch(() => {})
  }
})
