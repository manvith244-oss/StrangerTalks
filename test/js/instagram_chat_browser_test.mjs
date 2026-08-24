import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4002"
const SCREENSHOT_DIR = "tmp/chat-ui-screenshots"
fs.mkdirSync(SCREENSHOT_DIR, {recursive: true})

const DEVICES = [
  {name: "tiny legacy phone", width: 320, height: 568, mobile: true, touch: true},
  {name: "small Android phone", width: 360, height: 740, mobile: true, touch: true},
  {name: "modern phone", width: 390, height: 844, mobile: true, touch: true},
  {name: "tall Android phone", width: 412, height: 915, mobile: true, touch: true},
  {name: "phone landscape", width: 844, height: 390, mobile: true, touch: true},
  {name: "tablet", width: 820, height: 1180, mobile: true, touch: true},
  {name: "desktop", width: 1440, height: 900, mobile: false, touch: false}
]

const SHORT_PANEL_SELECTORS = [
  "#voice-warning",
  "#voice-preview",
  "#view-once-preview",
  "#atmosphere-chooser",
  "#report-form"
]

function screenshotName(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
}

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
      {mine: false, text: `https://example.com/${"very-long-unbroken-path-".repeat(12)}`},
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
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".site-header")).display === "none")
  await page.waitForFunction(() => document.querySelector("#messages > .message.ig-group-start"))
}

async function assertShortPanelsStayEscapable(page, device) {
  for (const selector of SHORT_PANEL_SELECTORS) {
    const exists = await page.locator(selector).count()
    if (!exists) continue

    await page.evaluate(({selectors, active}) => {
      for (const candidate of selectors) {
        const panel = document.querySelector(candidate)
        if (panel) panel.hidden = candidate !== active
      }
    }, {selectors: SHORT_PANEL_SELECTORS, active: selector})

    const geometry = await page.locator(selector).evaluate((panel) => {
      const rect = panel.getBoundingClientRect()
      const style = getComputedStyle(panel)
      return {
        top: rect.top,
        bottom: rect.bottom,
        height: rect.height,
        overflowY: style.overflowY,
        scrollHeight: panel.scrollHeight,
        clientHeight: panel.clientHeight
      }
    })

    assert.ok(geometry.top >= -1, `${device.name} ${selector} starts above viewport: ${geometry.top}`)
    assert.ok(geometry.bottom <= device.height + 1, `${device.name} ${selector} ends below viewport: ${geometry.bottom}`)
    assert.ok(["auto", "scroll"].includes(geometry.overflowY), `${device.name} ${selector} is not scrollable`)
    if (geometry.scrollHeight > geometry.clientHeight + 1) {
      assert.ok(geometry.clientHeight > 0, `${device.name} ${selector} has no usable scroll viewport`)
    }

    if (device.name === "phone landscape") {
      await page.screenshot({
        path: `${SCREENSHOT_DIR}/landscape-${screenshotName(selector)}.png`,
        fullPage: false
      })
    }
  }

  await page.evaluate((selectors) => {
    for (const selector of selectors) {
      const panel = document.querySelector(selector)
      if (panel) panel.hidden = true
    }
  }, SHORT_PANEL_SELECTORS)
}

