import assert from "node:assert/strict"
import {mkdir} from "node:fs/promises"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4004"
const SCREENSHOT_DIR = "tmp/team4-media-screenshots"
const VIEWPORTS = [
  [320, 568],
  [360, 740],
  [390, 844],
  [412, 915],
  [844, 390],
  [820, 1180],
  [1440, 900]
]

async function launchBrowser() {
  return chromium.launch({
    headless: true,
    args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]
  })
}

async function openMediaPage(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  await context.grantPermissions(["microphone", "camera"], {origin: BASE_URL})
  const page = await context.newPage()
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "StrangerTalks root loads")
  return {context, page}
}

test("real Chromium tracks obey CONNECTING, ACTIVE, teardown, Accept gate, and Return-to-Voice authority", {timeout: 60_000}, async () => {
  const browser = await launchBrowser()
  let context
  try {
    const opened = await openMediaPage(browser)
    context = opened.context
    const result = await opened.page.evaluate(async () => {
      const {CALL_STATUS, LiveCallCoordinator} = await import("/assets/live_call.mjs")
      const originalGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices)
      let captureRequests = 0
      navigator.mediaDevices.getUserMedia = async (constraints) => {
        captureRequests++
        return originalGetUserMedia(constraints)
      }

      const okPush = (event) => ({
        receive(kind, callback) {
          if (kind === "ok") {
            queueMicrotask(() => callback(
              event === "call:request_credentials"
                ? {ice_servers: []}
                : event === "call:return_to_voice"
                  ? {media_generation: 2}
                  : {}
            ))
          }
          return this
        }
      })
      const channel = {push(event) { return okPush(event) }}

      const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel})
      coord.callAttemptId = "attempt-1"
      coord.role = "caller"
      coord.status = CALL_STATUS.CONNECTING
      await coord.initializeWebRTC(true)
      const connectingCaptureRequests = captureRequests
      const pc = coord.peerConnection
      const generation = coord.mediaGeneration

      coord.status = CALL_STATUS.ACTIVE
      await coord.activateLocalMedia("attempt-1", generation, pc)
      const audioTrack = coord.localStream?.getAudioTracks?.()[0] || null
      const activeAudioState = audioTrack?.readyState || null
      const activeAudioEnabled = audioTrack?.enabled ?? null
      const attachedAudio = coord.transportAudioTransceiver?.sender?.track === audioTrack
      coord.teardown("blocked")
      const endedAudioState = audioTrack?.readyState || null

      const acceptMic = await originalGetUserMedia({audio: true, video: false})
      const acceptTrack = acceptMic.getAudioTracks()[0]
      acceptTrack.enabled = true
      const acceptCoord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel})
      acceptCoord.callAttemptId = "attempt-accept"
      acceptCoord.role = "callee"
      acceptCoord.status = CALL_STATUS.PENDING_INCOMING
      acceptCoord.rawAudioTrack = acceptTrack
      await acceptCoord.accept()
      const acceptStatus = acceptCoord.status
      const acceptTrackEnabled = acceptTrack.enabled
      acceptCoord.teardown("ended")

      const videoCoord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel})
      videoCoord.callAttemptId = "attempt-video"
      videoCoord.status = CALL_STATUS.ACTIVE
      const cameraStream = await videoCoord.acquireCameraStream()
      const cameraTrack = cameraStream?.getVideoTracks?.()[0] || null
      const cameraBeforeReturn = cameraTrack?.readyState || null
      await videoCoord.returnToVoice()
      const cameraAfterReturn = cameraTrack?.readyState || null
      videoCoord.teardown("ended")

      const appSource = await fetch("/assets/app.js").then((response) => response.text())
      const shareScreenVisible = [...document.querySelectorAll("button")]
        .some((button) => /share\s*screen/i.test(button.textContent || ""))

      navigator.mediaDevices.getUserMedia = originalGetUserMedia
      return {
        connectingCaptureRequests,
        activeAudioState,
        activeAudioEnabled,
        attachedAudio,
        endedAudioState,
        acceptStatus,
        acceptTrackEnabled,
        cameraBeforeReturn,
        cameraAfterReturn,
        shareScreenVisible,
        sourceUsesDisplayMedia: appSource.includes("getDisplayMedia")
      }
    })

    assert.equal(result.connectingCaptureRequests, 0, "CONNECTING makes zero microphone/camera requests")
    assert.equal(result.activeAudioState, "live", "ACTIVE owns a real Chromium microphone track")
    assert.equal(result.activeAudioEnabled, true, "ACTIVE unmuted audio track is enabled")
    assert.equal(result.attachedAudio, true, "ACTIVE audio track is attached to the authoritative sender")
    assert.equal(result.endedAudioState, "ended", "terminal teardown stops the real microphone track")
    assert.equal(result.acceptStatus, "CONNECTING", "Accept enters CONNECTING")
    assert.equal(result.acceptTrackEnabled, false, "Accept re-closes outgoing audio before CONNECTING")
    assert.equal(result.cameraBeforeReturn, "live", "ACTIVE camera acquisition yields a real track")
    assert.equal(result.cameraAfterReturn, "ended", "Return to Voice stops the real camera track")
    assert.equal(result.shareScreenVisible, false, "V1 exposes no Share Screen control")
    assert.equal(result.sourceUsesDisplayMedia, false, "V1 app source does not invoke getDisplayMedia")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("required media surfaces fit every Team 4 viewport and preserve basic accessibility contracts", {timeout: 90_000}, async () => {
  await mkdir(SCREENSHOT_DIR, {recursive: true})
  const browser = await launchBrowser()
  let context
  try {
    const opened = await openMediaPage(browser, {width: 390, height: 844})
    context = opened.context
    const page = opened.page

    await page.evaluate(() => {
      document.querySelectorAll("[data-screen]").forEach((screen) => screen.classList.remove("active"))
      document.querySelector('[data-screen="conversation"]')?.classList.add("active")
      for (const id of ["live-call-incoming", "live-call-active", "voice-recording", "voice-preview", "view-once-preview"]) {
        const node = document.getElementById(id)
        if (node) node.hidden = false
      }
      const localVideo = document.getElementById("live-call-local-video")
      const remoteVideo = document.getElementById("live-call-remote-video")
      if (localVideo) localVideo.hidden = false
      if (remoteVideo) remoteVideo.hidden = false
      for (const id of ["btn-call-return-to-voice", "view-once-video-send", "view-twice-video-send"]) {
        const node = document.getElementById(id)
        if (node) node.hidden = false
      }
    })

    const criticalSelectors = [
      "#btn-call-accept", "#btn-call-decline", "#btn-call-toggle-mute", "#btn-call-toggle-video",
      "#btn-call-return-to-voice", "#btn-call-end", "#voice-stop", "#voice-record-cancel",
      "#voice-send", "#voice-rerecord", "#view-once-send", "#view-twice-send",
      "#view-once-video-send", "#view-twice-video-send", "#view-once-preview-cancel"
    ]

    for (const [width, height] of VIEWPORTS) {
      await page.setViewportSize({width, height})
      for (const selector of criticalSelectors) {
        const locator = page.locator(selector)
        if (await locator.count()) await locator.scrollIntoViewIfNeeded()
      }
      const geometry = await page.evaluate(() => ({
        innerWidth: window.innerWidth,
        documentWidth: document.documentElement.scrollWidth,
        bodyWidth: document.body.scrollWidth
      }))
      assert.ok(geometry.documentWidth <= geometry.innerWidth + 1, `${width}x${height}: no document horizontal overflow`)
      assert.ok(geometry.bodyWidth <= geometry.innerWidth + 1, `${width}x${height}: no body horizontal overflow`)
      await page.screenshot({path: `${SCREENSHOT_DIR}/${width}x${height}.png`, fullPage: true})
    }

    const labels = await page.evaluate(() => ({
      incomingRole: document.getElementById("live-call-incoming")?.getAttribute("role"),
      incomingLabelledBy: document.getElementById("live-call-incoming")?.getAttribute("aria-labelledby"),
      activeLabel: document.getElementById("live-call-active")?.getAttribute("aria-label"),
      remoteVideoLabel: document.getElementById("live-call-remote-video")?.getAttribute("aria-label"),
      localVideoLabel: document.getElementById("live-call-local-video")?.getAttribute("aria-label")
    }))
    assert.equal(labels.incomingRole, "dialog")
    assert.ok(labels.incomingLabelledBy)
    assert.equal(labels.activeLabel, "Live Call")
    assert.equal(labels.remoteVideoLabel, "Remote Video")
    assert.equal(labels.localVideoLabel, "Local Video")

    await page.locator("#btn-call-toggle-mute").focus()
    const focusState = await page.locator("#btn-call-toggle-mute").evaluate((node) => {
      const style = getComputedStyle(node)
      return {active: document.activeElement === node, outline: style.outlineStyle, boxShadow: style.boxShadow}
    })
    assert.equal(focusState.active, true, "keyboard focus reaches media controls")
    assert.ok(focusState.outline !== "none" || focusState.boxShadow !== "none", "focused media control has a visible focus treatment")

    await page.emulateMedia({reducedMotion: "reduce"})
    assert.equal(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches), true)
    await page.emulateMedia({forcedColors: "active"})
    assert.equal(await page.evaluate(() => matchMedia("(forced-colors: active)").matches), true)

    await page.emulateMedia({forcedColors: "none", reducedMotion: "no-preference"})
    await page.setViewportSize({width: 720, height: 450})
    const reflow = await page.evaluate(() => ({innerWidth: innerWidth, scrollWidth: document.documentElement.scrollWidth}))
    assert.ok(reflow.scrollWidth <= reflow.innerWidth + 1, "200% zoom-equivalent CSS viewport reflows without horizontal overflow")
  } finally {
    await context?.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
