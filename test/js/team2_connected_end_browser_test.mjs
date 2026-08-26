import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4000"

async function prepareUiPage(page) {
  await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  await page.waitForSelector("#conversation-language")
  await page.waitForFunction(() => document.querySelectorAll(".door").length >= 4)
  await page.selectOption("#conversation-language", "en")
}

async function uiJoinQueue(page) {
  await page.click('.door[data-door="JUST_TALK"]')
}

async function uiWaitForConversation(page) {
  await page.waitForSelector('section[data-screen="conversation"].active', {timeout: 15_000})
}

async function uiWaitForEnded(page) {
  await page.waitForSelector('section[data-screen="ended"].active', {timeout: 15_000})
}

async function uiMatch(pageA, pageB) {
  await Promise.all([prepareUiPage(pageA), prepareUiPage(pageB)])
  await Promise.all([uiJoinQueue(pageA), uiJoinQueue(pageB)])
  await Promise.all([uiWaitForConversation(pageA), uiWaitForConversation(pageB)])
}

async function sendAndObserve(sender, receiver, content) {
  await sender.fill("#message-input", content)
  await sender.press("#message-input", "Enter")
  await receiver.waitForFunction(
    (wanted) => Array.from(document.querySelectorAll("#messages .message")).some((node) => node.textContent.includes(wanted)),
    content,
    {timeout: 10_000}
  )
}

test("connected two-browser normal End converges both clients and releases later product flow", {timeout: 70_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const contextA = await browser.newContext()
  const contextB = await browser.newContext()
  const contextC = await browser.newContext()
  const pageA = await contextA.newPage()
  const pageB = await contextB.newPage()
  let pageC = null

  try {
    await uiMatch(pageA, pageB)

    await sendAndObserve(pageA, pageB, "TEAM2-A-BEFORE-END")
    await sendAndObserve(pageB, pageA, "TEAM2-B-BEFORE-END")

    await pageA.click("details.overflow > summary")
    await pageA.click("#end-conversation")
    await pageA.waitForSelector("#end-confirmation-backdrop:not([hidden])")
    await pageA.click("#end-confirm")

    await Promise.all([uiWaitForEnded(pageA), uiWaitForEnded(pageB)])

    for (const page of [pageA, pageB]) {
      assert.equal(
        await page.locator('section[data-screen="conversation"]').evaluate((node) => node.classList.contains("active")),
        false
      )
      assert.equal(await page.locator("#message-form").isVisible(), false)
      assert.equal(await page.locator("#end-conversation").isVisible(), false)
    }

    // The terminal Conversation must not leave A participant_busy forever.
    // A dismisses terminal UI and immediately enters a later valid Conversation with C.
    await pageA.click("#fade-conversation")
    await pageA.waitForSelector('section[data-screen="doors"].active')
    await pageA.selectOption("#conversation-language", "en")

    pageC = await contextC.newPage()
    await prepareUiPage(pageC)
    await Promise.all([uiJoinQueue(pageA), uiJoinQueue(pageC)])
    await Promise.all([uiWaitForConversation(pageA), uiWaitForConversation(pageC)])

    await sendAndObserve(pageA, pageC, "TEAM2-LATER-FLOW")
  } finally {
    if (pageC) await pageC.close()
    await contextA.close()
    await contextB.close()
    await contextC.close()
    await browser.close()
  }
})
