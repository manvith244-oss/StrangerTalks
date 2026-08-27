import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT_MS = 12_000

async function boot(browser, path = "/") {
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  const page = await context.newPage()
  const response = await page.goto(`${BASE_URL}${path}`, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), `${path} loads`)
  await page.locator("#bottom-nav").waitFor({state: "attached", timeout: WAIT_MS})
  await page.waitForFunction(() => document.querySelectorAll("#doors button.door").length > 0, null, {timeout: WAIT_MS})
  return {context, page}
}

function activeScreen(page, screen) {
  return page.locator(`section[data-screen="${screen}"].active`)
}

async function clickPrimary(page, label) {
  await page.locator(`#bottom-nav button:has-text("${label}")`).click()
}

test("F03 browser J01/J02: primary navigation writes canonical URLs and Back/Forward preserves order", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let context
  try {
    const booted = await boot(browser)
    context = booted.context
    const page = booted.page

    await clickPrimary(page, "Chats")
    await activeScreen(page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")

    await clickPrimary(page, "Bonds")
    await activeScreen(page, "relationships").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/bonds")

    await clickPrimary(page, "You")
    await activeScreen(page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "relationships").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/bonds")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "chats").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/chats")

    await page.goForward({waitUntil: "domcontentloaded"})
    await activeScreen(page, "relationships").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/bonds")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser J12/J13: direct canonical entry presents route and secondary Back uses canonical parent", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let context
  try {
    const booted = await boot(browser, "/you/memories")
    context = booted.context
    const page = booted.page

    await activeScreen(page, "memories").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you/memories")

    await page.goBack({waitUntil: "domcontentloaded"})
    await activeScreen(page, "settings").waitFor({state: "visible"})
    assert.equal(new URL(page.url()).pathname, "/you")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("F03 browser active primary destination is route-derived via aria-current", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let context
  try {
    const booted = await boot(browser, "/you/reflections")
    context = booted.context
    const page = booted.page

    await activeScreen(page, "reflections").waitFor({state: "visible"})
    const selected = page.locator('#bottom-nav button[aria-current="page"]')
    assert.equal(await selected.count(), 1)
    assert.equal((await selected.textContent()).trim(), "You")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
