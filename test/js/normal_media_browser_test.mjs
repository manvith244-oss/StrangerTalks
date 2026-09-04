import assert from "node:assert/strict"
import test from "node:test"
import {execFileSync} from "node:child_process"
import {mkdirSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const SCREEN_DIR = join(tmpdir(), "team9-normal-media-browser")
const WAIT_MS = 12_000

function validJpeg(entropy = 0x12) {
  const sof0Payload = Buffer.from([8, 0, 100, 0, 100, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0])
  const sof0Len = sof0Payload.length + 2
  return Buffer.concat([
    Buffer.from([0xff, 0xd8, 0xff, 0xc0, (sof0Len >> 8) & 0xff, sof0Len & 0xff]),
    sof0Payload,
    Buffer.from([0xff, 0xda, 0, 8, 1, 1, 0, 0, 0x3f, 0, entropy, 0x34, 0xff, 0xd9])
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
  const consoleErrors = []
  page.on("pageerror", (error) => pageErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT_MS})
  await page.locator("#conversation-language").selectOption("en")
  await page.locator("#normal-media-picker-btn").waitFor({state: "attached", timeout: WAIT_MS})
  return {context, page, pageErrors, consoleErrors}
}

async function openSameParticipantTab(participant) {
  const page = await participant.context.newPage()
  const pageErrors = []
  const consoleErrors = []
  page.on("pageerror", (error) => pageErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "sibling tab loads")
  await page.locator("#normal-media-picker-btn").waitFor({state: "attached", timeout: WAIT_MS})
  await page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
  return {page, pageErrors, consoleErrors}
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

async function sendText(page, text) {
  await page.locator("#message-input").fill(text)
  await page.locator("#message-form button.primary").click()
  await page.locator("#messages li", {hasText: text}).waitFor({state: "visible", timeout: WAIT_MS})
}

async function waitForPeerText(page, text) {
  const node = page.locator("#messages li.message:not(.mine)", {hasText: text})
  await node.waitFor({state: "visible", timeout: WAIT_MS})
  return node
}

async function waitForPeerMedia(page, kind, count = 1) {
  const cards = page.locator(`.normal-media-message:not(.mine) .normal-media-card`, {
    hasText: kind === "video" ? "Video" : "Photo"
  })
  await page.waitForFunction(
    ({selector, expected}) => document.querySelectorAll(selector).length >= expected,
    {selector: `.normal-media-message:not(.mine) .normal-media-card`, expected: count},
    {timeout: WAIT_MS}
  )
  return cards
}

async function timelineIndex(locator) {
  return locator.evaluate((node) => [...node.parentElement.children].indexOf(node))
}

async function endConversation(page) {
  const details = page.locator("details.overflow")
  if ((await details.getAttribute("open")) === null) await details.locator("summary").click()
  await page.locator("#end-conversation").click()
  await page.locator("#end-confirmation-dialog").waitFor({state: "visible", timeout: WAIT_MS})
  await page.locator("#end-confirm").click()
  await page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT_MS})
}

async function blockConversation(page) {
  page.once("dialog", (dialog) => dialog.accept())
  const details = page.locator("details.overflow")
  if ((await details.getAttribute("open")) === null) await details.locator("summary").click()
  await page.locator("#block").click()
  await page.waitForTimeout(400)
}

async function fadeToDoors(page) {
  await page.locator("#fade-conversation").click()
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible", timeout: WAIT_MS})
  await page.locator("#conversation-language").selectOption("en")
}

async function holdRecipientMediaList(page) {
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const handler = async (route) => {
    await gate
    await route.continue()
  }
  await page.route("**/normal-media", handler)
  return async () => {
    release()
    await page.unroute("**/normal-media", handler)
  }
}

async function holdUpload(page) {
  let release
  let interceptedResolve
  const gate = new Promise((resolve) => { release = resolve })
  const intercepted = new Promise((resolve) => { interceptedResolve = resolve })
  const handler = async (route) => {
    if (route.request().method() !== "POST") return route.continue()
    interceptedResolve()
    await gate
    await route.continue()
  }
  await page.route("**/normal-media/**", handler)
  return {
    intercepted,
    release: async () => {
      release()
      await page.unroute("**/normal-media/**", handler)
    }
  }
}

function assertNoPageErrors(...participants) {
  for (const participant of participants) {
    assert.deepEqual(participant.pageErrors || [], [])
    assert.deepEqual(participant.consoleErrors || [], [])
  }
}

mkdirSync(SCREEN_DIR, {recursive: true})

test("photo choose → preview → send → peer receive → open → close → reopen → reconnect", {timeout: 90_000}, async () => {
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
    const peerCards = await waitForPeerMedia(b.page, "photo")
    const peerCard = peerCards.first()
    assert.equal((await peerCard.textContent()).includes("private-name-should-not-leak.jpg"), false)

    const open = peerCard.getByRole("button", {name: "Open photo"})
    await open.click()
    await b.page.locator("#normal-media-viewer img").waitFor({state: "visible", timeout: WAIT_MS})
    await b.page.locator("#normal-media-viewer-close").click()
    await b.page.locator("#normal-media-viewer").waitFor({state: "hidden", timeout: WAIT_MS})
    await open.click()
    await b.page.locator("#normal-media-viewer img").waitFor({state: "visible", timeout: WAIT_MS})
    await b.page.screenshot({path: `${SCREEN_DIR}/photo-reopen-390x844.png`, fullPage: true})
    await b.page.locator("#normal-media-viewer-close").click()

    await b.page.reload({waitUntil: "domcontentloaded"})
    await b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    const replayed = (await waitForPeerMedia(b.page, "photo")).first()
    await replayed.getByRole("button", {name: "Open photo"}).click()
    await b.page.locator("#normal-media-viewer img").waitFor({state: "visible", timeout: WAIT_MS})
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("video choose → preview → send → peer receive → play → finish → play again while text arrives", {timeout: 90_000}, async () => {
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

    const peerCard = (await waitForPeerMedia(b.page, "video")).first()
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

    const replayEnded = video.evaluate(async (element) => {
      element.currentTime = 0
      await element.play()
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("video replay timed out")), 5_000)
        element.addEventListener("ended", () => { clearTimeout(timer); resolve() }, {once: true})
      })
    })
    await sendText(a.page, "text while replaying")
    await waitForPeerText(b.page, "text while replaying")
    await replayEnded
    assert.equal(await video.evaluate((element) => element.ended), true)
    await b.page.screenshot({path: `${SCREEN_DIR}/video-replay-844x390.png`, fullPage: true})
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
    rmSync(videoPath, {force: true})
  }
})

