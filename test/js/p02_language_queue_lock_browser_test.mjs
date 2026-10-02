import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

test("Four Doors has no language prerequisite and Hangouts language control remains separate", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root page loads")
    await page.locator("body:not(.flow-booting)").waitFor({state: "attached", timeout: 15_000})
    await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})

    assert.equal(await page.locator("#conversation-language").count(), 0)
    assert.equal(await page.locator("#hangout-language").count(), 1)

    await page.getByRole("button", {name: /Advice/}).click()
    await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 15_000})
    await page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 15_000})
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
