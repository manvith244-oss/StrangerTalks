import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"

function seconds(value) {
  const first = String(value || "0s").split(",")[0].trim()
  if (first.endsWith("ms")) return Number.parseFloat(first) / 1000
  return Number.parseFloat(first) || 0
}

async function openConversation(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
  await page.waitForTimeout(1000)
  await page.evaluate(() => {
    document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
    document.querySelector('[data-screen="conversation"]')?.classList.add("active")
    document.querySelector("#messages")?.replaceChildren()
  })
  await page.waitForFunction(() => document.body.classList.contains("st-chat-mode"))
}

async function appendMessage(page, {id, mine}) {
  return page.evaluate(({id, mine}) => {
    const item = document.createElement("li")
    item.className = `message${mine ? " mine" : ""}`
    item.dataset.messageId = id
    const text = document.createElement("span")
    text.className = "message-content"
    text.textContent = mine ? "Outgoing arrival" : "Incoming arrival"
    item.append(text)
    document.querySelector("#messages").append(item)

    const style = getComputedStyle(item)
    return {
      animationName: style.animationName,
      animationDuration: style.animationDuration
    }
  }, {id, mine})
}

test("new incoming and outgoing bubbles use the same fast arrival motion and reduced motion collapses it", async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}})
  const page = await context.newPage()

  try {
    await openConversation(page)

    const incoming = await appendMessage(page, {id: "arrival-incoming", mine: false})
    const outgoing = await appendMessage(page, {id: "arrival-outgoing", mine: true})

    assert.notEqual(incoming.animationName, "none", "incoming bubble should animate on append")
    assert.equal(outgoing.animationName, incoming.animationName, "incoming and outgoing bubbles should share one arrival motion")
    assert.ok(seconds(incoming.animationDuration) > 0, `arrival duration must be non-zero, got ${incoming.animationDuration}`)
    assert.ok(seconds(incoming.animationDuration) < 0.2, `arrival duration must stay under 200ms, got ${incoming.animationDuration}`)
    assert.equal(outgoing.animationDuration, incoming.animationDuration)

    await page.emulateMedia({reducedMotion: "reduce"})
    const reduced = await appendMessage(page, {id: "arrival-reduced", mine: false})
    assert.ok(seconds(reduced.animationDuration) <= 0.001, `reduced-motion duration should collapse, got ${reduced.animationDuration}`)
  } finally {
    await context.close()
    await browser.close()
  }
})
