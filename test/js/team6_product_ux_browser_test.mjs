import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/team6-product-ux-screenshots")
const DEVICES = [
  {name: "320x568", width: 320, height: 568, mobile: true},
  {name: "360x740", width: 360, height: 740, mobile: true},
  {name: "390x844", width: 390, height: 844, mobile: true},
  {name: "412x915", width: 412, height: 915, mobile: true},
  {name: "844x390", width: 844, height: 390, mobile: true},
  {name: "820x1180", width: 820, height: 1180, mobile: true},
  {name: "1440x900", width: 1440, height: 900, mobile: false}
]

fs.mkdirSync(SCREENSHOTS, {recursive: true})

async function openPage(browser, device = DEVICES[2], extra = {}) {
  const context = await browser.newContext({
    viewport: {width: device.width, height: device.height},
    isMobile: device.mobile,
    hasTouch: device.mobile,
    deviceScaleFactor: device.mobile ? 2 : 1,
    ...extra
  })
  const page = await context.newPage()
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()) })
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator("button.door").first().waitFor({state: "visible", timeout: 15_000})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  return {context, page, errors}
}

async function assertNoOverflow(page, label) {
  const metrics = await page.evaluate(() => ({
    width: innerWidth,
    html: document.documentElement.scrollWidth,
    body: document.body.scrollWidth
  }))
  assert.ok(metrics.html <= metrics.width + 1, `${label}: html horizontal overflow ${metrics.html - metrics.width}px`)
  assert.ok(metrics.body <= metrics.width + 1, `${label}: body horizontal overflow ${metrics.body - metrics.width}px`)
}

async function fixtureConversation(page) {
  await page.waitForTimeout(900)
  await page.evaluate(() => {
    document.querySelectorAll("[data-screen]").forEach(screen => screen.classList.remove("active"))
    document.querySelector('[data-screen="conversation"]')?.classList.add("active")
    const expressive = document.querySelector("#expressive-composer")
    if (expressive) expressive.hidden = false
    const list = document.querySelector("#messages")
    list.replaceChildren()
    const rows = [
      [false, "A calm hello from the other person."],
      [true, "Hey — good to meet you here."],
      [false, `Long link: https://example.com/${"unbroken-segment-".repeat(16)}`],
      [true, "A short reply ✨"]
    ]
    rows.forEach(([mine, text], index) => {
      const li = document.createElement("li")
      li.className = `message${mine ? " mine" : ""}`
      li.dataset.messageId = `team6-${index}`
      li.tabIndex = 0
      const span = document.createElement("span")
      span.className = "message-content"
      span.textContent = text
      li.append(span)
      list.append(li)
    })
  })
  await page.waitForFunction(() => document.body.classList.contains("st-chat-mode"))
  await page.waitForFunction(() => document.querySelector("#messages > .message.ig-group-solo, #messages > .message.ig-group-start"))
}

async function hideOverlayStates(page) {
  await page.evaluate(() => {
    for (const selector of ["#live-call-incoming", "#live-call-active", "#report-form", "#view-once-preview", "#voice-warning", "#voice-preview"]) {
      const node = document.querySelector(selector)
      if (node) node.hidden = true
    }
    const details = document.querySelector(".conversation-head-actions .overflow")
    if (details) details.open = false
  })
}

test("Arrival language, Queue and human-facing labels are truthful", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openPage(browser)
    const {page} = session
    await page.screenshot({path: path.join(SCREENSHOTS, "390x844-arrival.png"), fullPage: true})
    await page.getByRole("button", {name: /Advice/}).click()
    await page.getByText("Choose a Conversation Language before picking a Door.").waitFor({state: "visible"})
    assert.equal(await page.locator("#conversation-language").getAttribute("aria-invalid"), "true")
    await page.locator("#conversation-language").selectOption("en")
    await page.getByRole("button", {name: /Advice/}).click()
    await page.locator('[data-screen="queue"].active').waitFor({state: "visible", timeout: 12_000})
    assert.equal((await page.locator("#leave-queue").innerText()).trim(), "Leave Queue")
    await page.screenshot({path: path.join(SCREENSHOTS, "390x844-queue.png"), fullPage: true})
    await assertNoOverflow(page, "Queue")
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Conversation presentation stays usable across the seven release viewports", {timeout: 180_000}, async () => {
  const browser = await chromium.launch({headless: true})
  try {
    for (const device of DEVICES) {
      const session = await openPage(browser, device)
      try {
        const {page} = session
        await fixtureConversation(page)
        await assertNoOverflow(page, `${device.name} conversation`)
        const geometry = await page.evaluate(() => {
          const composer = document.querySelector("#message-form").getBoundingClientRect()
          const head = document.querySelector(".conversation-head").getBoundingClientRect()
          const targets = ["#btn-voice-call", "#btn-video-call", ".conversation-head-actions .overflow summary", ".ig-compose-plus", "#voice-start"]
            .map(selector => document.querySelector(selector)?.getBoundingClientRect())
            .filter(Boolean)
          return {composerBottom: composer.bottom, headBottom: head.bottom, targets: targets.map(rect => Math.min(rect.width, rect.height))}
        })
        assert.ok(geometry.composerBottom <= device.height + 1, `${device.name}: composer remains visible`)
        const floor = device.mobile ? 44 : 40
        for (const size of geometry.targets) assert.ok(size >= floor, `${device.name}: critical target ${size}px < ${floor}px`)
        await page.screenshot({path: path.join(SCREENSHOTS, `${device.name}-conversation.png`), fullPage: false})

        await page.locator(".ig-compose-plus").click()
        await page.locator("#ig-message-tools").waitFor({state: "visible"})
        await assertNoOverflow(page, `${device.name} tools tray`)
        if (["320x568", "844x390", "1440x900"].includes(device.name)) {
          await page.screenshot({path: path.join(SCREENSHOTS, `${device.name}-tools.png`), fullPage: false})
        }
        assert.deepEqual(session.errors, [], `${device.name}: no browser errors`)
      } finally {
        await session.context.close().catch(() => {})
      }
    }
  } finally {
    await browser.close().catch(() => {})
  }
})

