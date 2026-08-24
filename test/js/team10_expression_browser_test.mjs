import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"
const SCREENSHOT_DIR = "tmp/chat-ui-screenshots"
const GIF_PIXEL = Buffer.from("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "base64")
fs.mkdirSync(SCREENSHOT_DIR, {recursive: true})

async function bootFresh(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  await context.route("https://media.example.test/**", (route) => route.fulfill({status: 200, contentType: "image/gif", body: GIF_PIXEL}))
  const page = await context.newPage()
  const loads = {runtime: 0, app: 0}
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.pathname === "/assets/expression_runtime.mjs") loads.runtime += 1
    if (url.pathname === "/assets/app.js") loads.app += 1
  })
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page, loads}
}

async function matchPair(browser) {
  const a = await bootFresh(browser)
  const b = await bootFresh(browser)
  const door = 'button.door:has-text("Advice")'

  await a.page.locator(door).click()
  await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 10_000})
  await b.page.locator(door).click()

  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 15_000})
  ])
  await Promise.all([
    a.page.locator("#expressive-composer:not([hidden])").waitFor({state: "visible"}),
    b.page.locator("#expressive-composer:not([hidden])").waitFor({state: "visible"})
  ])
  return {a, b}
}

async function clickHeartFromRealPicker(page) {
  if (await page.locator("#emoji-composer-picker").isHidden()) await page.locator("#emoji-open").click()
  await page.locator("#emoji-composer-picker").waitFor({state: "visible"})
  await page.locator("#emoji-composer-picker emoji-picker").waitFor({state: "attached"})
  await page.waitForFunction(() => {
    const picker = document.querySelector("#emoji-composer-picker emoji-picker")
    return Boolean(picker?.shadowRoot?.querySelector("button"))
  })

  const clicked = await page.evaluate(() => {
    const picker = document.querySelector("#emoji-composer-picker emoji-picker")
    const buttons = [...picker.shadowRoot.querySelectorAll("button")]
    const heart = buttons.find((button) => {
      const label = (button.getAttribute("aria-label") || "").toLowerCase()
      return button.textContent?.includes("❤️") || label.includes("red heart")
    })
    if (!heart) return false
    heart.click()
    return true
  })
  assert.equal(clicked, true, "the local emoji picker exposes a selectable red heart")
}

async function openGif(page) {
  if (await page.locator("#gif-picker").isHidden()) await page.locator("#gif-open").click()
  await page.locator("#gif-picker").waitFor({state: "visible"})
}

async function searchGif(page, query) {
  await openGif(page)
  await page.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
  await page.locator("#gif-search").fill(query)
}

async function endConversation(page) {
  await page.evaluate(() => {
    const details = document.querySelector(".conversation-head-actions details.overflow")
    if (details) details.open = true
    document.querySelector("#end-conversation")?.click()
  })
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
  await page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: 10_000})
}

async function blockConversation(page) {
  await page.evaluate(() => {
    const details = document.querySelector(".conversation-head-actions details.overflow")
    if (details) details.open = true
    document.querySelector("#block")?.click()
  })
  await page.waitForFunction(() => !document.querySelector('[data-screen="conversation"]')?.classList.contains("active"), null, {timeout: 10_000})
}

function mediaCount(page) {
  return page.locator("#messages .expressive-message img").count()
}

async function assertEmojiEdit(page, initial, start, end, expected, expectedCaret) {
  const input = page.locator("#message-input")
  await input.fill(initial)
  await input.evaluate((node, selection) => node.setSelectionRange(selection.start, selection.end), {start, end})
  const beforeMessages = await page.locator("#messages > li").count()
  await clickHeartFromRealPicker(page)
  assert.equal(await input.inputValue(), expected)
  assert.equal(await input.evaluate((node) => node.selectionStart), expectedCaret)
  assert.equal(await page.locator("#messages > li").count(), beforeMessages, "emoji insertion never auto-sends")
  await page.locator("#emoji-close").click()
}

