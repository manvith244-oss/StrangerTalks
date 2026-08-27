import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL
const SCREENSHOT_DIR = "tmp/chat-ui-screenshots"
fs.mkdirSync(SCREENSHOT_DIR, {recursive: true})

async function openMobilePage(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({
    viewport,
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2
  })
  const page = await context.newPage()
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.f09MobileFlowBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
  return {context, page}
}

async function prepareConversation(page) {
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForTimeout(1000)

  await page.evaluate(() => {
    document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
    document.querySelector('[data-screen="conversation"]').classList.add("active")
    const expressive = document.querySelector("#expressive-composer")
    if (expressive) expressive.hidden = false

    const messages = document.querySelector("#messages")
    messages.replaceChildren()
    for (let index = 0; index < 36; index += 1) {
      const item = document.createElement("li")
      item.className = `message${index % 2 ? " mine" : ""}`
      item.dataset.messageId = `f09-${index}`
      const content = document.createElement("span")
      content.className = "message-content"
      content.textContent = `Viewport continuity message ${index + 1}`
      item.append(content)
      messages.append(item)
    }

    const input = document.querySelector("#message-input")
    input.value = "draft survives"
    input.dispatchEvent(new Event("input", {bubbles: true}))
  })

  await page.waitForFunction(() => document.body.classList.contains("st-chat-mode"))
  await page.waitForFunction(() => document.querySelector(".ig-chat-back"))
}

async function assertConversationLayout(page, label) {
  const layout = await page.evaluate(() => {
    const conversation = document.querySelector('[data-screen="conversation"]')
    const composer = document.querySelector("#message-form")
    const conversationRect = conversation.getBoundingClientRect()
    const composerRect = composer.getBoundingClientRect()
    return {
      active: conversation.classList.contains("active"),
      width: window.innerWidth,
      height: window.innerHeight,
      conversationWidth: conversationRect.width,
      conversationHeight: conversationRect.height,
      composerBottom: composerRect.bottom,
      overflowX: document.documentElement.scrollWidth - window.innerWidth,
      draft: document.querySelector("#message-input").value,
      viewportVar: Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--ig-vh"))
    }
  })

  assert.equal(layout.active, true, `${label}: Conversation lost active state`)
  assert.equal(layout.draft, "draft survives", `${label}: draft was lost`)
  assert.ok(layout.overflowX <= 1, `${label}: horizontal overflow ${layout.overflowX}px`)
  assert.ok(layout.conversationWidth <= layout.width + 1, `${label}: Conversation wider than viewport`)
  assert.ok(layout.conversationHeight <= layout.height + 1, `${label}: Conversation taller than viewport`)
  assert.ok(layout.composerBottom <= layout.height + 1, `${label}: composer below viewport`)
  assert.ok(Number.isFinite(layout.viewportVar), `${label}: --ig-vh is not numeric`)
  assert.ok(Math.abs(layout.viewportVar - layout.height) <= 2, `${label}: --ig-vh ${layout.viewportVar}px != viewport ${layout.height}px`)
}

