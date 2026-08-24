import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"
const SCREENSHOT_DIR = "tmp/chat-ui-screenshots"
fs.mkdirSync(SCREENSHOT_DIR, {recursive: true})

async function bootFresh(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 15_000})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page}
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
  await page.locator("#emoji-open").click()
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

async function endConversation(page) {
  const overflow = page.locator(".conversation-head-actions details.overflow")
  if ((await overflow.getAttribute("open")) === null) await overflow.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible"})
  await page.locator("#end-confirm").click()
  await page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: 10_000})
}

function mediaCount(page) {
  return page.locator("#messages .expressive-message img").count()
}

test("Team 10 real Conversation: emoji insertion, sticker delivery, GIF truthfulness and terminal stale guard", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const {a, b} = pair

    assert.equal(await a.page.locator("#emoji-open").isVisible(), true)
    assert.equal(await a.page.locator("#expressive-open").isVisible(), true)
    assert.equal(await a.page.locator("#gif-open").isVisible(), true)
    assert.equal((await a.page.locator("#expressive-open").textContent()).trim(), "Stickers")

    const input = a.page.locator("#message-input")
    await input.fill("hello world")
    await input.evaluate((node) => node.setSelectionRange(5, 5))
    await clickHeartFromRealPicker(a.page)
    assert.equal(await input.inputValue(), "hello❤️ world")
    assert.equal(await input.evaluate((node) => node.selectionStart), 7)

    await a.page.locator("#message-form button.primary").click()
    await b.page.locator("#messages .message-content").filter({hasText: "hello❤️ world"}).waitFor({state: "visible"})
    assert.equal(await b.page.locator("#messages .message-content").filter({hasText: "hello❤️ world"}).count(), 1)

    await input.fill("draft survives sticker send")
    const aBefore = await mediaCount(a.page)
    const bBefore = await mediaCount(b.page)
    await a.page.locator("#expressive-open").click()
    await a.page.locator("#expressive-picker").waitFor({state: "visible"})
    await a.page.locator("#expressive-results button").first().click()
    await a.page.waitForFunction((count) => document.querySelectorAll("#messages .expressive-message img").length === count + 1, aBefore)
    await b.page.waitForFunction((count) => document.querySelectorAll("#messages .expressive-message img").length === count + 1, bBefore)
    assert.equal(await input.inputValue(), "draft survives sticker send")
    assert.match(await b.page.locator("#messages .expressive-message img").last().getAttribute("alt"), /wave|spark|sticker|bounc|calm/i)

    await a.page.locator("#gif-open").click()
    await a.page.locator("#gif-picker").waitFor({state: "visible"})
    await a.page.getByText("GIFs unavailable. Stickers, emoji, and normal messages still work.", {exact: true}).waitFor({state: "visible"})
    assert.equal(await a.page.locator("#gif-search").isDisabled(), true)
    await a.page.screenshot({path: `${SCREENSHOT_DIR}/team10-gif-unavailable-390x844.png`, fullPage: false})
    await a.page.locator("#gif-close").click()

    await a.page.route("**/api/gifs/status", async (route) => {
      await route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({available: true})})
    })
    let releaseLateSearch
    const lateSearchStarted = new Promise((resolve) => { releaseLateSearch = resolve })
    await a.page.route("**/api/gifs/search?**", async (route) => {
      releaseLateSearch()
      await new Promise((resolve) => setTimeout(resolve, 650))
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({results: [{
          id: "late",
          provider: "fake",
          reference: "signed-late-reference",
          media_url: "https://media.example.test/late.gif",
          label: "Late GIF",
          width: 160,
          height: 120
        }]})
      })
    })

    await a.page.locator("#gif-open").click()
    await a.page.locator("#gif-search").waitFor({state: "visible"})
    await a.page.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
    await a.page.locator("#gif-search").fill("late result")
    await lateSearchStarted
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

test("Team 10 expression controls stay reachable at required functional viewport floors", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const page = pair.a.page
    await page.route("**/api/gifs/status", (route) => route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({available: true})}))
    await page.route("**/api/gifs/search?**", (route) => route.fulfill({status: 200, contentType: "application/json", body: JSON.stringify({results: []})}))

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

      await page.locator("#gif-open").click()
      await page.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
      await page.locator("#gif-search").focus()
      const panelBox = await page.locator("#gif-picker").boundingBox()
      assert.ok(panelBox)
      assert.ok(panelBox.x >= -1 && panelBox.x + panelBox.width <= viewport.width + 1, `${viewport.name} GIF sheet fits width`)
      assert.ok(panelBox.y >= -1 && panelBox.y + panelBox.height <= viewport.height + 1, `${viewport.name} GIF sheet fits height`)
      await page.locator("#gif-close").click()

      await page.locator("#message-input").fill("line one\nline two\nline three")
      await page.locator("#emoji-open").click()
      await page.locator("#emoji-composer-picker").waitFor({state: "visible"})
      const emojiBox = await page.locator("#emoji-composer-picker").boundingBox()
      assert.ok(emojiBox)
      assert.ok(emojiBox.x >= -1 && emojiBox.x + emojiBox.width <= viewport.width + 1, `${viewport.name} emoji sheet fits width`)
      assert.ok(emojiBox.y >= -1 && emojiBox.y + emojiBox.height <= viewport.height + 1, `${viewport.name} emoji sheet fits height`)
      await page.locator("#emoji-close").click()
    }
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
