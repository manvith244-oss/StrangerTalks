import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREENSHOTS = path.resolve("tmp/arrival-first-60-screenshots")
const VIEWPORTS = [
  {width: 320, height: 568},
  {width: 360, height: 740},
  {width: 390, height: 844},
  {width: 412, height: 915},
  {width: 844, height: 390},
  {width: 820, height: 1180},
  {width: 1024, height: 768},
  {width: 1440, height: 900}
]

async function openFresh(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  let participantId = null
  const errors = []
  const failedRequests = []

  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text())
  })
  page.on("requestfailed", request => failedRequests.push(`${request.method()} ${request.url()} ${request.failure()?.errorText || "failed"}`))
  page.on("response", async response => {
    if (new URL(response.url()).pathname !== "/api/participants" || !response.ok()) return
    try {
      participantId = (await response.json()).participant_id || null
    } catch (_error) {}
  })

  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("button.door").first().waitFor({state: "visible"})

  return {context, page, errors, failedRequests, participantId: () => participantId}
}

async function waitForQueue(page) {
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: 12_000})
  await page.getByRole("status").filter({hasText: "Queue status: queued"}).waitFor({state: "visible", timeout: 12_000})
}

async function leaveQueue(page) {
  await page.locator("#leave-queue").click()
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: 12_000})
}

async function assertNoHorizontalOverflow(page, label) {
  const dimensions = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    scrollWidth: document.documentElement.scrollWidth,
    bodyScrollWidth: document.body.scrollWidth
  }))
  assert.ok(dimensions.scrollWidth <= dimensions.innerWidth + 1, `${label}: document does not overflow horizontally`)
  assert.ok(dimensions.bodyScrollWidth <= dimensions.innerWidth + 1, `${label}: body does not overflow horizontally`)
}

async function assertPrimaryControlReachable(page, selector, label) {
  const box = await page.locator(selector).boundingBox()
  assert.ok(box, `${label}: primary control is rendered`)
  const viewport = page.viewportSize()
  assert.ok(box.x >= -1 && box.x + box.width <= viewport.width + 1, `${label}: primary control fits horizontally`)
  assert.ok(box.y >= -1 && box.y < viewport.height, `${label}: primary control begins inside viewport`)
}

test("first visit is self-explanatory and missing language cannot silently enter queue", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let fresh
  try {
    fresh = await openFresh(browser)
    const {page} = fresh

    await page.getByText("Anonymous, one-to-one conversation with another person. No profile required.").waitFor({state: "visible"})
    assert.equal(await page.locator("button.door").count(), 4)
    assert.equal(await page.locator("#conversation-language").inputValue(), "")

    await page.getByRole("button", {name: /Advice/}).click()
    await page.getByText("Choose a Conversation Language before picking a Door.").waitFor({state: "visible"})
    assert.equal(await page.locator('section[data-screen="doors"]').getAttribute("class").then(value => value.includes("active")), true)
    assert.equal(await page.locator("#conversation-language").getAttribute("aria-invalid"), "true")
    assert.equal(await page.evaluate(() => document.activeElement?.id), "conversation-language")

    await page.locator("#conversation-language").selectOption("en")
    assert.equal(await page.locator("#conversation-language").getAttribute("aria-invalid"), null)
    await page.getByRole("button", {name: /Advice/}).click()
    await waitForQueue(page)
    await page.waitForFunction(() => document.activeElement === document.querySelector('section[data-screen="queue"] h1'))
    await assertNoHorizontalOverflow(page, "390x844 queue")

    await leaveQueue(page)
    await page.waitForFunction(() => document.activeElement === document.querySelector('section[data-screen="doors"] h1'))
    assert.deepEqual(fresh.errors, [])
    assert.deepEqual(fresh.failedRequests, [])
  } finally {
    await fresh?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("participant bootstrap failure becomes a visible recoverable state", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    await context.route("**/api/participants", async route => {
      await route.fulfill({status: 503, contentType: "application/json", body: JSON.stringify({error: "intentional_test_failure"})})
    })
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), "root shell still loads")

    const panel = page.locator("#arrival-startup-failure")
    await panel.waitFor({state: "visible", timeout: 12_000})
    await panel.getByRole("heading", {name: "StrangerTalks couldn't connect"}).waitFor({state: "visible"})
    await panel.getByRole("button", {name: "Retry"}).waitFor({state: "visible"})
    assert.equal(await page.locator("#conversation-language").isDisabled(), true)
    assert.equal(await page.locator("button.door:not([disabled])").count(), 0)
    assert.equal(await page.evaluate(() => document.activeElement?.textContent), "Retry")
  } finally {
    await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("required device matrix can enter and leave matchmaking without squeezed or unreachable UI", {timeout: 150_000}, async () => {
  fs.mkdirSync(SCREENSHOTS, {recursive: true})
  const browser = await chromium.launch({headless: true})

  try {
    for (const viewport of VIEWPORTS) {
      const label = `${viewport.width}x${viewport.height}`
      const fresh = await openFresh(browser, viewport)
      try {
        const {page} = fresh
        await assertNoHorizontalOverflow(page, `${label} arrival`)
        await assertPrimaryControlReachable(page, "#conversation-language", `${label} arrival`)
        await page.locator("#conversation-language").selectOption("en")
        await page.getByRole("button", {name: /Distract/}).click()
        await waitForQueue(page)
        await assertNoHorizontalOverflow(page, `${label} queue`)
        await assertPrimaryControlReachable(page, "#leave-queue", `${label} queue`)
        await page.screenshot({path: path.join(SCREENSHOTS, `${label}-queue.png`), fullPage: true})
        await leaveQueue(page)
        assert.deepEqual(fresh.errors, [], `${label}: no browser/console errors`)
        assert.deepEqual(fresh.failedRequests, [], `${label}: no failed requests`)
      } finally {
        await fresh.context.close().catch(() => {})
      }
    }
  } finally {
    await browser.close().catch(() => {})
  }
})

test("two isolated fresh participants reach one usable Conversation and can talk", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b

  try {
    a = await openFresh(browser, {width: 390, height: 844})
    b = await openFresh(browser, {width: 390, height: 844})
    await a.page.locator("#conversation-language").selectOption("en")
    await b.page.locator("#conversation-language").selectOption("en")

    await a.page.getByRole("button", {name: /Deep Talk/}).click()
    await waitForQueue(a.page)
    await b.page.getByRole("button", {name: /Deep Talk/}).click()

    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 20_000}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: 20_000})
    ])

    const text = `Team 1 handoff ${Date.now()}`
    const inputA = a.page.locator("#message-input")
    const inputB = b.page.locator("#message-input")
    assert.equal(await inputA.isVisible(), true)
    assert.equal(await inputA.isEnabled(), true)
    assert.equal(await inputB.isVisible(), true)
    assert.equal(await inputB.isEnabled(), true)

    await inputA.fill(text)
    await a.page.locator("#message-form").getByRole("button", {name: "Send"}).click()
    await b.page.locator("#messages").getByText(text, {exact: true}).waitFor({state: "visible", timeout: 12_000})

    for (const participant of [a, b]) {
      const participantId = participant.participantId()
      if (participantId) {
        assert.equal((await participant.page.locator("body").innerText()).includes(participantId), false, "participant UUID is not exposed in UI")
      }
      await assertNoHorizontalOverflow(participant.page, "usable Conversation handoff")
      assert.deepEqual(participant.errors, [])
      assert.deepEqual(participant.failedRequests, [])
    }
  } finally {
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})