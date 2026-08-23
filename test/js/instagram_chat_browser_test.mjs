import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"
const DEVICES = [
  {name: "small Android phone", width: 360, height: 740},
  {name: "modern phone", width: 390, height: 844},
  {name: "phone landscape", width: 844, height: 390},
  {name: "tablet", width: 820, height: 1180},
  {name: "desktop", width: 1440, height: 900}
]

async function prepareConversation(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")

  await page.evaluate(() => {
    document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
    const conversation = document.querySelector('[data-screen="conversation"]')
    conversation.classList.add("active")

    const expressive = document.querySelector("#expressive-composer")
    if (expressive) expressive.hidden = false

    const messages = document.querySelector("#messages")
    messages.replaceChildren()
    const rows = [
      {mine: false, text: "Hey, how is your day going?"},
      {mine: false, text: "Anything unexpectedly good happen?"},
      {mine: true, text: "Honestly, getting a quiet evening 😭"},
      {mine: true, text: "I needed it."},
      {mine: false, text: "That sounds peaceful."}
    ]

    for (const [index, row] of rows.entries()) {
      const item = document.createElement("li")
      item.className = `message${row.mine ? " mine" : ""}`
      item.dataset.messageId = `visual-${index}`
      item.tabIndex = 0
      const content = document.createElement("span")
      content.className = "message-content"
      content.textContent = row.text
      item.append(content)
      if (row.mine) {
        const status = document.createElement("small")
        status.className = "message-status"
        status.textContent = "Delivered"
        item.append(status)
      }
      messages.append(item)
    }
  })

  await page.waitForFunction(() => document.body.classList.contains("st-chat-mode"))
  await page.waitForFunction(() => document.querySelector("#messages > .message.ig-group-start"))
}

for (const device of DEVICES) {
  test(`Conversation shell stays usable on ${device.name}`, async () => {
    const browser = await chromium.launch({headless: true})
    const context = await browser.newContext({viewport: {width: device.width, height: device.height}})
    const page = await context.newPage()

    try {
      await prepareConversation(page)

      const layout = await page.evaluate(() => {
        const conversation = document.querySelector('[data-screen="conversation"]')
        const composer = document.querySelector("#message-form")
        const camera = document.querySelector("#view-once-picker-btn")
        const voice = document.querySelector("#voice-start")
        const plus = document.querySelector(".ig-compose-plus")
        const heading = document.querySelector(".conversation-head h1")
        const back = document.querySelector(".ig-chat-back")
        const input = document.querySelector("#message-input")
        const conversationRect = conversation.getBoundingClientRect()
        const composerRect = composer.getBoundingClientRect()
        const cameraRect = camera.getBoundingClientRect()
        const voiceRect = voice.getBoundingClientRect()
        const plusRect = plus.getBoundingClientRect()

        return {
          bodyMode: document.body.classList.contains("st-chat-mode"),
          siteHeaderDisplay: getComputedStyle(document.querySelector(".site-header")).display,
          overflowX: document.documentElement.scrollWidth - window.innerWidth,
          conversationWidth: conversationRect.width,
          conversationHeight: conversationRect.height,
          composerBottom: composerRect.bottom,
          cameraSize: Math.min(cameraRect.width, cameraRect.height),
          voiceSize: Math.min(voiceRect.width, voiceRect.height),
          plusSize: Math.min(plusRect.width, plusRect.height),
          heading: heading.textContent,
          hasBack: Boolean(back),
          placeholder: input.getAttribute("placeholder"),
          companionLoaded: Boolean(document.querySelector("#companion-control")),
          grouped: Array.from(document.querySelectorAll("#messages > .message")).map((item) =>
            [...item.classList].find((name) => name.startsWith("ig-group-"))
          )
        }
      })

      assert.equal(layout.bodyMode, true)
      assert.equal(layout.siteHeaderDisplay, "none")
      assert.ok(layout.overflowX <= 1, `horizontal overflow: ${layout.overflowX}px`)
      assert.ok(layout.conversationWidth <= device.width)
      assert.ok(layout.conversationHeight <= device.height + 1)
      assert.ok(layout.composerBottom <= device.height + 1)
      assert.ok(layout.cameraSize >= 40)
      assert.ok(layout.voiceSize >= 40)
      assert.ok(layout.plusSize >= 40)
      assert.equal(layout.heading, "Stranger")
      assert.equal(layout.hasBack, true)
      assert.equal(layout.placeholder, "Message…")
      assert.equal(layout.companionLoaded, true)
      assert.deepEqual(layout.grouped, ["ig-group-start", "ig-group-end", "ig-group-start", "ig-group-end", "ig-group-solo"])

      await page.click(".ig-compose-plus")
      assert.equal(await page.locator("#message-form").evaluate((form) => form.classList.contains("ig-tray-open")), true)
      assert.equal(await page.locator("#ig-message-tools").evaluate((tray) => getComputedStyle(tray).display !== "none"), true)

      await page.focus("#message-input")
      assert.equal(await page.locator("body").evaluate((body) => body.classList.contains("ig-keyboard-open")), true)

      await page.fill("#message-input", "hello")
      assert.equal(await page.locator("#message-form").evaluate((form) => form.classList.contains("has-text")), true)
      assert.equal(await page.locator("#message-form .compose > .primary").evaluate((button) => getComputedStyle(button).pointerEvents !== "none"), true)
    } finally {
      await context.close()
      await browser.close()
    }
  })
}
