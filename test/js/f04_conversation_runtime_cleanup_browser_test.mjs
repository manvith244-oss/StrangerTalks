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
window.__f04ConversationChannels = {created: 0, left: 0, active: 0, topics: []}
const __f04OriginalChannel = __F04Socket.prototype.channel
__F04Socket.prototype.channel = function(topic, params) {
  const channel = __f04OriginalChannel.call(this, topic, params)
  if (typeof topic === "string" && topic.startsWith("conversation:")) {
    const metrics = window.__f04ConversationChannels
    metrics.created += 1
    metrics.active += 1
    metrics.topics.push(topic)
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

async function channelMetrics(page) {
  return page.evaluate(() => window.__f04ConversationChannels)
}

test("F04 terminal retention releases Conversation A runtime before Conversation B", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const a = await boot(browser, {instrument: true})
  const b = await boot(browser)
  let c = null

  try {
    await matchPair(a.page, b.page)

    const initial = await channelMetrics(a.page)
    assert.equal(initial.created, 1, "initial match creates one Conversation channel")
    assert.equal(initial.active, 1, "initial Conversation has one active client channel")

    await endConversation(a.page)
    await Promise.all([
      a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT}),
      b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT})
    ])

    await a.page.locator("#fade-conversation").click()
    await a.page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})

    const afterRetention = await channelMetrics(a.page)
    assert.equal(afterRetention.left, 1, "leaving terminal retention releases Conversation A channel")
    assert.equal(afterRetention.active, 0, "no terminal Conversation channel remains active after retention")

    c = await boot(browser)
    await matchPair(a.page, c.page)

    const afterReplacement = await channelMetrics(a.page)
    assert.equal(afterReplacement.created, 2, "Conversation B creates exactly one new channel")
    assert.equal(afterReplacement.active, 1, "Conversation A cannot remain subscribed beside Conversation B")
    assert.equal(new Set(afterReplacement.topics).size, 2, "replacement uses a distinct Conversation identity")
  } finally {
    await Promise.all([a, b, c].filter(Boolean).map(({context}) => context.close().catch(() => {})))
    await browser.close().catch(() => {})
  }
})
