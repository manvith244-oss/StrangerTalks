import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = "http://localhost:4000"
const MATRIX = [
  [320, 568],
  [360, 740],
  [390, 844],
  [412, 915],
  [844, 390],
  [820, 1180],
  [1440, 900]
]

async function activateScreen(page, name) {
  await page.evaluate((screen) => {
    document.querySelectorAll("[data-screen]").forEach((node) => node.classList.toggle("active", node.dataset.screen === screen))
  }, name)
  await page.locator(`section[data-screen="${name}"].active`).waitFor({state: "visible"})
}

async function assertNoHorizontalOverflow(page, label) {
  const dimensions = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    scrollWidth: document.documentElement.scrollWidth
  }))
  assert.ok(dimensions.scrollWidth <= dimensions.innerWidth + 1, `${label} has no horizontal page overflow`)
}

async function assertControlInsideViewport(page, selector, label) {
  const control = page.locator(selector)
  await control.waitFor({state: "visible"})
  const box = await control.boundingBox()
  assert.ok(box, `${label} has a box`)
  assert.ok(box.x >= -1, `${label} starts inside viewport`)
  assert.ok(box.x + box.width <= (await page.evaluate(() => innerWidth)) + 1, `${label} ends inside viewport`)
  assert.ok(box.height >= 40, `${label} preserves a touch-safe height`)
}

async function boot(page) {
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.waitForFunction(() => document.querySelectorAll("#doors .door").length > 0)
}

test("Team 7 continuity surfaces survive the complete device matrix and accessibility modes", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    await boot(page)
    await page.emulateMedia({reducedMotion: "reduce", forcedColors: "active"})

    for (const [width, height] of MATRIX) {
      await page.setViewportSize({width, height})

      await activateScreen(page, "ended")
      assert.equal((await page.locator('section[data-screen="ended"] legend').textContent()).trim(), "What should happen to this Conversation?")
      await assertControlInsideViewport(page, "#keep-conversation", `${width}x${height} Keep`)
      await assertControlInsideViewport(page, "#summary-choice-form button", `${width}x${height} Summary-only`)
      await assertControlInsideViewport(page, "#fade-conversation", `${width}x${height} Fade`)
      await page.locator("#keep-conversation").focus()
      assert.equal(await page.locator("#keep-conversation").evaluate((node) => node === document.activeElement), true)
      await assertNoHorizontalOverflow(page, `${width}x${height} retention`)

      await activateScreen(page, "chats")
      assert.match(await page.locator('section[data-screen="chats"]').textContent(), /Kept on this device/)
      await assertControlInsideViewport(page, "#delete-kept-all", `${width}x${height} delete kept history`)
      await assertNoHorizontalOverflow(page, `${width}x${height} Chats`)

      await activateScreen(page, "history")
      assert.match(await page.locator('section[data-screen="history"]').textContent(), /Local copy/)
      assert.match(await page.locator('section[data-screen="history"]').textContent(), /not an active Conversation/i)
      assert.equal(await page.locator('section[data-screen="history"] #message-form').count(), 0)
      assert.equal(await page.locator('section[data-screen="history"] #typing').count(), 0)
      assert.equal(await page.locator('section[data-screen="history"] #presence').count(), 0)
      await assertControlInsideViewport(page, "#history-memory", `${width}x${height} create Memory`)
      await assertControlInsideViewport(page, "#history-delete", `${width}x${height} delete kept Conversation`)
      await assertNoHorizontalOverflow(page, `${width}x${height} history`)

      await activateScreen(page, "memories")
      assert.match(await page.locator('section[data-screen="memories"]').textContent(), /saved notes and summaries stay in this browser/i)
      await assertControlInsideViewport(page, "#memory-form button", `${width}x${height} save Memory`)
      await assertNoHorizontalOverflow(page, `${width}x${height} Memory`)

      await activateScreen(page, "relationships")
      assert.match(await page.locator('section[data-screen="relationships"]').textContent(), /Private mutual connections/)
      assert.doesNotMatch((await page.locator('section[data-screen="relationships"]').textContent()).toLowerCase(), /followers|following|popularity|best friends|people you may know|streak/)
      await assertNoHorizontalOverflow(page, `${width}x${height} Bonds`)

      await activateScreen(page, "settings")
      const settingsText = await page.locator('section[data-screen="settings"]').textContent()
      assert.match(settingsText, /You & privacy/)
      assert.match(settingsText, /Guest StrangerTalks remains fully available|Continue across devices/)
      await assertControlInsideViewport(page, "#export-data", `${width}x${height} encrypted export`)
      await assertControlInsideViewport(page, "#delete-all", `${width}x${height} delete all local data`)
      await assertNoHorizontalOverflow(page, `${width}x${height} You`)

      console.log(`TEAM7_DEVICE_PASS ${width}x${height}`)
    }

    await page.setViewportSize({width: 1440, height: 900})
    await activateScreen(page, "settings")
    await page.evaluate(() => { document.documentElement.style.zoom = "2" })
    await assertControlInsideViewport(page, "#export-data", "200% zoom export")
    await assertControlInsideViewport(page, "#delete-all", "200% zoom delete all")
    await assertNoHorizontalOverflow(page, "200% zoom settings")
    console.log("TEAM7_DEVICE_PASS 200%-zoom")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
