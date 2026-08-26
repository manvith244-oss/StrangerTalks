import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4004"
const CALL_TIMEOUT_MS = 45_000

function phoenixMessage(payload) {
  const text = typeof payload === "string" ? payload : payload?.toString?.()
  if (!text) return null
  try {
    const [joinRef, ref, topic, event, body] = JSON.parse(text)
    return {joinRef, ref, topic, event, body}
  } catch {
    return null
  }
}

async function installPeerInstrumentation(page) {
  await page.addInitScript(() => {
    window.__team4PeerConnections = []
    window.__team4RemoteTracks = []
    window.__team4LocalTracks = []

    const NativePeerConnection = window.RTCPeerConnection
    if (!NativePeerConnection) return

    class Team4TrackedPeerConnection extends NativePeerConnection {
      constructor(config) {
        super(config)
        window.__team4PeerConnections.push(this)
        this.addEventListener("track", (event) => {
          window.__team4RemoteTracks.push(event.track)
        })
      }
    }

    Object.defineProperty(window, "RTCPeerConnection", {
      configurable: true,
      writable: true,
      value: Team4TrackedPeerConnection
    })

    const mediaDevices = navigator.mediaDevices
    if (!mediaDevices?.getUserMedia) return
    const nativeGetUserMedia = mediaDevices.getUserMedia.bind(mediaDevices)
    Object.defineProperty(mediaDevices, "getUserMedia", {
      configurable: true,
      writable: true,
      value: async (constraints) => {
        const stream = await nativeGetUserMedia(constraints)
        for (const track of stream.getTracks()) window.__team4LocalTracks.push(track)
        return stream
      }
    })
  })
}

async function bootParticipant(browser) {
  const context = await browser.newContext({viewport: {width: 1280, height: 800}})
  await context.grantPermissions(["microphone", "camera"], {origin: BASE_URL})
  const page = await context.newPage()
  const frames = []

  page.on("websocket", (websocket) => {
    websocket.on("framesent", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) frames.push({direction: "sent", ...message})
    })
    websocket.on("framereceived", ({payload}) => {
      const message = phoenixMessage(payload)
      if (message) frames.push({direction: "received", ...message})
    })
  })

  await installPeerInstrumentation(page)
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "StrangerTalks root loads")
  await page.locator("button.door").first().waitFor({state: "visible"})
  await page.locator("#conversation-language").selectOption("en")
  return {context, page, frames}
}

async function matchPair(browser) {
  const a = await bootParticipant(browser)
  const b = await bootParticipant(browser)
  await a.page.getByRole("button", {name: "Advice", exact: true}).click()
  await a.page.locator('section[data-screen="queue"].active').waitFor({state: "visible"})
  await b.page.getByRole("button", {name: "Advice", exact: true}).click()
  await Promise.all([
    a.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"}),
    b.page.locator('section[data-screen="conversation"].active').waitFor({state: "visible"})
  ])
  return {a, b}
}

async function waitForPeerConnected(page) {
  await page.waitForFunction(() => {
    if (window.__team4PeerConnections.length !== 1) return false
    const pc = window.__team4PeerConnections[0]
    return pc.connectionState === "connected" || ["connected", "completed"].includes(pc.iceConnectionState)
  }, null, {timeout: CALL_TIMEOUT_MS})
}

async function waitForInboundPackets(page, kind) {
  await page.waitForFunction(async (expectedKind) => {
    const pc = window.__team4PeerConnections.at(-1)
    if (!pc) return false
    const stats = await pc.getStats()
    for (const report of stats.values()) {
      const reportKind = report.kind || report.mediaType
      if (report.type === "inbound-rtp" && reportKind === expectedKind && Number(report.packetsReceived || 0) > 0) {
        return true
      }
    }
    return false
  }, kind, {timeout: CALL_TIMEOUT_MS})
}

async function mediaSnapshot(page, kind) {
  return page.evaluate(async (expectedKind) => {
    const pc = window.__team4PeerConnections.at(-1)
    const stats = await pc.getStats()
    let selectedPair = null

    for (const report of stats.values()) {
      if (report.type === "transport" && report.selectedCandidatePairId) {
        selectedPair = stats.get(report.selectedCandidatePairId)
        if (selectedPair) break
      }
    }

    if (!selectedPair) {
      for (const report of stats.values()) {
        if (report.type === "candidate-pair" && report.state === "succeeded" && (report.selected || report.nominated)) {
          selectedPair = report
          break
        }
      }
    }

    const localCandidate = selectedPair ? stats.get(selectedPair.localCandidateId) : null
    const remoteCandidate = selectedPair ? stats.get(selectedPair.remoteCandidateId) : null
    let inboundPackets = 0
    for (const report of stats.values()) {
      const reportKind = report.kind || report.mediaType
      if (report.type === "inbound-rtp" && reportKind === expectedKind) {
        inboundPackets += Number(report.packetsReceived || 0)
      }
    }

    return {
      pcCount: window.__team4PeerConnections.length,
      connectionState: pc.connectionState,
      iceConnectionState: pc.iceConnectionState,
      remoteTrackLive: window.__team4RemoteTracks.some((track) => track.kind === expectedKind && track.readyState === "live"),
      localTrackLive: window.__team4LocalTracks.some((track) => track.kind === expectedKind && track.readyState === "live"),
      inboundPackets,
      selectedPairState: selectedPair?.state || null,
      selectedPairNominated: Boolean(selectedPair?.nominated || selectedPair?.selected),
      localCandidateType: localCandidate?.candidateType || null,
      remoteCandidateType: remoteCandidate?.candidateType || null
    }
  }, kind)
}

