import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL
const SCREENSHOT_DIR = "tmp/chat-ui-screenshots"
fs.mkdirSync(SCREENSHOT_DIR, {recursive: true})

if (!BASE_URL) {
  test("F-09 browser checks require STRANGERTALKS_BROWSER_BASE_URL", {skip: true}, () => {})
} else {
  test("F-09 live boot path suppresses rapid mobile matchmaking taps", async () => {
    const browser = await chromium.launch({headless: true})
    const context = await browser.newContext({
      viewport: {width: 390, height: 844},
      isMobile: true,
      hasTouch: true,
      deviceScaleFactor: 2
    })
    const page = await context.newPage()

    try {
      await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
      await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)

      const viewportMeta = await page.locator('meta[name="viewport"]').getAttribute("content")
      assert.match(viewportMeta || "", /viewport-fit=cover/)
      assert.doesNotMatch(viewportMeta || "", /user-scalable\s*=\s*no/i)

      await page.evaluate(() => {
        window.__f09RapidTapCount = 0
        const probe = document.createElement("button")
        probe.id = "f09-rapid-tap-probe"
        probe.type = "button"
        probe.textContent = "F-09 probe"
        probe.addEventListener("click", (event) => {
          window.__f09RapidTapCount += 1
          event.stopPropagation()
        })
        document.querySelector("#doors").append(probe)
        probe.click()
        probe.click()
      })

      assert.equal(await page.evaluate(() => window.__f09RapidTapCount), 1)
      await page.waitForTimeout(925)
      await page.locator("#f09-rapid-tap-probe").click()
      assert.equal(await page.evaluate(() => window.__f09RapidTapCount), 2)
    } finally {
      await context.close()
      await browser.close()
    }
  })

  test("F-09 Conversation preserves layout and draft across changing mobile viewport geometry", async () => {
    const browser = await chromium.launch({headless: true})
    const context = await browser.newContext({
      viewport: {width: 390, height: 844},
      isMobile: true,
      hasTouch: true,
      deviceScaleFactor: 2
    })
    const page = await context.newPage()

    async function assertConversationLayout(label) {
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

    try {
      await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
      await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
      await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
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
      await page.focus("#message-input")
      await page.waitForFunction(() => document.body.classList.contains("ig-keyboard-open"))
      await assertConversationLayout("portrait")

      // Height reduction is emulation of keyboard/browser-chrome pressure, not proof of a real virtual keyboard.
      await page.setViewportSize({width: 390, height: 520})
      await page.waitForTimeout(100)
      await assertConversationLayout("short portrait")

      await page.setViewportSize({width: 844, height: 390})
      await page.waitForTimeout(100)
      await assertConversationLayout("landscape")
      await page.screenshot({path: `${SCREENSHOT_DIR}/f09-dynamic-landscape.png`, fullPage: false})

      await page.setViewportSize({width: 390, height: 844})
      await page.waitForTimeout(100)
      await assertConversationLayout("portrait restored")
      await page.screenshot({path: `${SCREENSHOT_DIR}/f09-portrait-restored.png`, fullPage: false})
    } finally {
      await context.close()
      await browser.close()
    }
  })
}