for (const device of DEVICES) {
  test(`Conversation shell stays usable on ${device.name}`, async () => {
    const browser = await chromium.launch({headless: true})
    const context = await browser.newContext({
      viewport: {width: device.width, height: device.height},
      isMobile: device.mobile,
      hasTouch: device.touch,
      deviceScaleFactor: device.mobile ? 2 : 1
    })
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
          composerFontSize: Number.parseFloat(getComputedStyle(input).fontSize),
          cameraLabel: camera.getAttribute("aria-label"),
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
      if (device.mobile) assert.ok(layout.composerFontSize >= 16, `mobile composer font is ${layout.composerFontSize}px`)
      assert.equal(layout.cameraLabel, "Choose a view-once photo")
      assert.equal(layout.heading, "Stranger")
      assert.equal(layout.hasBack, true)
      assert.equal(layout.placeholder, "Message…")
      assert.equal(layout.companionLoaded, true)
      assert.deepEqual(layout.grouped, ["ig-group-start", "ig-group-end", "ig-group-start", "ig-group-end", "ig-group-solo"])

      const info = page.locator(".conversation-head-actions .overflow")
      const infoSummary = info.locator("summary")
      await infoSummary.click()
      assert.equal(await info.evaluate((details) => details.open), true)
      assert.equal(await infoSummary.getAttribute("aria-expanded"), "true")
      await page.keyboard.press("Escape")
      assert.equal(await info.evaluate((details) => details.open), false)
      assert.equal(await infoSummary.getAttribute("aria-expanded"), "false")
      assert.equal(await infoSummary.evaluate((summary) => document.activeElement === summary), true)

      await infoSummary.click()
      assert.equal(await info.evaluate((details) => details.open), true)
      await page.locator("#messages").click({position: {x: 4, y: 4}})
      assert.equal(await info.evaluate((details) => details.open), false)

      await page.click(".ig-compose-plus")
      assert.equal(await page.locator("#message-form").evaluate((form) => form.classList.contains("ig-tray-open")), true)
      assert.equal(await page.locator("#ig-message-tools").evaluate((tray) => getComputedStyle(tray).display !== "none"), true)

      await page.focus("#message-input")
      assert.equal(await page.locator("body").evaluate((body) => body.classList.contains("ig-keyboard-open")), true)

      await page.fill("#message-input", "hello")
      assert.equal(await page.locator("#message-form").evaluate((form) => form.classList.contains("has-text")), true)
      assert.equal(await page.locator("#message-form").evaluate((form) => form.classList.contains("ig-tray-open")), false)
      assert.equal(await page.locator(".ig-compose-plus").getAttribute("aria-expanded"), "false")
      assert.equal(await page.locator("#message-form .compose > .primary").evaluate((button) => getComputedStyle(button).pointerEvents !== "none"), true)

      await page.evaluate(() => { document.querySelector("#message-input").value = "" })
      await page.waitForFunction(() => !document.querySelector("#message-form").classList.contains("has-text"))
      assert.equal(await page.locator(".ig-compose-plus").evaluate((button) => getComputedStyle(button).display !== "none"), true)

      await page.evaluate(() => { document.querySelector("#message-input").value = "Prompt-filled draft" })
      await page.waitForFunction(() => document.querySelector("#message-form").classList.contains("has-text"))
      assert.equal(await page.locator("#message-form .compose > .primary").evaluate((button) => getComputedStyle(button).pointerEvents !== "none"), true)

      await page.evaluate(() => {
        const item = document.createElement("li")
        item.className = "message mine message-unsent"
        item.dataset.messageId = "visual-unsent"
        item.tabIndex = 0
        const content = document.createElement("span")
        content.className = "message-content"
        content.textContent = "Message unsent"
        const status = document.createElement("small")
        status.className = "message-status"
        status.textContent = "Delivered"
        item.append(content, status)
        document.querySelector("#messages").append(item)
      })
      await page.waitForFunction(() => document.querySelector('[data-message-id="visual-3"]')?.classList.contains("ig-latest-own"))
      assert.equal(await page.locator('[data-message-id="visual-unsent"]').evaluate((item) => item.classList.contains("ig-latest-own")), false)
      assert.equal(await page.locator('[data-message-id="visual-3"]').evaluate((item) => item.classList.contains("ig-latest-own")), true)

      if (["tiny legacy phone", "phone landscape"].includes(device.name)) {
        await assertShortPanelsStayEscapable(page, device)
      }

      await page.screenshot({
        path: `${SCREENSHOT_DIR}/${screenshotName(device.name)}.png`,
        fullPage: false
      })
    } finally {
      await context.close()
      await browser.close()
    }
  })
}
