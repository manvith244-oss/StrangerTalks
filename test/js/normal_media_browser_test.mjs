import assert from "node:assert/strict"
import test from "node:test"
import {execFileSync} from "node:child_process"
import {mkdirSync, rmSync} from "node:fs"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREEN_DIR = "/tmp/team9-normal-media-browser"
const WAIT_MS = 12_000

function validJpeg() {
  const sof0Payload = Buffer.from([8, 0, 100, 0, 100, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0])
  const sof0Len = sof0Payload.length + 2
  return Buffer.concat([
    Buffer.from([0xff, 0xd8, 0xff, 0xc0, (sof0Len >> 8) & 0xff, sof0Len & 0xff]),
    sof0Payload,
    Buffer.from([0xff, 0xda, 0, 8, 1, 1, 0, 0, 0x3f, 0, 0x12, 0x34, 0xff, 0xd9])
  ])
}

function makeVideo(path) {
  execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "color=c=black:s=160x120:d=0.8",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
    "-an", path
  ])
}

async function boot(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  const pageErrors = []
  page.on("pageerror", (error) => pageErrors.push(error.message))
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT_MS})
  await page.locator("#conversation-language").selectOption("en")
  await page.locator("#normal-media-picker-btn").waitFor({state: "attached", timeout: WAIT_MS})
  return {context, page, pageErrors}
}

async function matchPair(browser, viewportA, viewportB) {
  const a = await boot(browser, viewportA)
  const b = await boot(browser, viewportB)
  await a.page.locator('button.door:has-text("Advice")').click()
  await b.page.locator('button.door:has-text("Advice")').click()
  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
  ])
  return {a, b}
}

async function chooseMedia(page, {name, mimeType, buffer}) {
  await page.locator("#normal-media-file-input").setInputFiles({name, mimeType, buffer})
  await page.locator("#normal-media-preview").waitFor({state: "visible", timeout: WAIT_MS})
}

async function sendNormal(page) {
  await page.locator("#normal-media-send").click()
}

async function waitForPeerMedia(page, kind) {
  const card = page.locator(`.normal-media-message:not(.mine) .normal-media-card`, {hasText: kind === "video" ? "Video" : "Photo"})
  await card.waitFor({state: "visible", timeout: WAIT_MS})
  return card
}

async function endConversation(page) {
  const details = page.locator("details.overflow")
  if ((await details.getAttribute("open")) === null) await details.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible", timeout: WAIT_MS})
  await page.locator("#end-confirm").click()
  await page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT_MS})
}

async function fadeToDoors(page) {
  await page.locator("#fade-conversation").click()
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT_MS})
  await page.locator("#conversation-language").selectOption("en")
}

function assertNoPageErrors(...participants) {
  for (const participant of participants) assert.deepEqual(participant.pageErrors, [])
}

mkdirSync(SCREEN_DIR, {recursive: true})

