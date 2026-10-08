import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

async function openReady(browser, options = {}) {
  const context = await browser.newContext({
    viewport: {width: 390, height: 844},
    ...options
  })
  const page = await context.newPage()
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()) })
  const responses = []
  const sockets = []
  page.on("response", response => {
    const pathname = new URL(response.url()).pathname
    if (pathname === "/api/participants" || pathname === "/api/account/session") {
      responses.push({path: pathname, status: response.status()})
    }
  })
  page.on("websocket", socket => {
    const state = {path: new URL(socket.url()).pathname, joins: []}
    sockets.push(state)
    socket.on("framesent", ({payload}) => {
      try { const frame = JSON.parse(payload); if (frame[3] === "phx_join") state.joins.push({topic: String(frame[2]).split(":")[0]}) }
      catch (_ignored) {}
    })
    socket.on("framereceived", ({payload}) => {
      try { const frame = JSON.parse(payload); if (frame[3] === "phx_reply" && frame[4]?.response?.status) state.joinStatus = frame[4].response.status }
      catch (_ignored) {}
    })
  })
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok())
  try {
    await page.locator("button.door").first().waitFor({state: "visible"})
  } catch (error) {
    const state = await page.evaluate(() => ({
      booting: document.body.classList.contains("flow-booting"),
      bridgeState: document.querySelector("#boot-bridge")?.dataset.state || null,
      bridgeVisible: Boolean(document.querySelector("#boot-bridge")?.getClientRects().length),
      activeScreen: document.querySelector("section.screen.active")?.dataset.screen || null,
      doorsVisible: [...document.querySelectorAll("button.door")].filter(node => Boolean(node.getClientRects().length) && getComputedStyle(node).visibility === "visible").length
    })).catch(() => ({unavailable: true}))
    console.error("TEAM3E_STARTUP_DIAGNOSTICS=" + JSON.stringify({httpRoot: response.status(), responses, sockets, state, error: error.name}))
    throw error
  }
  return {context, page, errors}
}

async function waitQueued(page) {
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 12_000})
  await page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 12_000})
}

