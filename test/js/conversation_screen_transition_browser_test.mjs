import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4003"

function secondsList(value) {
  return String(value || "0s").split(",").map((part) => {
    const item = part.trim()
    if (item.endsWith("ms")) return Number.parseFloat(item) / 1000
    return Number.parseFloat(item) || 0
  })
}

async function openApp(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => !document.body.classList.contains("flow-booting"))
  await page.waitForTimeout(150)
}

async function transition(page, from, to) {
  await page.evaluate(({from, to}) => {
    document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
    document.querySelector(`[data-screen="${from}"]`)?.classList.add("active")
    void document.querySelector(`[data-screen="${from}"]`)?.offsetWidth
    document.querySelector(`[data-screen="${from}"]`)?.classList.remove("active")
    document.querySelector(`[data-screen="${to}"]`)?.classList.add("active")
  }, {from, to})

  await page.waitForTimeout(35)
  return page.evaluate(({from, to}) => {
    const outgoing = document.querySelector(`[data-screen="${from}"]`)
    const incoming = document.querySelector(`[data-screen="${to}"]`)
    const outStyle = getComputedStyle(outgoing)
    const inStyle = getComputedStyle(incoming)
    return {
      outgoingDisplay: outStyle.display,
      outgoingOpacity: Number.parseFloat(outStyle.opacity),
      incomingDisplay: inStyle.display,
      incomingOpacity: Number.parseFloat(inStyle.opacity),
      incomingTransitionProperty: inStyle.transitionProperty,
      incomingTransitionDuration: inStyle.transitionDuration,
      incomingTransitionBehavior: inStyle.transitionBehavior
    }
  }, {from, to})
}

function assertFastScreenMotion(state, label) {
  assert.notEqual(state.outgoingDisplay, "none", `${label}: outgoing screen should remain renderable during its exit motion`)
  assert.equal(state.incomingDisplay, "block", `${label}: incoming screen should be presented during enter motion`)
  assert.ok(state.outgoingOpacity < 1 && state.outgoingOpacity >= 0, `${label}: outgoing screen should be fading, got ${state.outgoingOpacity}`)
  assert.ok(state.incomingOpacity > 0 && state.incomingOpacity < 1, `${label}: incoming screen should be fading in, got ${state.incomingOpacity}`)
  assert.match(state.incomingTransitionProperty, /opacity/)
  assert.match(state.incomingTransitionProperty, /transform/)
  assert.match(state.incomingTransitionProperty, /display/)
  const durations = secondsList(state.incomingTransitionDuration)
  assert.ok(durations.some((duration) => duration > 0), `${label}: transition duration must be non-zero`)
  assert.ok(durations.every((duration) => duration < 0.2), `${label}: every transition must stay under 200ms, got ${state.incomingTransitionDuration}`)
  assert.match(state.incomingTransitionBehavior, /allow-discrete/, `${label}: display must transition discretely so exit motion can finish`)
}

test("matchmaking → Conversation and Conversation → ended use fast enter/exit motion with reduced-motion collapse", async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    await openApp(page)

    const enteringConversation = await transition(page, "queue", "conversation")
    assertFastScreenMotion(enteringConversation, "matchmaking → Conversation")
    await page.waitForTimeout(190)
    assert.equal(await page.locator('[data-screen="queue"]').evaluate((node) => getComputedStyle(node).display), "none")

    const leavingConversation = await transition(page, "conversation", "ended")
    assertFastScreenMotion(leavingConversation, "Conversation → ended")
    await page.waitForTimeout(190)
    assert.equal(await page.locator('[data-screen="conversation"]').evaluate((node) => getComputedStyle(node).display), "none")

    await page.emulateMedia({reducedMotion: "reduce"})
    await page.evaluate(() => {
      document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
      document.querySelector('[data-screen="queue"]')?.classList.add("active")
    })
    const reduced = await page.locator('[data-screen="queue"]').evaluate((node) => getComputedStyle(node).transitionDuration)
    assert.ok(secondsList(reduced).every((duration) => duration <= 0.001), `reduced-motion transition should collapse, got ${reduced}`)
  } finally {
    await context.close()
    await browser.close()
  }
})
