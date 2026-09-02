import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"
const WAIT_MS = 18_000

function phoenixMessage(payload) {
  if (typeof payload !== "string") return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(payload)
    return {joinRef, ref, topic, event, body}
  } catch (_) {
    return null
  }
}

function waitUntil(predicate, label, timeout = WAIT_MS) {
  const started = Date.now()
  return new Promise((resolve, reject) => {
    const tick = () => {
      const result = predicate()
      if (result) return resolve(result)
      if (Date.now() - started >= timeout) return reject(new Error(`Timed out waiting for ${label}`))
      setTimeout(tick, 50)
    }
    tick()
  })
}

async function bootFresh(browser, {controlledSocket = false} = {}) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const control = {
    expressiveFrames: [],
    routes: new Set(),
    dropReplyRef: null,
    armDropFirstExpressiveReply: false,
    suppressServerAfterFirstExpressive: false,
    suppressed: 0
  }

  if (controlledSocket) {
    await context.routeWebSocket(/\/socket\/websocket/, (route) => {
      const server = route.connectToServer()
      const pair = {page: route, server}
      control.routes.add(pair)

      server.onMessage((payload) => {
        const message = phoenixMessage(payload)
        if (control.dropReplyRef && message?.event === "phx_reply" && message.ref === control.dropReplyRef) {
          control.dropReplyRef = null
          control.suppressed += 1
          return
        }
        if (control.suppressServerAfterFirstExpressive && control.expressiveFrames.length >= 1) {
          control.suppressed += 1
          return
        }
        route.send(payload)
      })
    })
  }

  const page = await context.newPage()
  page.on("websocket", (socket) => {
    socket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message?.event !== "message:send" || typeof message.body?.expressive_id !== "string") return
      control.expressiveFrames.push(message)
      if (control.armDropFirstExpressiveReply && control.expressiveFrames.length === 1) {
        control.dropReplyRef = message.ref
        control.armDropFirstExpressiveReply = false
      }
    })
  })

  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")

  control.disconnect = async () => {
    const pairs = [...control.routes]
    control.routes.clear()
    await Promise.all(pairs.flatMap(({page: pageRoute, server}) => [
      pageRoute.close({code: 1001, reason: "Team 10 reconnect proof"}).catch(() => {}),
      server.close({code: 1001, reason: "Team 10 reconnect proof"}).catch(() => {})
    ]))
  }

  return {context, page, control}
}

async function matchPair(browser, {controlledA = false} = {}) {
  const a = await bootFresh(browser, {controlledSocket: controlledA})
  const b = await bootFresh(browser)
  const door = 'button.door:has-text("Advice")'
  await a.page.locator(door).click()
  await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
  await b.page.locator(door).click()
  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
  ])
  return {a, b}
}

async function clickFirstSticker(page) {
  await page.locator("#expressive-open").click()
  await page.locator("#expressive-picker").waitFor({state: "visible"})
  await page.locator("#expressive-results button").first().click()
}

function assertSameIdentity(first, second) {
  assert.equal(second.body.client_message_id, first.body.client_message_id)
  assert.equal(second.body.message_id, first.body.message_id)
  assert.equal(second.body.expressive_id, first.body.expressive_id)
}

test("sticker timeout retries once with the same message identity and peer sees one item", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {controlledA: true})
    pair.a.control.armDropFirstExpressiveReply = true

    await clickFirstSticker(pair.a.page)
    await pair.b.page.locator("#messages .expressive-message").waitFor({state: "visible", timeout: 10_000})
    const frames = await waitUntil(() => pair.a.control.expressiveFrames.length >= 2 && pair.a.control.expressiveFrames, "same-id timeout retry")
    assertSameIdentity(frames[0], frames[1])
    assert.ok(pair.a.control.suppressed >= 1, "first acknowledgement was actually suppressed")
    await pair.a.page.waitForTimeout(300)
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 1)
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("sticker reconnect retries ambiguous local send with the same identity and no peer duplicate", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {controlledA: true})
    pair.a.control.suppressServerAfterFirstExpressive = true

    await clickFirstSticker(pair.a.page)
    const first = await waitUntil(() => pair.a.control.expressiveFrames[0], "first expressive send")
    await pair.b.page.locator("#messages .expressive-message").waitFor({state: "visible", timeout: 10_000})
    await pair.a.control.disconnect()
    pair.a.control.suppressServerAfterFirstExpressive = false

    await pair.a.page.waitForFunction(() => document.querySelector('[data-screen="conversation"]')?.classList.contains("active"), null, {timeout: 15_000})
    const frames = await waitUntil(() => pair.a.control.expressiveFrames.length >= 2 && pair.a.control.expressiveFrames, "reconnect expressive retry")
    assertSameIdentity(first, frames[1])
    await pair.a.page.waitForTimeout(500)
    assert.equal(await pair.b.page.locator("#messages .expressive-message").count(), 1)
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
