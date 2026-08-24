import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"
const GIF_PIXEL = Buffer.from("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "base64")

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_) {
    return null
  }
}

function observeExpressiveFrames(page) {
  const frames = []
  page.on("websocket", (socket) => {
    socket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message?.event === "message:send" && typeof message.body?.expressive_id === "string") frames.push(message)
    })
  })
  return frames
}

async function preparePage(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
}

async function bootFresh(browser) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  await context.route("https://media.example.test/**", (route) =>
    route.fulfill({status: 200, contentType: "image/gif", body: GIF_PIXEL})
  )
  const page = await context.newPage()
  const expressiveFrames = observeExpressiveFrames(page)
  await preparePage(page)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page, expressiveFrames}
}

async function openSibling(participant) {
  const page = await participant.context.newPage()
  const expressiveFrames = observeExpressiveFrames(page)
  await preparePage(page)
  await page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#expressive-composer:not([hidden])").waitFor({state: "visible"})
  return {page, expressiveFrames}
}

async function queue(page) {
  await page.locator('button.door:has-text("Advice")').click()
}

async function matchExistingWithFresh(browser, participant) {
  const peer = await bootFresh(browser)
  await queue(participant.page)
  await participant.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
  await queue(peer.page)
  await Promise.all([
    participant.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
    peer.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
  ])
  return peer
}

async function matchPair(browser) {
  const a = await bootFresh(browser)
  const b = await bootFresh(browser)
  await queue(a.page)
  await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
  await queue(b.page)
  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
  ])
  return {a, b}
}

async function endConversation(page) {
  await page.evaluate(() => {
    const details = document.querySelector(".conversation-head-actions details.overflow")
    if (details) details.open = true
    document.querySelector("#end-conversation")?.click()
  })
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
  await page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: 10_000})
}

async function returnToDoors(page) {
  await page.evaluate(() => document.querySelector('[data-go="doors"]')?.click())
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 10_000})
}

async function sendSticker(sender, receiver) {
  const before = await receiver.locator("#messages .expressive-message").count()
  await sender.locator("#expressive-open").click()
  await sender.locator("#expressive-picker").waitFor({state: "visible"})
  await sender.locator("#expressive-results button").first().click()
  await receiver.waitForFunction((n) => document.querySelectorAll("#messages .expressive-message").length === n + 1, before)
}

async function sendGif(sender, receiver, query) {
  const before = await receiver.locator("#messages .expressive-message").count()
  await sender.locator("#gif-open").click()
  await sender.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
  await sender.locator("#gif-search").fill(query)
  await sender.locator("#gif-results button").first().waitFor({state: "visible", timeout: 10_000})
  await sender.locator("#gif-results button").first().click()
  await receiver.waitForFunction((n) => document.querySelectorAll("#messages .expressive-message").length === n + 1, before)
}

test("Conversation A stale GIF search and sticker selection cannot leak into Conversation B", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let peerB

  try {
    pair = await matchPair(browser)
    const a = pair.a

    // Bind a sticker selection to Conversation A but do not send it yet.
    await a.page.locator("#expressive-open").click()
    await a.page.locator("#expressive-picker").waitFor({state: "visible"})

    let oldSearchResolved
    let releaseOldSearch
    const oldResolved = new Promise((resolve) => { oldSearchResolved = resolve })
    const release = new Promise((resolve) => { releaseOldSearch = resolve })

    await a.page.locator("#gif-open").click()
    await a.page.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
    await a.page.route("**/api/gifs/search?**", async (route) => {
      const url = new URL(route.request().url())
      if (url.searchParams.get("q") !== "old-cat") return route.continue()
      const response = await route.fetch()
      oldSearchResolved()
      await release
      await route.fulfill({response})
    })
    await a.page.locator("#gif-search").fill("old-cat")
    await oldResolved

    await endConversation(a.page)
    await returnToDoors(a.page)
    peerB = await matchExistingWithFresh(browser, a)

    const framesBeforeStaleSticker = a.expressiveFrames.length
    await a.page.evaluate(() => document.querySelector("#expressive-results button")?.click())
    await a.page.waitForTimeout(300)
    assert.equal(a.expressiveFrames.length, framesBeforeStaleSticker, "old Conversation A sticker never sends into B")
    assert.match(await a.page.locator("#expression-send-status").textContent(), /no longer available/i)

    releaseOldSearch()
    await a.page.waitForTimeout(500)
    assert.equal(await a.page.locator("#gif-results button", {hasText: "Fixture GIF old-cat"}).count(), 0)

    await a.page.locator("#gif-open").click()
    await a.page.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
    await a.page.locator("#gif-search").fill("new-dog")
    await a.page.locator("#gif-results button", {hasText: "Fixture GIF new-dog"}).waitFor({state: "visible", timeout: 10_000})
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await peerB?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("sibling tab stale sticker selection is blocked after primary tab ends Conversation", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let sibling

  try {
    pair = await matchPair(browser)
    sibling = await openSibling(pair.a)
    await sibling.page.locator("#expressive-open").click()
    await sibling.page.locator("#expressive-picker").waitFor({state: "visible"})

    await endConversation(pair.a.page)
    await sibling.page.waitForFunction(() => document.querySelector("#expressive-composer")?.hidden === true, null, {timeout: 10_000})

    const before = sibling.expressiveFrames.length
    await sibling.page.evaluate(() => document.querySelector("#expressive-results button")?.click())
    await sibling.page.waitForTimeout(300)
    assert.equal(sibling.expressiveFrames.length, before)
    assert.match(await sibling.page.locator("#expression-send-status").textContent(), /no longer available/i)
  } finally {
    await sibling?.page?.close().catch(() => {})
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("expressive replay plus a live expressive arrival converges without duplicates", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    await sendSticker(pair.a.page, pair.b.page)
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 1)

    const reload = pair.b.page.reload({waitUntil: "domcontentloaded"})
    await reload
    // Send while the receiver is reconciling/rejoining; the item may arrive live or via replay,
    // but canonical convergence must produce exactly two expressive messages.
    await sendGif(pair.a.page, pair.b.page, "replay-race")
    await pair.b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
    await pair.b.page.waitForFunction(() => document.querySelectorAll("#messages .expressive-message").length === 2, null, {timeout: 15_000})
    await pair.b.page.waitForTimeout(500)
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 2)
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