test("file picker cancel and preview Cancel send zero media", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    let posts = 0
    a.page.on("request", (request) => {
      if (request.method() === "POST" && request.url().includes("/normal-media/")) posts += 1
    })

    const chooserPromise = a.page.waitForEvent("filechooser")
    await a.page.locator("#normal-media-picker-btn").click()
    const chooser = await chooserPromise
    await chooser.setFiles([])
    await a.page.waitForTimeout(300)
    assert.equal(await a.page.locator("#normal-media-preview").isHidden(), true)

    await chooseMedia(a.page, {name: "cancel.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await a.page.locator("#normal-media-cancel").click()
    await a.page.locator("#normal-media-preview").waitFor({state: "hidden", timeout: WAIT_MS})
    await b.page.waitForTimeout(800)
    assert.equal(posts, 0)
    assert.equal(await b.page.locator(".normal-media-message:not(.mine)").count(), 0)
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("authoritative upload rejection reports rejection and delivers nothing", {timeout: 60_000}, async () => {
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
    await a.page.locator("#normal-media-preview-status").filter({hasText: "Send rejected"}).waitFor({state: "visible", timeout: WAIT_MS})
    await b.page.waitForTimeout(1_200)
    assert.equal(await b.page.locator(".normal-media-message:not(.mine)").count(), 0)
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("server accepted + ACK lost + retry keeps one logical media item", {timeout: 75_000}, async () => {
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
    await a.page.locator("#normal-media-preview-status").filter({hasText: "Send not confirmed"}).waitFor({state: "visible", timeout: WAIT_MS})
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

test("disconnect during upload leaves ambiguous retryable state and reconnect converges once", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  try {
    pair = await matchPair(browser)
    const {a, b} = pair

    await chooseMedia(a.page, {name: "offline.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await a.context.setOffline(true)
    await sendNormal(a.page)
    await a.page.locator("#normal-media-preview-status").filter({hasText: "Send not confirmed"}).waitFor({state: "visible", timeout: WAIT_MS})
    await a.context.setOffline(false)
    await a.page.waitForTimeout(1_000)
    await a.page.locator("#normal-media-send").click()
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})
    await waitForPeerMedia(b.page, "photo")
    assert.equal(await b.page.locator(".normal-media-message:not(.mine)").count(), 1)
    assertNoPageErrors(a, b)
  } finally {
    await pair?.a.context.setOffline(false).catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("media accepted → text accepted → recipient polls renders media → text", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let releaseList
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    releaseList = await holdRecipientMediaList(b.page)

    await chooseMedia(a.page, {name: "before-text.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})
    await sendText(a.page, "text accepted second")
    const peerText = await waitForPeerText(b.page, "text accepted second")

    await releaseList()
    releaseList = null
    const mediaNode = b.page.locator(".normal-media-message:not(.mine)").first()
    await mediaNode.waitFor({state: "visible", timeout: WAIT_MS})
    assert.ok(await timelineIndex(mediaNode) < await timelineIndex(peerText))
    assertNoPageErrors(a, b)
  } finally {
    await releaseList?.().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("text accepted → media accepted → recipient polls renders text → media", {timeout: 75_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let releaseList
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    releaseList = await holdRecipientMediaList(b.page)

    await sendText(a.page, "text accepted first")
    const peerText = await waitForPeerText(b.page, "text accepted first")
    await chooseMedia(a.page, {name: "after-text.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})

    await releaseList()
    releaseList = null
    const mediaNode = b.page.locator(".normal-media-message:not(.mine)").first()
    await mediaNode.waitFor({state: "visible", timeout: WAIT_MS})
    assert.ok(await timelineIndex(peerText) < await timelineIndex(mediaNode))
    assertNoPageErrors(a, b)
  } finally {
    await releaseList?.().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("media1 → text → media2 survives reconnect without duplication or reordering", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let releaseList
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    releaseList = await holdRecipientMediaList(b.page)

    await chooseMedia(a.page, {name: "media-1.jpg", mimeType: "image/jpeg", buffer: validJpeg(0x12)})
    await sendNormal(a.page)
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})
    await sendText(a.page, "middle canonical text")
    await waitForPeerText(b.page, "middle canonical text")
    await chooseMedia(a.page, {name: "media-2.jpg", mimeType: "image/jpeg", buffer: validJpeg(0x13)})
    await sendNormal(a.page)
    await a.page.getByRole("status").filter({hasText: "Photo sent."}).waitFor({state: "visible", timeout: WAIT_MS})

    await releaseList()
    releaseList = null
    await waitForPeerMedia(b.page, "photo", 2)

    const assertOrder = async () => {
      const media = b.page.locator(".normal-media-message:not(.mine)")
      const text = b.page.locator("#messages li.message:not(.mine)", {hasText: "middle canonical text"})
      assert.equal(await media.count(), 2)
      assert.ok(await timelineIndex(media.nth(0)) < await timelineIndex(text))
      assert.ok(await timelineIndex(text) < await timelineIndex(media.nth(1)))
    }

    await assertOrder()
    await b.page.reload({waitUntil: "domcontentloaded"})
    await b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    await waitForPeerMedia(b.page, "photo", 2)
    await waitForPeerText(b.page, "middle canonical text")
    await assertOrder()
    assertNoPageErrors(a, b)
  } finally {
    await releaseList?.().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("End during upload makes late completion inert", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let held
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    held = await holdUpload(a.page)

    await chooseMedia(a.page, {name: "end-race.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await held.intercepted
    await endConversation(b.page)
    await a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT_MS})
    await held.release()
    held = null
    await a.page.waitForTimeout(1_000)
    assert.equal(await a.page.locator(".normal-media-message").count(), 0)
    assert.equal(await b.page.locator(".normal-media-message").count(), 0)
    assertNoPageErrors(a, b)
  } finally {
    await held?.release().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("Block during upload makes late completion inert", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let held
  try {
    pair = await matchPair(browser)
    const {a, b} = pair
    held = await holdUpload(a.page)

    await chooseMedia(a.page, {name: "block-race.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await held.intercepted
    await blockConversation(b.page)
    await held.release()
    held = null
    await a.page.waitForTimeout(1_200)
    assert.equal(await a.page.locator(".normal-media-message").count(), 0)
    assert.equal(await b.page.locator(".normal-media-message").count(), 0)
    assertNoPageErrors(a, b)
  } finally {
    await held?.release().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("sibling tab stale draft cannot send after the Conversation ends", {timeout: 90_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let pair
  let sibling
  try {
    pair = await matchPair(browser)
    sibling = await openSameParticipantTab(pair.a)
    let siblingPosts = 0
    sibling.page.on("request", (request) => {
      if (request.method() === "POST" && request.url().includes("/normal-media/")) siblingPosts += 1
    })

    await chooseMedia(sibling.page, {name: "sibling-stale.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await endConversation(pair.a.page)
    await sibling.page.waitForTimeout(500)
    await sibling.page.locator("#normal-media-send").click({force: true}).catch(() => {})
    await sibling.page.waitForTimeout(700)
    assert.equal(siblingPosts, 0)
    assertNoPageErrors(pair.a, pair.b, sibling)
  } finally {
    await sibling?.page.close().catch(() => {})
    await pair?.a.context.close().catch(() => {})
    await pair?.b.context.close().catch(() => {})
    await browser.close()
  }
})

test("Conversation A late upload completion is inert after participant enters Conversation B", {timeout: 120_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let a
  let b
  let c
  let held
  try {
    a = await boot(browser)
    b = await boot(browser)
    await a.page.locator('button.door:has-text("Advice")').click()
    await b.page.locator('button.door:has-text("Advice")').click()
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS}),
      b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    ])

    held = await holdUpload(a.page)
    await chooseMedia(a.page, {name: "conversation-a.jpg", mimeType: "image/jpeg", buffer: validJpeg()})
    await sendNormal(a.page)
    await held.intercepted

    await endConversation(b.page)
    await a.page.locator('section[data-screen="ended"].active').waitFor({state: "visible", timeout: WAIT_MS})
    await fadeToDoors(a.page)
    await fadeToDoors(b.page)

    c = await boot(browser)
    await a.page.locator('button.door:has-text("Advice")').click()
    await c.page.locator('button.door:has-text("Advice")').click()
    await Promise.all([
      a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS}),
      c.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible", timeout: WAIT_MS})
    ])

    await held.release()
    held = null
    await a.page.waitForTimeout(1_200)
    await c.page.waitForTimeout(1_200)
    assert.equal(await a.page.locator(".normal-media-message").count(), 0)
    assert.equal(await c.page.locator(".normal-media-message").count(), 0)
    assertNoPageErrors(a, b, c)
  } finally {
    await held?.release().catch(() => {})
    await a?.context.close().catch(() => {})
    await b?.context.close().catch(() => {})
    await c?.context.close().catch(() => {})
    await browser.close()
  }
})
