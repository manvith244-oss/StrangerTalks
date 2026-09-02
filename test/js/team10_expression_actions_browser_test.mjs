import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"
const GIF_PIXEL = Buffer.from("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "base64")

async function bootFresh(browser) {
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  await context.route("https://media.example.test/**", (route) =>
    route.fulfill({status: 200, contentType: "image/gif", body: GIF_PIXEL})
  )
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

async function sendSticker(sender, receiver) {
  const beforeSender = await sender.locator("#messages .expressive-message").count()
  const beforeReceiver = await receiver.locator("#messages .expressive-message").count()
  await sender.locator("#expressive-open").click()
  await sender.locator("#expressive-picker").waitFor({state: "visible"})
  await sender.locator("#expressive-results button").first().click()
  await sender.waitForFunction((n) => document.querySelectorAll("#messages .expressive-message").length === n + 1, beforeSender)
  await receiver.waitForFunction((n) => document.querySelectorAll("#messages .expressive-message").length === n + 1, beforeReceiver)
}

async function sendGif(sender, receiver) {
  const beforeSender = await sender.locator("#messages .expressive-message").count()
  const beforeReceiver = await receiver.locator("#messages .expressive-message").count()
  await sender.locator("#gif-open").click()
  await sender.waitForFunction(() => document.querySelector("#gif-search")?.disabled === false)
  await sender.locator("#gif-search").fill("actions proof")
  await sender.locator("#gif-results button").first().waitFor({state: "visible", timeout: 10_000})
  await sender.locator("#gif-results button").first().click()
  await sender.waitForFunction((n) => document.querySelectorAll("#messages .expressive-message").length === n + 1, beforeSender)
  await receiver.waitForFunction((n) => document.querySelectorAll("#messages .expressive-message").length === n + 1, beforeReceiver)
}

test("expressive messages expose React/Reply/Pin, close overlapping picker, and never expose Edit/Unsend", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair

  try {
    pair = await matchPair(browser)
    const sender = pair.a.page
    const receiver = pair.b.page

    await sendSticker(sender, receiver)
    const sticker = sender.locator("#messages .expressive-message").last()
    assert.equal(await sticker.locator(".react-action-btn").count(), 1)
    assert.equal(await sticker.locator(".reply-action-btn").count(), 1)
    assert.equal(await sticker.locator(".pin-action-btn").count(), 1)
    assert.equal(await sticker.locator(".edit-action-btn").count(), 0)
    assert.equal(await sticker.locator(".unsend-action-btn").count(), 0)

    await sender.locator("#emoji-open").click()
    await sender.locator("#emoji-composer-picker").waitFor({state: "visible"})
    await sticker.locator(".react-action-btn").click()
    assert.equal(await sender.locator("#emoji-composer-picker").isHidden(), true)
    await sender.locator(".reaction-picker").waitFor({state: "visible"})
    await sender.locator(".reaction-picker .reaction-btn").first().click()
    await sender.waitForFunction(() => {
      const message = document.querySelector("#messages .expressive-message")
      return Boolean(message?.querySelector(".message-reactions")?.children.length)
    })

    await sticker.locator(".pin-action-btn").click()
    await sender.waitForFunction(() => document.querySelector("#messages .expressive-message")?.classList.contains("is-pinned"))
    await receiver.waitForFunction(() => document.querySelector("#messages .expressive-message")?.classList.contains("is-pinned"))

    await sendGif(sender, receiver)
    const gif = sender.locator("#messages .expressive-message").last()
    assert.equal(await gif.locator(".react-action-btn").count(), 1)
    assert.equal(await gif.locator(".reply-action-btn").count(), 1)
    assert.equal(await gif.locator(".pin-action-btn").count(), 1)
    assert.equal(await gif.locator(".edit-action-btn").count(), 0)
    assert.equal(await gif.locator(".unsend-action-btn").count(), 0)
  } finally {
    await pair?.a?.context.close().catch(() => {})
    await pair?.b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
