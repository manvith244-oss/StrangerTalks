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
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok())
  await page.locator("button.door").first().waitFor({state: "visible"})
  await page.locator("#conversation-language").selectOption("en")
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

test("rapid repeated Door activation creates only one visible queue transition", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openReady(browser)
    const page = session.page
    let queueJoinFrames = 0
    page.on("websocket", websocket => {
      websocket.on("framesent", ({payload}) => {
        if (typeof payload === "string" && payload.includes('"queue:join"')) queueJoinFrames += 1
      })
    })

    const door = page.getByRole("button", {name: /Advice/})
    await Promise.all([
      door.click({clickCount: 2, delay: 10}).catch(() => {}),
      page.waitForTimeout(50)
    ])
    await waitQueued(page)
    await page.waitForTimeout(150)
    assert.equal(queueJoinFrames, 1, "only one queue:join is emitted for repeated activation")
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
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

    const languageBox = await page.locator("#conversation-language").boundingBox()
    assert.ok(languageBox)
    await page.getByRole("button", {name: /Deep Talk/}).click()
    await waitQueued(page)
    const leaveBox = await page.locator("#leave-queue").boundingBox()
    assert.ok(leaveBox)
    assert.ok(leaveBox.y < 844, "queue exit remains reachable at 200% page scale")
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
