import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {chromium} from "playwright"
import "./team10_expression_browser_test.mjs"
import "./team10_expression_actions_browser_test.mjs"
import "./team10_expression_reliability_browser_test.mjs"
import "./team10_expression_authority_browser_test.mjs"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"
const SCREENSHOT_DIR = "tmp/chat-ui-screenshots"
fs.mkdirSync(SCREENSHOT_DIR, {recursive: true})

test("Conversation report form remains cancellable in short landscape", async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({
    viewport: {width: 844, height: 390},
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2
  })
  const page = await context.newPage()

  try {
    await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
    await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
    await page.waitForTimeout(1000)
    await page.waitForFunction(() => document.querySelector('[data-screen="doors"]')?.classList.contains("active"))

    await page.evaluate(() => {
      document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
      document.querySelector('[data-screen="conversation"]').classList.add("active")
    })
    await page.waitForFunction(() => document.body.classList.contains("st-chat-mode"))

    assert.equal(await page.locator("#report-cancel").count(), 1)
    assert.equal(await page.locator("#report-cancel").getAttribute("type"), "button")

    await page.locator(".conversation-head-actions .overflow summary").click()
    await page.locator("#report-open").click()
    await page.waitForFunction(() => document.querySelector("#report-form")?.hidden === false)

    const form = page.locator("#report-form")
    const cancel = page.locator("#report-cancel")
    assert.equal(await form.evaluate((node) => ["auto", "scroll"].includes(getComputedStyle(node).overflowY)), true)

    await cancel.scrollIntoViewIfNeeded()
    const geometry = await cancel.evaluate((node) => {
      const rect = node.getBoundingClientRect()
      return {top: rect.top, bottom: rect.bottom, height: rect.height}
    })
    assert.ok(geometry.top >= -1, `report cancel starts above viewport: ${geometry.top}`)
    assert.ok(geometry.bottom <= 391, `report cancel ends below viewport: ${geometry.bottom}`)
    assert.ok(geometry.height >= 40, `report cancel target is only ${geometry.height}px high`)

    await page.screenshot({
      path: `${SCREENSHOT_DIR}/landscape-report-cancel.png`,
      fullPage: false
    })

    await cancel.click()
    await page.waitForFunction(() => document.querySelector("#report-form")?.hidden === true)
  } finally {
    await context.close()
    await browser.close()
  }
})
