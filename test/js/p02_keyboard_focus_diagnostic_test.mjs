import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"

async function openDoors(browser) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("button.door").first().waitFor({state: "visible"})
  return {context, page}
}

async function tabUntil(page, predicate, label, maxTabs = 24, argument = null) {
  for (let attempt = 0; attempt < maxTabs; attempt += 1) {
    await page.keyboard.press("Tab")
    const matched = await page.evaluate(predicate, argument)
    if (matched) return
  }
  assert.fail(`keyboard focus never reached ${label}`)
}

async function withDoors(callback) {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openDoors(browser)
    await callback(app.page)
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
}

test("P02 diagnostic: Conversation Language is keyboard reachable", {timeout: 20_000}, async () => {
  await withDoors(async page => {
    await tabUntil(page, () => document.activeElement?.id === "conversation-language", "Conversation Language", 8)
    assert.equal(await page.evaluate(() => document.activeElement?.id), "conversation-language")
  })
})

test("P02 diagnostic: Conversation Language focus indicator and target are valid", {timeout: 20_000}, async () => {
  await withDoors(async page => {
    await tabUntil(page, () => document.activeElement?.id === "conversation-language", "Conversation Language", 8)
    const indicator = await page.locator("#conversation-language").evaluate(element => {
      const style = getComputedStyle(element)
      return {style: style.outlineStyle, width: style.outlineWidth, height: style.height}
    })
    assert.notEqual(indicator.style, "none")
    assert.ok(Number.parseFloat(indicator.width) >= 3)
    assert.ok(Number.parseFloat(indicator.height) >= 44)
  })
})

test("P02 diagnostic: first Door is keyboard reachable after Conversation Language", {timeout: 20_000}, async () => {
  await withDoors(async page => {
    await tabUntil(page, () => document.activeElement?.id === "conversation-language", "Conversation Language", 8)
    await tabUntil(page, () => {
      const doors = [...document.querySelectorAll("button.door")]
      return doors.indexOf(document.activeElement) === 0
    }, "Door 1", 12)
    assert.equal(await page.evaluate(() => [...document.querySelectorAll("button.door")].indexOf(document.activeElement)), 0)
  })
})

test("P02 diagnostic: all four Doors are reachable in canonical keyboard order", {timeout: 20_000}, async () => {
  await withDoors(async page => {
    await tabUntil(page, () => document.activeElement?.id === "conversation-language", "Conversation Language", 8)
    for (let index = 0; index < 4; index += 1) {
      await tabUntil(page, expectedIndex => {
        const doors = [...document.querySelectorAll("button.door")]
        return doors.indexOf(document.activeElement) === expectedIndex
      }, `Door ${index + 1}`, 12, index)
    }
  })
})

test("P02 diagnostic: language and Door focus indicators use the same visible style", {timeout: 20_000}, async () => {
  await withDoors(async page => {
    await tabUntil(page, () => document.activeElement?.id === "conversation-language", "Conversation Language", 8)
    const language = await page.locator("#conversation-language").evaluate(element => {
      const style = getComputedStyle(element)
      return {color: style.outlineColor, style: style.outlineStyle, width: style.outlineWidth}
    })
    await tabUntil(page, () => document.activeElement?.matches("button.door") === true, "a Door", 12)
    const door = await page.locator("button.door:focus").evaluate(element => {
      const style = getComputedStyle(element)
      return {color: style.outlineColor, style: style.outlineStyle, width: style.outlineWidth}
    })
    assert.deepEqual(language, door)
  })
})