test("ephemeral choice, expressive media and Report presentation tell the truth", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openPage(browser)
    const {page} = session
    await fixtureConversation(page)

    await page.locator(".ig-compose-plus").click()
    const expressive = page.locator("#expressive-open")
    assert.match((await expressive.innerText()).trim(), /Stickers|Expressions/)
    assert.doesNotMatch((await expressive.innerText()).trim(), /GIF/i)
    await expressive.click()
    await page.locator("#expressive-picker").waitFor({state: "visible"})
    assert.doesNotMatch(await page.locator("#expressive-picker").getAttribute("aria-label"), /GIF/i)
    await page.screenshot({path: path.join(SCREENSHOTS, "390x844-expressions.png"), fullPage: false})
    await page.keyboard.press("Escape")

    await page.evaluate(() => { document.querySelector("#view-once-preview").hidden = false })
    await page.getByText("View Once can be opened one time. View Twice can be opened up to two times.").waitFor({state: "visible"})
    await page.screenshot({path: path.join(SCREENSHOTS, "390x844-view-once-twice.png"), fullPage: false})
    await hideOverlayStates(page)

    await page.locator(".conversation-head-actions .overflow summary").click()
    await page.locator("#report-open").click()
    await page.locator("#report-form").waitFor({state: "visible"})
    const labels = await page.locator("#report-category option").allTextContents()
    assert.deepEqual(labels.map(x => x.trim()), ["Choose…", "Spam", "Harassment", "Sexual misconduct", "Malicious links", "Threats"])
    assert.equal(await page.locator("#report-cancel").isVisible(), true)
    await page.screenshot({path: path.join(SCREENSHOTS, "390x844-report.png"), fullPage: false})
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("call states are visibly distinct and short-screen panels remain escapable", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openPage(browser, DEVICES[4])
    const {page} = session
    await fixtureConversation(page)

    await page.evaluate(() => { document.querySelector("#live-call-incoming").hidden = false })
    await page.screenshot({path: path.join(SCREENSHOTS, "844x390-call-incoming.png"), fullPage: false})
    const incoming = await page.locator("#live-call-incoming").boundingBox()
    assert.ok(incoming && incoming.y >= -1 && incoming.y + incoming.height <= 391)

    await page.evaluate(() => {
      document.querySelector("#live-call-incoming").hidden = true
      document.querySelector("#live-call-active").hidden = false
      document.querySelector("#live-call-status").textContent = "Connecting…"
    })
    assert.equal((await page.locator("#live-call-status").innerText()).trim(), "Connecting…")
    await page.screenshot({path: path.join(SCREENSHOTS, "844x390-call-connecting.png"), fullPage: false})

    await page.evaluate(() => { document.querySelector("#live-call-status").textContent = "Call Active" })
    assert.equal((await page.locator("#live-call-status").innerText()).trim(), "Call Active")
    await page.screenshot({path: path.join(SCREENSHOTS, "844x390-call-active.png"), fullPage: false})
    await assertNoOverflow(page, "landscape call")
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("keyboard, Escape, reduced motion, forced contrast and 200 percent zoom retain core access", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let session
  try {
    session = await openPage(browser, DEVICES[2], {reducedMotion: "reduce", forcedColors: "active"})
    const {page} = session
    await fixtureConversation(page)
    assert.equal(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches), true)

    const info = page.locator(".conversation-head-actions .overflow summary")
    await info.focus()
    await page.keyboard.press("Enter")
    await page.keyboard.press("Escape")
    assert.equal(await page.evaluate(() => document.activeElement?.getAttribute("aria-label")), "Conversation info and safety")

    const input = page.locator("#message-input")
    await input.focus()
    await input.fill("One\nTwo\nThree\nFour")
    await page.setViewportSize({width: 390, height: 520})
    await page.waitForTimeout(100)
    const composer = await page.locator("#message-form").boundingBox()
    assert.ok(composer && composer.y < 520 && composer.y + Math.min(composer.height, 80) <= 521, "composer remains reachable after visual-height squeeze")
    await assertNoOverflow(page, "keyboard-size viewport")

    const cdp = await session.context.newCDPSession(page)
    await cdp.send("Emulation.setPageScaleFactor", {pageScaleFactor: 2})
    await assertNoOverflow(page, "200% zoom")
    assert.equal(await page.locator("#message-input").isVisible(), true)
    assert.deepEqual(session.errors, [])
  } finally {
    await session?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
