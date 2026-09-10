import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

test("Conversation Language is available only while the Four Doors screen owns selection", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root page loads")

    await page.locator("body:not(.flow-booting)").waitFor({state: "attached", timeout: 15_000})
    await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})

    const language = page.locator("#conversation-language")
    const control = page.locator("#conversation-language-control")
    const doors = page.locator('section[data-screen="doors"]')

    assert.equal(await language.isDisabled(), false, "language is editable while Doors owns selection")
    assert.equal(await control.getAttribute("data-language-selection-available"), "true")

    await language.selectOption("en")

    await doors.evaluate(element => {
      element.classList.remove("active")
      element.hidden = true
    })

    await page.waitForFunction(() => document.querySelector("#conversation-language")?.disabled === true)
    assert.equal(await language.isDisabled(), true, "language locks as soon as Doors no longer owns selection")
    assert.equal(await control.getAttribute("data-language-selection-available"), "false")
    assert.equal(await language.inputValue(), "en", "locking never mutates the already selected language")

    await doors.evaluate(element => {
      element.hidden = false
      element.classList.add("active")
    })

    await page.waitForFunction(() => document.querySelector("#conversation-language")?.disabled === false)
    assert.equal(await language.isDisabled(), false, "language becomes editable again when a fresh Doors state returns")
    assert.equal(await control.getAttribute("data-language-selection-available"), "true")
    assert.equal(await language.inputValue(), "en", "returning to Doors preserves the selected value")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
