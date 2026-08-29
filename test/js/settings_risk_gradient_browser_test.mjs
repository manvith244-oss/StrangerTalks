import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const WAIT = 15_000
const DOORS = ["Deep Talk", "Vent", "Distract", "Advice"]

async function boot(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()) })
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
  await page.waitForFunction(() => document.querySelectorAll("#doors .door").length === 4)
  return {context, page, errors}
}

async function openSettings(page) {
  await page.locator('#bottom-nav [data-go="settings"]').click()
  await page.locator('section[data-screen="settings"].active').waitFor({state: "visible", timeout: WAIT})
}

async function returnToSettingsAfterQueue(page, door) {
  await page.locator("#conversation-language").selectOption("en")
  await page.getByRole("button", {name: new RegExp(door)}).click()
  await page.locator('section[data-screen="queue"].active').waitFor({state: "visible", timeout: WAIT})
  await page.locator("#leave-queue").waitFor({state: "visible", timeout: WAIT})
  await page.locator("#leave-queue").click()
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
  await openSettings(page)
}

test("Memory Space and Private Reflections are reachable and return to Settings", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const app = await boot(browser)
  try {
    await openSettings(app.page)
    for (const [name, screen] of [["Memory Space", "memories"], ["Private Reflections", "reflections"]]) {
      await app.page.getByRole("button", {name: new RegExp(name)}).click()
      await app.page.locator(`section[data-screen="${screen}"].active`).waitFor({state: "visible", timeout: WAIT})
      await app.page.getByRole("button", {name: "← Back to You"}).click()
      await app.page.locator('section[data-screen="settings"].active').waitFor({state: "visible", timeout: WAIT})
    }
    assert.deepEqual(app.errors, [])
  } finally {
    await app.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Settings stays neutral after every Door queue visit", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const app = await boot(browser)
  try {
    for (const door of DOORS) {
      await returnToSettingsAfterQueue(app.page, door)
      const presentation = await app.page.locator('section[data-screen="settings"]').evaluate(section => {
        const body = getComputedStyle(document.body)
        const suggestion = getComputedStyle(document.querySelector("#continuity-suggestion"))
        return {
          bodyBackgroundImage: body.backgroundImage,
          sectionBackgroundImage: getComputedStyle(section).backgroundImage,
          suggestionBorder: suggestion.borderLeftColor,
          doorTokens: ["--st-deep-talk", "--st-vent", "--st-distract", "--st-advice"].map(token => getComputedStyle(document.documentElement).getPropertyValue(token).trim())
        }
      })
      assert.equal(presentation.bodyBackgroundImage, "none", `${door}: Settings body has no atmospheric gradient`)
      assert.equal(presentation.sectionBackgroundImage, "none", `${door}: Settings section has no atmospheric gradient`)
      assert.equal(presentation.doorTokens.includes(presentation.suggestionBorder), false, `${door}: continuity cue does not use a Door color`)
      await app.page.locator('#bottom-nav [data-go="doors"]').click()
      await app.page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT})
    }
    assert.deepEqual(app.errors, [])
  } finally {
    await app.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("danger actions are isolated and confirmations state consequences and recovery", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const app = await boot(browser, {width: 1280, height: 800})
  try {
    await openSettings(app.page)
    const structure = await app.page.evaluate(() => ({
      deleteSection: document.querySelector("#delete-all")?.closest("[data-settings-section]")?.dataset.settingsSection,
      syncDeleteSection: document.querySelector("#sync-delete")?.closest("[data-settings-section]")?.dataset.settingsSection,
      exportSection: document.querySelector("#export-data")?.closest("[data-settings-section]")?.dataset.settingsSection,
      sameParent: document.querySelector("#delete-all")?.parentElement === document.querySelector("#export-data")?.parentElement,
      deleteClass: document.querySelector("#delete-all")?.className
    }))
    assert.equal(structure.deleteSection, "danger-zone")
    assert.equal(structure.syncDeleteSection, "danger-zone")
    assert.equal(structure.exportSection, "privacy-local-data")
    assert.equal(structure.sameParent, false)
    assert.match(structure.deleteClass, /danger-action/)

    const dialogMessage = new Promise(resolve => app.page.once("dialog", async dialog => {
      resolve(dialog.message())
      await dialog.dismiss()
    }))
    await app.page.locator("#delete-all").click()
    assert.match(await dialogMessage, /Delete all local StrangerTalks data.*cannot be undone.*exported backup/is)
    assert.deepEqual(app.errors, [])
  } finally {
    await app.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("every visible Settings control is reachable by keyboard in DOM order", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const app = await boot(browser, {width: 1280, height: 800})
  try {
    await openSettings(app.page)
    const settings = app.page.locator('section[data-screen="settings"]')
    const controls = settings.locator('button:not([hidden]):visible, input:not([hidden]):visible')
    const count = await controls.count()
    assert.ok(count >= 8, "guest Settings exposes its routine controls")

    await controls.first().focus()
    for (let index = 0; index < count; index += 1) {
      const control = controls.nth(index)
      assert.equal(await control.evaluate(node => node === document.activeElement), true, `control ${index + 1} receives focus`)
      if (index < count - 1) await app.page.keyboard.press("Tab")
    }
    assert.deepEqual(app.errors, [])
  } finally {
    await app.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Settings remains responsive at mobile, 992px, desktop, and 200 percent zoom", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const app = await boot(browser)
  try {
    await openSettings(app.page)
    for (const viewport of [{width: 390, height: 844}, {width: 992, height: 800}, {width: 1440, height: 900}]) {
      await app.page.setViewportSize(viewport)
      const geometry = await app.page.locator('section[data-screen="settings"]').evaluate(section => ({
        viewport: innerWidth,
        documentWidth: document.documentElement.scrollWidth,
        columns: getComputedStyle(section.querySelector(".settings-sections")).gridTemplateColumns,
        targetHeights: [...section.querySelectorAll("button, .settings-toggle, .settings-file-control")]
          .filter(node => !node.hidden && node.getClientRects().length > 0)
          .map(node => node.getBoundingClientRect().height)
      }))
      assert.ok(geometry.documentWidth <= geometry.viewport + 1, `${viewport.width}px has no horizontal overflow`)
      assert.ok(geometry.targetHeights.length > 0)
      assert.ok(Math.min(...geometry.targetHeights) >= 44, `${viewport.width}px controls preserve 44px targets`)
    }

    await app.page.evaluate(() => { document.documentElement.style.zoom = "2" })
    const zoomed = await app.page.evaluate(() => ({viewport: innerWidth, documentWidth: document.documentElement.scrollWidth}))
    assert.ok(zoomed.documentWidth <= zoomed.viewport + 1, "200% zoom has no horizontal overflow")
    assert.deepEqual(app.errors, [])
  } finally {
    await app.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