function assertRealSignaling(a, b) {
  assert.ok(a.frames.some((frame) => frame.direction === "sent" && frame.event === "call:initiate"), "A sends authoritative call:initiate")
  assert.ok(b.frames.some((frame) => frame.direction === "received" && frame.event === "call:incoming"), "B receives authoritative call:incoming")
  assert.ok(b.frames.some((frame) => frame.direction === "sent" && frame.event === "call:accept"), "B sends authoritative call:accept")
  assert.ok(a.frames.some((frame) => frame.direction === "received" && frame.event === "call:accepted"), "A receives authoritative call:accepted")
  assert.ok(a.frames.some((frame) => frame.direction === "sent" && frame.event === "call:signal"), "A sends WebRTC signaling through StrangerTalks")
  assert.ok(b.frames.some((frame) => frame.direction === "received" && frame.event === "call:signal"), "B receives A WebRTC signaling through StrangerTalks")
  assert.ok(b.frames.some((frame) => frame.direction === "sent" && frame.event === "call:signal"), "B sends WebRTC signaling through StrangerTalks")
  assert.ok(a.frames.some((frame) => frame.direction === "received" && frame.event === "call:signal"), "A receives B WebRTC signaling through StrangerTalks")
}

async function assertCleanup(participant) {
  await participant.page.waitForFunction(() => {
    return window.__team4PeerConnections.length > 0 && window.__team4PeerConnections.every((pc) => pc.connectionState === "closed")
  }, null, {timeout: 10_000})

  const cleanup = await participant.page.evaluate(() => ({
    allPeerConnectionsClosed: window.__team4PeerConnections.every((pc) => pc.connectionState === "closed"),
    allLocalTracksEnded: window.__team4LocalTracks.length > 0 && window.__team4LocalTracks.every((track) => track.readyState === "ended")
  }))
  assert.equal(cleanup.allPeerConnectionsClosed, true, "all real peer connections close")
  assert.equal(cleanup.allLocalTracksEnded, true, "all acquired local media tracks stop")
}

for (const scenario of [
  {name: "VOICE", startSelector: "#btn-voice-call", mediaKind: "audio"},
  {name: "VIDEO", startSelector: "#btn-video-call", mediaKind: "video"}
]) {
  test(`T4-WEBRTC-${scenario.name}: two real browser peers establish relay-only ${scenario.mediaKind} media and cleanly hang up`, {timeout: 120_000}, async () => {
    const browser = await chromium.launch({
      headless: true,
      args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]
    })
    let pair

    try {
      pair = await matchPair(browser)
      const {a, b} = pair

      await a.page.locator(scenario.startSelector).click()
      await b.page.locator("#live-call-incoming").waitFor({state: "visible"})
      await b.page.locator("#btn-call-accept").click()

      await Promise.all([waitForPeerConnected(a.page), waitForPeerConnected(b.page)])
      await Promise.all([
        waitForInboundPackets(a.page, scenario.mediaKind),
        waitForInboundPackets(b.page, scenario.mediaKind)
      ])

      const [snapshotA, snapshotB] = await Promise.all([
        mediaSnapshot(a.page, scenario.mediaKind),
        mediaSnapshot(b.page, scenario.mediaKind)
      ])

      for (const [label, snapshot] of [["A", snapshotA], ["B", snapshotB]]) {
        assert.equal(snapshot.pcCount, 1, `${label} owns exactly one real RTCPeerConnection`)
        assert.ok(["connected", "completed"].includes(snapshot.iceConnectionState) || snapshot.connectionState === "connected", `${label} ICE is connected`)
        assert.equal(snapshot.remoteTrackLive, true, `${label} observes a live remote ${scenario.mediaKind} MediaStreamTrack`)
        assert.equal(snapshot.localTrackLive, true, `${label} owns a live local ${scenario.mediaKind} MediaStreamTrack`)
        assert.ok(snapshot.inboundPackets > 0, `${label} receives actual inbound ${scenario.mediaKind} RTP packets`)
        assert.equal(snapshot.selectedPairState, "succeeded", `${label} selected candidate pair succeeded`)
        assert.equal(snapshot.localCandidateType, "relay", `${label} local selected ICE candidate is relay`)
        assert.equal(snapshot.remoteCandidateType, "relay", `${label} remote selected ICE candidate is relay`)
      }

      assertRealSignaling(a, b)

      await a.page.locator("#btn-call-end").click()
      await Promise.all([
        a.page.locator("#live-call-active").waitFor({state: "hidden"}),
        b.page.locator("#live-call-active").waitFor({state: "hidden"})
      ])
      await Promise.all([assertCleanup(a), assertCleanup(b)])
      assert.ok(a.frames.some((frame) => frame.direction === "sent" && frame.event === "call:end"), "hangup crosses authoritative StrangerTalks call:end path")
      assert.ok(b.frames.some((frame) => frame.direction === "received" && frame.event === "call:ended"), "peer converges through authoritative call:ended event")
    } finally {
      await pair?.a.context.close().catch(() => {})
      await pair?.b.context.close().catch(() => {})
      await browser.close().catch(() => {})
    }
  })
}