test("keyboard activation reaches queue and focus follows the state change", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openReady(browser)
    const door = session.page.getByRole("button", {name: /Vent/})
    await door.focus()
    assert.equal(await session.page.evaluate(() => document.activeElement?.dataset?.door), "JUST_TALK")
    await session.page.keyboard.press("Enter")
    await waitQueued(session.page)
    await session.page.waitForFunction(() => document.activeElement === document.querySelector('section[data-screen="queue"] h1'))

    const leave = session.page.locator("#leave-queue")
    await leave.focus()
    await session.page.keyboard.press("Enter")
    await session.page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 12_000})
    await session.page.waitForFunction(() => document.activeElement === document.querySelector('section[data-screen="doors"] h1'))
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("rapid repeated Door activation emits one queue join", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  const errors = []
  let queueJoinFrames = 0

  try {
    page.on("pageerror", error => errors.push(error.message))
    page.on("console", message => { if (message.type() === "error") errors.push(message.text()) })
    page.on("websocket", websocket => {
      websocket.on("framesent", ({payload}) => {
        if (typeof payload === "string" && payload.includes('"queue:join"')) queueJoinFrames += 1
      })
    })

    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok())
    await page.locator("button.door").first().waitFor({state: "visible"})

    const door = page.getByRole("button", {name: /Advice/})
    await door.click({clickCount: 2, delay: 10})
    await waitQueued(page)
    await page.waitForTimeout(150)
    assert.equal(queueJoinFrames, 1, "only one queue:join is emitted for repeated activation")
    assert.deepEqual(errors, [])
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("reduced-motion preference preserves the complete Arrival to Queue interaction", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openReady(browser, {reducedMotion: "reduce"})
    assert.equal(await session.page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches), true)
    await session.page.getByRole("button", {name: /Distract/}).click()
    await waitQueued(session.page)
    assert.equal(await session.page.locator("#leave-queue").isVisible(), true)
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("200 percent browser zoom keeps Arrival and queue primary controls reachable", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openReady(browser)
    const page = session.page
    const cdp = await session.context.newCDPSession(page)
    await cdp.send("Emulation.setPageScaleFactor", {pageScaleFactor: 2})

    const doorBox = await page.locator("button.door").first().boundingBox()
    assert.ok(doorBox)
    const deepTalk = page.getByRole("button", {name: /Deep Talk/})
    // CDP page-scale acts like pinch zoom. Scroll the *document* until the Door
    // is in the actual visual viewport; Playwright's default 390px-wide center
    // is otherwise outside the 195px-wide visible region at page scale 2.
    await deepTalk.evaluate(button => {
      const rect = button.getBoundingClientRect()
      const visualHeight = window.visualViewport?.height || innerHeight
      window.scrollBy({top: rect.top - visualHeight * 0.25, behavior: "instant"})
    })
    const pointer = await deepTalk.evaluate(button => {
      const bounds = button.getBoundingClientRect()
      const visual = window.visualViewport
      const left = visual?.offsetLeft || 0
      const top = visual?.offsetTop || 0
      const right = left + (visual?.width || innerWidth)
      const bottom = top + (visual?.height || innerHeight)
      // Choose a real visible and unobstructed interior point, not a forced
      // synthetic event, a higher z-index, or an invisible Door.
      const x = Math.min(bounds.left + Math.min(bounds.width * 0.25, 80), right - 16)
      const y = Math.min(bounds.top + Math.min(bounds.height * 0.3, 35), bottom - 16)
      const hit = document.elementFromPoint(x, y)
      return {
        valid: x > Math.max(bounds.left, left) + 1 &&
          y > Math.max(bounds.top, top) + 1 &&
          (hit === button || button.contains(hit)),
        x: x - bounds.left,
        y: y - bounds.top,
        visualWidth: visual?.width,
        visualHeight: visual?.height,
        hitTag: hit?.tagName || null,
        scrollY,
        top: bounds.top
      }
    })
    assert.ok(pointer.valid, "Deep Talk has a genuine reachable pointer target inside the 200% visual viewport: " + JSON.stringify(pointer))
    // Normal Playwright pointer input with actionability and hit testing ON.
    try {
      await deepTalk.click({position: {x: pointer.x, y: pointer.y}})
    } catch (error) {
      const geometry = await page.evaluate(() => {
        const rect = selector => {
          const n = document.querySelector(selector)
          if (!n) return null
          const b = n.getBoundingClientRect()
          const s = getComputedStyle(n)
          return {x: b.x, y: b.y, width: b.width, height: b.height, position: s.position, transform: s.transform, zIndex: s.zIndex, pointerEvents: s.pointerEvents, overflow: s.overflow}
        }
        const target = document.querySelector('button.door[data-door="SOMETHING_REAL"]')
        const box = target?.getBoundingClientRect()
        const cx = box ? box.x + box.width / 2 : 0
        const cy = box ? box.y + box.height / 2 : 0
        const hit = document.elementFromPoint(cx, cy)
        return {
          viewport: {width: innerWidth, height: innerHeight, visualWidth: visualViewport?.width, visualHeight: visualViewport?.height, scale: visualViewport?.scale, scrollX, scrollY},
          door: rect('button.door[data-door="SOMETHING_REAL"]'),
          heading: rect('section[data-screen="doors"] h1'),
          hangouts: rect("#hangout-entry-banner"),
          main: rect("#main"),
          elementAtDoorCenter: {tag: hit?.tagName, id: hit?.id || null, classes: String(hit?.className || "").slice(0, 100)}
        }
      }).catch(() => ({unavailable: true}))
      console.error("TEAM3E_PAGE_SCALE_POINTER=" + JSON.stringify({geometry, error: error.name}))
      throw error
    }
    await waitQueued(page)
    const leaveBox = await page.locator("#leave-queue").boundingBox()
    assert.ok(leaveBox)
    assert.ok(leaveBox.y < 844, "queue exit remains reachable at 200% page scale")
    // Keyboard access remains possible even in the magnified visual viewport.
    const leave = page.locator("#leave-queue")
    await leave.focus()
    await page.keyboard.press("Enter")
    await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 12_000})
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