test("Team 10 real Conversation covers canonical load, emoji, sticker, GIF and stale search", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b} = pair

    assert.equal(a.loads.runtime, 1)
    assert.equal(a.loads.app, 1)
    assert.equal(b.loads.runtime, 1)
    assert.equal(b.loads.app, 1)
    assert.equal(await a.page.locator("#emoji-open").isVisible(), true)
    assert.equal(await a.page.locator("#expressive-open").isVisible(), true)
    assert.equal(await a.page.locator("#gif-open").isVisible(), true)
    assert.equal((await a.page.locator("#expressive-open").textContent()).trim(), "Stickers")

    await assertEmojiEdit(a.page, "hello", 0, 0, "❤️hello", 2)
    await assertEmojiEdit(a.page, "hello world", 5, 5, "hello❤️ world", 7)
    await assertEmojiEdit(a.page, "hello", 5, 5, "hello❤️", 7)
    await assertEmojiEdit(a.page, "hello world", 6, 11, "hello ❤️", 8)
    await assertEmojiEdit(a.page, "one\ntwo\nthree", 7, 7, "one\ntwo❤️\nthree", 9)

    const input = a.page.locator("#message-input")
    await input.fill("native 😊 input")
    await a.page.locator("#message-form button.primary").click()
    await b.page.locator("#messages .message-content").filter({hasText: "native 😊 input"}).waitFor({state: "visible"})

    await input.fill("draft survives sticker send")
    const aBeforeSticker = await mediaCount(a.page)
    const bBeforeSticker = await mediaCount(b.page)
    await a.page.locator("#expressive-open").click()
    await a.page.locator("#expressive-picker").waitFor({state: "visible"})
    await a.page.locator("#expressive-results button").first().click()
    await a.page.waitForFunction((count) => document.querySelectorAll("#messages .expressive-message img").length === count + 1, aBeforeSticker)
    await b.page.waitForFunction((count) => document.querySelectorAll("#messages .expressive-message img").length === count + 1, bBeforeSticker)
    assert.equal(await input.inputValue(), "draft survives sticker send")

    await a.page.route("**/api/gifs/status", (route) => route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({available: false})}))
    await a.page.locator("#gif-open").click()
    await a.page.getByText("GIFs unavailable. Stickers, emoji, and normal messages still work.", {exact: true}).waitFor({state: "visible"})
    assert.equal(await a.page.locator("#gif-search").isDisabled(), true)
    await a.page.screenshot({path: `${SCREENSHOT_DIR}/team10-gif-unavailable-390x844.png`, fullPage: false})
    await a.page.locator("#gif-close").click()
    await a.page.unroute("**/api/gifs/status")

    await input.fill("draft survives GIF send")
    const aBeforeGif = await mediaCount(a.page)
    const bBeforeGif = await mediaCount(b.page)
    await searchGif(a.page, "happy dance")
    await a.page.locator("#gif-results button", {hasText: "Fixture GIF happy dance"}).waitFor({state: "visible"})
    await a.page.locator("#gif-results button").first().click()
    await a.page.waitForFunction((count) => document.querySelectorAll("#messages .expressive-message img").length === count + 1, aBeforeGif)
    await b.page.waitForFunction((count) => document.querySelectorAll("#messages .expressive-message img").length === count + 1, bBeforeGif)
    assert.equal(await input.inputValue(), "draft survives GIF send")
    assert.match(await b.page.locator("#messages .expressive-message img").last().getAttribute("alt"), /Fixture GIF happy dance/i)

    for (const [query, expected] of [
      ["empty", "No GIFs found. Try another search."],
      ["error", "GIF search failed. Try another search."],
      ["malformed", "GIF search failed. Try another search."],
      ["timeout", "GIF search failed. Try another search."],
      ["rate", "GIF search is rate limited. Try again in a moment."]
    ]) {
      await searchGif(a.page, query)
      await a.page.getByText(expected, {exact: true}).waitFor({state: "visible", timeout: 10_000})
    }

    let catStarted
    const catRequestStarted = new Promise((resolve) => { catStarted = resolve })
    await a.page.route("**/api/gifs/search?**", async (route) => {
      const url = new URL(route.request().url())
      if (url.searchParams.get("q") !== "cat") return route.continue()
      catStarted()
      const response = await route.fetch()
      await new Promise((resolve) => setTimeout(resolve, 700))
      await route.fulfill({response})
    })

    await searchGif(a.page, "cat")
    await catRequestStarted
    await a.page.locator("#gif-search").fill("dog")
    await a.page.locator("#gif-results button", {hasText: "Fixture GIF dog"}).waitFor({state: "visible"})
    await a.page.waitForTimeout(800)
    assert.equal(await a.page.locator("#gif-results button", {hasText: "Fixture GIF cat"}).count(), 0)
    await a.page.unroute("**/api/gifs/search?**")

    let lateStarted
    const lateRequestStarted = new Promise((resolve) => { lateStarted = resolve })
    await a.page.route("**/api/gifs/search?**", async (route) => {
      const url = new URL(route.request().url())
      if (url.searchParams.get("q") !== "late result") return route.continue()
      lateStarted()
      const response = await route.fetch()
      await new Promise((resolve) => setTimeout(resolve, 650))
      await route.fulfill({response})
    })
    await a.page.locator("#gif-search").fill("late result")
    await lateRequestStarted
    await endConversation(a.page)
    await a.page.waitForTimeout(800)
    assert.equal(await a.page.locator("#gif-picker").isHidden(), true)
    assert.equal(await a.page.locator("#gif-results button").count(), 0)
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 10 Block invalidates in-flight GIF search", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const page = pair.a.page
    let started
    const requestStarted = new Promise((resolve) => { started = resolve })
    await page.route("**/api/gifs/search?**", async (route) => {
      const url = new URL(route.request().url())
      if (url.searchParams.get("q") !== "block delay") return route.continue()
      started()
      const response = await route.fetch()
      await new Promise((resolve) => setTimeout(resolve, 650))
      await route.fulfill({response})
    })
    await searchGif(page, "block delay")
    await requestStarted
    await blockConversation(page)
    await page.waitForTimeout(800)
    assert.equal(await page.locator("#gif-picker").isHidden(), true)
    assert.equal(await page.locator("#gif-results button").count(), 0)
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Team 10 expression controls survive mobile keyboard, Escape focus and reduced motion", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const page = pair.a.page

    for (const viewport of [
      {width: 320, height: 568, name: "320x568"},
      {width: 390, height: 844, name: "390x844"},
      {width: 844, height: 390, name: "844x390"}
    ]) {
      await page.setViewportSize({width: viewport.width, height: viewport.height})
      for (const selector of ["#emoji-open", "#expressive-open", "#gif-open"]) {
        const box = await page.locator(selector).boundingBox()
        assert.ok(box, `${viewport.name} ${selector} is rendered`)
        assert.ok(box.x >= -1 && box.y >= -1, `${viewport.name} ${selector} starts onscreen`)
        assert.ok(box.x + box.width <= viewport.width + 1, `${viewport.name} ${selector} fits horizontally`)
        assert.ok(box.y + box.height <= viewport.height + 1, `${viewport.name} ${selector} fits vertically`)
        assert.ok(box.height >= 40, `${viewport.name} ${selector} has a usable touch height`)
      }
    }

    await page.setViewportSize({width: 390, height: 500})
    await page.locator("#message-input").focus()
    const keyboardLayout = await page.locator("#message-form").boundingBox()
    assert.ok(keyboardLayout && keyboardLayout.y + keyboardLayout.height <= 501, "composer remains reachable after keyboard-like viewport shrink")

    await page.locator("#emoji-open").click()
    await page.locator("#emoji-composer-picker").waitFor({state: "visible"})
    await page.keyboard.press("Escape")
    assert.equal(await page.locator("#emoji-composer-picker").isHidden(), true)
    assert.equal(await page.locator("#message-input").evaluate((node) => document.activeElement === node), true)

    await openGif(page)
    await page.keyboard.press("Escape")
    assert.equal(await page.locator("#gif-picker").isHidden(), true)
    assert.equal(await page.locator("#gif-open").evaluate((node) => document.activeElement === node), true)

    await page.emulateMedia({reducedMotion: "reduce"})
    await page.locator("#expressive-open").click()
    await page.locator("#expressive-picker").waitFor({state: "visible"})
    const animatedSticker = page.locator("#expressive-results img.expressive-loop").first()
    if (await animatedSticker.count()) {
      const animationName = await animatedSticker.evaluate((node) => getComputedStyle(node).animationName)
      assert.equal(animationName, "none")
    }
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