if (!BASE_URL) {
  test("F-09 browser checks require STRANGERTALKS_BROWSER_BASE_URL", {skip: true}, () => {})
} else {
  test("F-09 suppresses only rapid touch matchmaking taps and preserves keyboard/script activation", async () => {
    const browser = await chromium.launch({headless: true})
    let context

    try {
      const opened = await openMobilePage(browser)
      context = opened.context
      const page = opened.page

      const viewportMeta = await page.locator('meta[name="viewport"]').getAttribute("content")
      assert.match(viewportMeta || "", /viewport-fit=cover/)
      assert.doesNotMatch(viewportMeta || "", /user-scalable\s*=\s*no/i)

      await page.evaluate(() => {
        window.__f09RapidTapCount = 0
        const probe = document.createElement("button")
        probe.id = "f09-rapid-tap-probe"
        probe.className = "door"
        probe.type = "button"
        probe.textContent = "F-09 probe"
        probe.addEventListener("click", (event) => {
          window.__f09RapidTapCount += 1
          event.stopPropagation()
        })
        document.querySelector("#doors").append(probe)
      })

      const probe = page.locator("#f09-rapid-tap-probe")
      await probe.tap()
      await probe.tap()
      assert.equal(await page.evaluate(() => window.__f09RapidTapCount), 1, "second rapid touch tap was not suppressed")

      await probe.focus()
      await page.keyboard.press("Enter")
      assert.equal(await page.evaluate(() => window.__f09RapidTapCount), 2, "keyboard activation was incorrectly suppressed")

      await page.evaluate(() => document.querySelector("#f09-rapid-tap-probe").click())
      assert.equal(await page.evaluate(() => window.__f09RapidTapCount), 3, "script activation was incorrectly suppressed")

      await page.waitForTimeout(925)
      await probe.tap()
      assert.equal(await page.evaluate(() => window.__f09RapidTapCount), 4, "touch tap did not recover after suppression window")
    } finally {
      await context?.close()
      await browser.close()
    }
  })

  test("F-09 Conversation preserves draft, safe geometry, keyboard presentation, and lifecycle continuity", async () => {
    const browser = await chromium.launch({headless: true})
    let context

    try {
      const opened = await openMobilePage(browser)
      context = opened.context
      const page = opened.page
      await prepareConversation(page)

      await page.focus("#message-input")
      await page.waitForFunction(() => document.body.classList.contains("ig-keyboard-open"))
      await assertConversationLayout(page, "portrait")

      await page.setViewportSize({width: 390, height: 520})
      await page.waitForTimeout(100)
      await assertConversationLayout(page, "short portrait")

      await page.setViewportSize({width: 844, height: 390})
      await page.waitForTimeout(100)
      await assertConversationLayout(page, "landscape")
      await page.screenshot({path: `${SCREENSHOT_DIR}/f09-dynamic-landscape.png`, fullPage: false})

      await page.evaluate(() => window.dispatchEvent(new Event("pagehide")))
      assert.equal(await page.evaluate(() => document.body.classList.contains("ig-keyboard-open")), false, "background presentation stayed keyboard-open")
      await assertConversationLayout(page, "background presentation")

      await page.evaluate(() => window.dispatchEvent(new Event("pageshow")))
      await page.waitForFunction(() => document.body.classList.contains("ig-keyboard-open"))
      await assertConversationLayout(page, "foreground presentation")

      await page.setViewportSize({width: 390, height: 844})
      await page.waitForTimeout(100)
      await assertConversationLayout(page, "portrait restored")
      await page.screenshot({path: `${SCREENSHOT_DIR}/f09-portrait-restored.png`, fullPage: false})
    } finally {
      await context?.close()
      await browser.close()
    }
  })

  test("F-09 coarse-pointer Conversation controls remain accessible touch targets and preserve system-edge scrolling", async () => {
    const browser = await chromium.launch({headless: true})
    let context

    try {
      const opened = await openMobilePage(browser)
      context = opened.context
      const page = opened.page
      await prepareConversation(page)

      const targets = [
        ".ig-chat-back",
        "#btn-voice-call",
        "#btn-video-call",
        ".overflow summary",
        ".ig-compose-plus",
        "#view-once-picker-btn",
        "#voice-start"
      ]

      for (const selector of targets) {
        const target = page.locator(selector)
        assert.equal(await target.count(), 1, `${selector}: expected one target`)
        const geometry = await target.boundingBox()
        assert.ok(geometry, `${selector}: no rendered geometry`)
        assert.ok(geometry.width >= 47.5, `${selector}: width ${geometry.width}px is below 48px coarse target`)
        assert.ok(geometry.height >= 47.5, `${selector}: height ${geometry.height}px is below 48px coarse target`)
        const label = await target.getAttribute("aria-label")
        assert.ok(label?.trim(), `${selector}: missing accessible label`)
      }

      const interaction = await page.evaluate(() => {
        const message = document.querySelector("#messages > .message")
        const input = document.querySelector("#message-input")
        return {
          messageTouchAction: getComputedStyle(message).touchAction,
          inputFontSize: Number.parseFloat(getComputedStyle(input).fontSize),
          overflowX: document.documentElement.scrollWidth - window.innerWidth
        }
      })

      assert.equal(interaction.messageTouchAction, "pan-y")
      assert.ok(interaction.inputFontSize >= 16, `composer font-size ${interaction.inputFontSize}px risks iOS focus zoom`)
      assert.ok(interaction.overflowX <= 1, `Conversation has horizontal overflow ${interaction.overflowX}px`)
    } finally {
      await context?.close()
      await browser.close()
    }
  })
}