test("photo choose → preview → send → peer open → close → reopen → reconnect", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {width: 320, height: 568}, {width: 390, height: 844})
    const {a, b} = pair

    await chooseMedia(a.page, {name: "private-name-should-not-leak.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    assert.match(await a.page.locator("#normal-media-preview-status").textContent(), /Photo ready/)
    assert.equal(await a.page.locator("#normal-media-preview-container img").count(), 1)
    await a.page.screenshot({path: `${SCREEN_DIR}/photo-preview-320x568.png`, fullPage: true})

    await sendNormal(a.page)
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})
    const peerCard = await waitForPeerMedia(b.page, "photo")
    assert.equal((await peerCard.textContent()).includes("private-name-should-not-leak.jpg"), false)

    const open = peerCard.getByRole("button", {name: "Open photo"})
    await open.click()
    await b.page.locator("#normal-media-viewer").waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(await b.page.locator("#normal-media-viewer img").count(), 1)
    await b.page.locator("#normal-media-viewer-close").click()
    await b.page.locator("#normal-media-viewer").waitFor({state: "hidden", timeout: WAIT_MS})
    await open.click()
    await b.page.locator("#normal-media-viewer").waitFor({state: "visible", timeout: WAIT_MS})
    await b.page.screenshot({path: `${SCREEN_DIR}/photo-reopen-390x844.png`, fullPage: true})
    await b.page.locator("#normal-media-viewer-close").click()

    await b.page.reload({waitUntil: "domcontentloaded"})
    await b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    const replayed = await waitForPeerMedia(b.page, "photo")
    await replayed.getByRole("button", {name: "Open photo"}).click()
    await b.page.locator("#normal-media-viewer img").waitFor({state: "visible", timeout: WAIT_MS})

    await b.page.setViewportSize({width: 844, height: 390})
    await b.page.screenshot({path: `${SCREEN_DIR}/photo-reconnect-844x390.png`, fullPage: true})
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("video choose → preview → send → peer play to end → replay", {timeout: 90_000}, async () => {
  const videoPath = `${SCREEN_DIR}/tiny-h264.mp4`
  makeVideo(videoPath)
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser, {width: 390, height: 844}, {width: 844, height: 390})
    const {a, b} = pair

    await a.page.locator("#normal-media-file-input").setInputFiles(videoPath)
    await a.page.locator("#normal-media-preview").waitFor({state: "visible", timeout: WAIT_MS})
    assert.equal(await a.page.locator("#normal-media-preview-container video").count(), 1)
    await sendNormal(a.page)
    await a.page.getByRole("status").filter({hasText: "Video sent."}).waitFor({state: "visible", timeout: WAIT_MS})

    const peerCard = await waitForPeerMedia(b.page, "video")
    const video = peerCard.locator("video")
    await video.waitFor({state: "visible", timeout: WAIT_MS})
    await video.evaluate(async (element) => {
      await element.play()
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("first video playback timed out")), 5_000)
        element.addEventListener("ended", () => { clearTimeout(timer); resolve() }, {once: true})
      })
    })
    assert.equal(await video.evaluate((element) => element.ended), true)

    await video.evaluate(async (element) => {
      element.currentTime = 0
      await element.play()
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("video replay timed out")), 5_000)
        element.addEventListener("ended", () => { clearTimeout(timer); resolve() }, {once: true})
      })
    })
    assert.equal(await video.evaluate((element) => element.ended), true)
    await b.page.screenshot({path: `${SCREEN_DIR}/video-replay-844x390.png`, fullPage: true})
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("true upload failure shows failure and delivers nothing", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    await a.page.route("**/normal-media/**", async (route) => {
      if (route.request().method() === "POST") {
        await route.fulfill({status: 503, contentType: "application/json", body: JSON.stringify({error: "forced_upload_failure"})})
      } else {
        await route.continue()
      }
    })

    await chooseMedia(a.page, {name: "failure.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await a.page.locator("#normal-media-preview-status").filter({hasText: "Send failed"}).waitFor({state: "visible", timeout: WAIT_MS})
    await b.page.waitForTimeout(1_500)
    assert.equal(await b.page.locator(".normal-media-message:not(.mine)").count(), 0)
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("lost acknowledgement retries same logical media and converges to one bubble", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    const postUrls = []
    let first = true

    await a.page.route("**/normal-media/**", async (route) => {
      if (route.request().method() !== "POST") return route.continue()
      postUrls.push(route.request().url())
      if (first) {
        first = false
        const upstream = await route.fetch()
        assert.equal(upstream.status(), 201)
        await route.abort("failed")
      } else {
        await route.continue()
      }
    })

    await chooseMedia(a.page, {name: "lost-ack.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await a.page.locator("#normal-media-send").filter({hasText: "Retry send"}).waitFor({state: "visible", timeout: WAIT_MS})
    await waitForPeerMedia(b.page, "photo")
    await a.page.locator("#normal-media-send").click()
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})

    assert.equal(postUrls.length, 2)
    assert.equal(postUrls[0], postUrls[1], "retry keeps the same client media identity")
    assert.equal(await a.page.locator(".normal-media-message.mine").count(), 1)
    assert.equal(await b.page.locator(".normal-media-message:not(.mine)").count(), 1)
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("Conversation A late upload completion is inert after A ends and participant enters Conversation B", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b
  let c
  let releaseUpload
  try {
    a = await boot(browser)
    b = await boot(browser)
    await a.page.locator('button.door:has-text("Advice")').click()
    await b.page.locator('button.door:has-text("Advice")').click()
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    ])

    let interceptedResolve
    const intercepted = new Promise((resolve) => { interceptedResolve = resolve })
    const gate = new Promise((resolve) => { releaseUpload = resolve })

    await a.page.route("**/normal-media/**", async (route) => {
      if (route.request().method() === "POST") {
        interceptedResolve()
        await gate
        await route.continue()
      } else {
        await route.continue()
      }
    })

    await chooseMedia(a.page, {name: "conversation-a.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await intercepted
    await a.page.locator("#normal-media-preview-status").filter({hasText: "Uploading / sending"}).waitFor({state: "visible", timeout: WAIT_MS})

    await endConversation(a.page)
    await b.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT_MS})
    await fadeToDoors(a.page)
    await fadeToDoors(b.page)

    c = await boot(browser)
    await a.page.locator('button.door:has-text("Advice")').click()
    await c.page.locator('button.door:has-text("Advice")').click()
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS}),
      c.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    ])

    releaseUpload()
    await a.page.waitForTimeout(1_500)
    await c.page.waitForTimeout(1_500)
    assert.equal(await a.page.locator(".normal-media-message").count(), 0)
    assert.equal(await c.page.locator(".normal-media-message").count(), 0)
    assertNoPageErrors(a, b, c)
  } finally {
    releaseUpload?.()
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await c?.context.close().catch(() => {})
    await browser.close()
    rmSync(`${SCREEN_DIR}/tiny-h264.mp4`, {force: true})
  }
})
