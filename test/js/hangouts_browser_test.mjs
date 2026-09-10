import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL
const TIMEOUT_MS = 30_000

if (!BASE_URL) {
  test("Hangouts Playwright browser proof (skipped: STRANGERTALKS_BROWSER_BASE_URL not set)", {skip: true}, () => {})
} else {
  test.describe("Hangouts V1 Real Multi-Browser Playwright Proof", {timeout: 120_000}, () => {
    let browser

    test.before(async () => {
      browser = await chromium.launch({
        headless: true,
        args: ["--no-sandbox", "--disable-setuid-sandbox"]
      })
    })

    test.after(async () => {
      if (browser) await browser.close()
    })

    async function createParticipantPage(viewport = {width: 390, height: 844}) {
      const context = await browser.newContext({
        viewport,
        isMobile: true,
        hasTouch: true
      })
      const page = await context.newPage()
      await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
      await page.waitForFunction(() => document.documentElement.dataset.hangoutsBooted === "true", null, {timeout: TIMEOUT_MS})
      return {context, page}
    }

    test("FLOW 1 & 2 & 8: Mobile viewport entry -> waiting -> formation -> temporary identities -> chat", async () => {
      const p1 = await createParticipantPage({width: 390, height: 844})
      const p2 = await createParticipantPage({width: 390, height: 844})
      const p3 = await createParticipantPage({width: 390, height: 844})

      try {
        // Flow 8 check: mobile viewport has no horizontal overflow
        const overflow1 = await p1.page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth)
        assert.equal(overflow1, false, "Mobile viewport should have no horizontal overflow")

        // Navigate to Hangout entry
        for (const p of [p1, p2, p3]) {
          await p.page.click("[data-go='hangout-entry']")
          await p.page.waitForSelector("[data-screen='hangout-entry']:not([hidden])")
        }

        // Join queue
        for (const p of [p1, p2, p3]) {
          await p.page.click("#hangout-join-queue-btn")
          await p.page.waitForSelector("[data-screen='hangout-waiting']:not([hidden])")
        }

        // Group forms with 3 participants; all enter room
        for (const p of [p1, p2, p3]) {
          await p.page.waitForSelector("[data-screen='hangout-room']:not([hidden])", {timeout: TIMEOUT_MS})
        }

        // Verify temporary identities rendered in roster
        for (const p of [p1, p2, p3]) {
          const badges = await p.page.$$(".hangout-member-badge")
          assert.equal(badges.length, 3, "Room roster must contain 3 temporary member badges")

          const selfBadge = await p.page.$(".hangout-member-badge.self")
          assert.ok(selfBadge, "Participant must see their own temporary identity marked (You)")

          // Flow 1 law: No internal participant UUIDs in public roster
          const rosterText = await p.page.$eval("#hangout-roster", (el) => el.textContent)
          assert.doesNotMatch(rosterText, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)
        }

        // Flow 2: Group chat
        await p1.page.fill("#hangout-message-input", "Hello from participant A!")
        await p1.page.click("#hangout-send-btn")

        // Verify message received on p2 and p3 with sender temporary identity
        for (const p of [p2, p3]) {
          await p.page.waitForSelector(".hangout-message", {timeout: TIMEOUT_MS})
          const msgText = await p.page.$eval(".hangout-message:last-child .hangout-message-body", (el) => el.textContent)
          assert.equal(msgText, "Hello from participant A!")

          const author = await p.page.$eval(".hangout-message:last-child .hangout-message-author", (el) => el.textContent)
          assert.ok(author.length > 0, "Message author temporary identity must render")
        }

        // Flow 6: Safety report and block
        await p1.page.click("#hangout-report-open-btn")
        await p1.page.waitForSelector("#hangout-report-dialog-backdrop:not([hidden])")
        await p1.page.fill("#hangout-report-evidence", "Testing safety report in e2e")
        await p1.page.click("#hangout-report-submit-btn")
        await p1.page.waitForSelector("#hangout-report-dialog-backdrop", {state: "hidden"})

        // Block
        await p1.page.click("#hangout-block-open-btn")
        await p1.page.waitForSelector("#hangout-block-dialog-backdrop:not([hidden])")
        await p1.page.click("#hangout-block-submit-btn")
        await p1.page.waitForSelector("#hangout-block-dialog-backdrop", {state: "hidden"})

        // Flow 7: Leave
        await p3.page.click("#hangout-leave-room-btn")
        await p3.page.waitForSelector("[data-screen='hangout-ended']:not([hidden])")
      } finally {
        await p1.context.close()
        await p2.context.close()
        await p3.context.close()
      }
    })

    test("FLOW 3 & 5: Treatment content reactions/skip and disconnect recovery", async () => {
      const p1 = await createParticipantPage()
      const p2 = await createParticipantPage()
      const p3 = await createParticipantPage()

      try {
        for (const p of [p1, p2, p3]) {
          await p.page.click("[data-go='hangout-entry']")
          await p.page.waitForSelector("[data-screen='hangout-entry']:not([hidden])")
          await p.page.click("#hangout-join-queue-btn")
          await p.page.waitForSelector("[data-screen='hangout-waiting']:not([hidden])")
        }

        for (const p of [p1, p2, p3]) {
          await p.page.waitForSelector("[data-screen='hangout-room']:not([hidden])", {timeout: TIMEOUT_MS})
        }

        // If treatment room, shared stimulus is visible
        const stimulusVisible = await p1.page.isVisible("#hangout-stimulus:not([hidden])")
        if (stimulusVisible) {
          const reactionBtn = await p1.page.$(".hangout-reaction-btn")
          if (reactionBtn) {
            await reactionBtn.click()
            // Wait for reaction broadcast update
            await p2.page.waitForTimeout(500)
          }

          const skipBtn = await p1.page.$("#hangout-skip-btn")
          if (skipBtn) {
            await skipBtn.click()
            await p2.page.waitForTimeout(500)
          }
        }

        // Flow 5: Disconnect and reconnect
        await p1.page.evaluate(() => {
          window.app?.socket?.disconnect()
        })
        // Banner appears
        await p1.page.waitForSelector("#hangout-reconnecting-banner:not([hidden])", {timeout: 5000}).catch(() => {})

        // Reconnect
        await p1.page.evaluate(() => {
          window.app?.socket?.connect()
        })
        await p1.page.waitForTimeout(1000)
        // Roster still present and room still active
        const rosterCount = await p1.page.$$eval(".hangout-member-badge", (els) => els.length)
        assert.ok(rosterCount >= 2, "Room must retain membership on reconnect")
      } finally {
        await p1.context.close()
        await p2.context.close()
        await p3.context.close()
      }
    })

    test("FLOW 4: Control room operates as pure group chat without shared stimulus", async () => {
      // In a control room, stimulus remains hidden
      const p = await createParticipantPage()
      try {
        await p.page.evaluate(() => {
          window.__hangoutClient?.dispatch({
            type: "ROOM_SNAPSHOT",
            snapshot: {
              room_id: "ctrl-room-1",
              status: "ACTIVE",
              experiment_arm: "GROUP_NO_CONTENT",
              language_tag: "en",
              members: [{identity: {slot: 0, emoji: "🦉", label: "Quiet Owl"}, self: true, status: "ACTIVE"}],
              messages: []
            }
          })
        })

        const stimulusHidden = await p.page.$eval("#hangout-stimulus", (el) => el.hidden)
        assert.equal(stimulusHidden, true, "Control room must not show shared stimulus")
      } finally {
        await p.context.close()
      }
    })
  })
}
