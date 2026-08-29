import "./door_mapping_test.mjs"
import "./door_click_flow_test.mjs"
import "./arrival_first_minute_browser_test.mjs"
import "./arrival_accessibility_browser_test.mjs"
import "./f09_mobile_flow_test.mjs"
import "./team6_product_ux_browser_test.mjs"
import "./team6_real_ux_browser_test.mjs"
import "./f10_desktop_flow_browser_test.mjs"
import "./doors_visual_structure_browser_test.mjs"
import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = "http://localhost:4000"

async function openApp(browser) {
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const page = await context.newPage()
  const pageErrors = []
  const consoleErrors = []
  page.on("pageerror", error => pageErrors.push(error.message))
  page.on("console", message => { if (message.type() === "error") consoleErrors.push(message.text()) })
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator("#bottom-nav").waitFor({state: "visible"})
  return {context, page, pageErrors, consoleErrors}
}

async function openYou(page) {
  await page.locator('#bottom-nav [data-go="settings"]').click()
  await page.locator('section[data-screen="settings"].active').waitFor({state: "visible"})
}

test("F-06 You → Private Reflections → You is a coherent secondary-screen journey", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openApp(browser)
    await openYou(app.page)

    const reflectionsEntry = app.page.getByRole("button", {name: "Open Private Reflections"})
    await reflectionsEntry.waitFor({state: "visible"})
    await reflectionsEntry.click()
    await app.page.locator('section[data-screen="reflections"].active').waitFor({state: "visible"})

    await app.page.getByRole("button", {name: "← Back to You"}).click()
    await app.page.locator('section[data-screen="settings"].active').waitFor({state: "visible"})

    assert.deepEqual(app.pageErrors, [])
    assert.deepEqual(app.consoleErrors, [])
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F-06 rapid Reduce motion changes persist newest intent across refresh", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openApp(browser)
    await openYou(app.page)
    const toggle = app.page.locator("#reduced-motion")

    await toggle.check()
    await toggle.uncheck()
    await toggle.check()
    await app.page.getByRole("status").filter({hasText: "Reduce motion is on."}).waitFor({state: "attached"})

    await app.page.reload({waitUntil: "domcontentloaded"})
    await openYou(app.page)
    assert.equal(await app.page.locator("#reduced-motion").isChecked(), true)
    assert.equal(await app.page.locator("body").evaluate(body => body.classList.contains("reduce-motion")), true)

    assert.deepEqual(app.pageErrors, [])
    assert.deepEqual(app.consoleErrors, [])
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F-06 failed Reduce motion save restores persisted canonical value", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openApp(browser)
    await openYou(app.page)
    const toggle = app.page.locator("#reduced-motion")
    if (await toggle.isChecked()) {
      await toggle.uncheck()
      await app.page.getByRole("status").filter({hasText: "Reduce motion is off."}).waitFor({state: "attached"})
    }

    await app.page.evaluate(() => {
      const originalPut = IDBObjectStore.prototype.put
      let failNextPrivacyWrite = true
      IDBObjectStore.prototype.put = function(value, ...args) {
        if (failNextPrivacyWrite && value?.id === "settings:privacy") {
          failNextPrivacyWrite = false
          const request = {
            error: new DOMException("forced F-06 write failure", "QuotaExceededError"),
            onsuccess: null,
            onerror: null
          }
          queueMicrotask(() => request.onerror?.())
          return request
        }
        return originalPut.call(this, value, ...args)
      }
    })

    await toggle.check()
    await app.page.getByRole("status").filter({hasText: "Reduce motion wasn't saved. Restored your saved preference."}).waitFor({state: "attached"})
    assert.equal(await toggle.isChecked(), false, "failed optimistic value rolls back")
    assert.equal(await app.page.locator("body").evaluate(body => body.classList.contains("reduce-motion")), false)
    assert.equal(await toggle.getAttribute("aria-invalid"), null, "canonical rollback is not left marked unconfirmed")

    assert.deepEqual(app.pageErrors, [])
    assert.deepEqual(app.consoleErrors, [])
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
