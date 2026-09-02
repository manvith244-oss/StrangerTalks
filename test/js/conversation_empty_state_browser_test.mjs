import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"

async function openSyntheticEmptyConversation(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForFunction(() => document.documentElement.dataset.instagramChatBooted === "true")
  await page.waitForFunction(() => document.querySelector("#doors")?.children.length > 0)
  await page.waitForTimeout(1000)
  await page.waitForFunction(() => document.querySelector('[data-screen="doors"]')?.classList.contains("active"))

  await page.evaluate(() => {
    document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
    document.querySelector('[data-screen="conversation"]')?.classList.add("active")
    document.querySelector("#messages")?.replaceChildren()
  })

  await page.waitForFunction(() => document.body.classList.contains("st-chat-mode"))
}

async function appendMessage(page, {mine, id}) {
  await page.evaluate(({mine, id}) => {
    const item = document.createElement("li")
    item.className = `message${mine ? " mine" : ""}`
    item.dataset.messageId = id
    item.textContent = mine ? "Hello from me" : "Hello from Stranger"
    document.querySelector("#messages")?.append(item)
  }, {mine, id})
}

test("zero-message Conversation shows an empty state that disappears for either sender", async () => {
  const browser = await chromium.launch({headless: true})
  const context = await browser.newContext({viewport: {width: 390, height: 844}, isMobile: true, hasTouch: true})
  const page = await context.newPage()

  try {
    await openSyntheticEmptyConversation(page)

    const empty = page.locator(".ig-conversation-empty")
    await empty.waitFor({state: "visible"})
    assert.match(await empty.textContent(), /No messages yet/i)
    assert.match(await empty.textContent(), /Say hello when you're ready/i)

    await appendMessage(page, {mine: false, id: "empty-state-peer"})
    await page.waitForFunction(() => !document.querySelector(".ig-conversation-empty"))

    await page.evaluate(() => document.querySelector("#messages")?.replaceChildren())
    await empty.waitFor({state: "visible"})

    await appendMessage(page, {mine: true, id: "empty-state-self"})
    await page.waitForFunction(() => !document.querySelector(".ig-conversation-empty"))
  } finally {
    await context.close()
    await browser.close()
  }
})
