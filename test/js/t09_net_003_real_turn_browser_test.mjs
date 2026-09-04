import test from "node:test"
import assert from "node:assert/strict"
import {chromium} from "playwright"

const STATIC_BASE = process.env.T09_STATIC_BASE_URL || "http://127.0.0.1:8008"
const TURN_URL = process.env.T09_TURN_URL || "turn:127.0.0.1:3478?transport=udp"
const TURN_USERNAME = process.env.T09_TURN_USERNAME || "t09"
const TURN_CREDENTIAL = process.env.T09_TURN_CREDENTIAL || "t09-secret"

async function launchBrowser() {
  return chromium.launch({
    headless: true,
    args: [
      "--use-fake-ui-for-media-stream",
      "--use-fake-device-for-media-stream",
      "--autoplay-policy=no-user-gesture-required",
      "--disable-features=WebRtcHideLocalIpsWithMdns"
    ]
  })
}

test("T09 real Chromium establishes bidirectional fake-audio media through isolated relay-only TURN", async () => {
  const browser = await launchBrowser()
  const page = await browser.newPage()
  const pageErrors = []
  const consoleErrors = []
  page.on("pageerror", (error) => pageErrors.push(String(error)))
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text())
  })

  try {
    await page.goto(`${STATIC_BASE}/`, {waitUntil: "domcontentloaded"})

    const result = await page.evaluate(async ({turnUrl, username, credential}) => {
      const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
      const waitFor = async (predicate, label, timeout = 15000) => {
        const deadline = Date.now() + timeout
        while (Date.now() < deadline) {
          if (await predicate()) return
          await sleep(50)
        }
        throw new Error(`Timed out waiting for ${label}`)
      }
      const waitForGathering = async (pc) => {
        if (pc.iceGatheringState === "complete") return
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error("ICE gathering timeout")), 10000)
          const listener = () => {
            if (pc.iceGatheringState === "complete") {
              clearTimeout(timer)
              pc.removeEventListener("icegatheringstatechange", listener)
              resolve()
            }
          }
          pc.addEventListener("icegatheringstatechange", listener)
        })
      }
      const inboundAudioPackets = async (pc) => {
        const stats = await pc.getStats()
        let packets = 0
        stats.forEach((stat) => {
          if (stat.type === "inbound-rtp" && stat.kind === "audio" && !stat.isRemote) {
            packets += Number(stat.packetsReceived || 0)
          }
        })
        return packets
      }
      const selectedPair = async (pc) => {
        const stats = await pc.getStats()
        let pair = null
        stats.forEach((stat) => {
          if (stat.type === "transport" && stat.selectedCandidatePairId && stats.get(stat.selectedCandidatePairId)) {
            pair = stats.get(stat.selectedCandidatePairId)
          }
        })
        if (!pair) {
          stats.forEach((stat) => {
            if (stat.type === "candidate-pair" && stat.state === "succeeded" && stat.nominated) pair = stat
          })
        }
        if (!pair) return null
        const local = stats.get(pair.localCandidateId)
        const remote = stats.get(pair.remoteCandidateId)
        return {
          state: pair.state,
          nominated: Boolean(pair.nominated),
          localCandidateType: local?.candidateType || null,
          remoteCandidateType: remote?.candidateType || null,
          localProtocol: local?.protocol || null,
          remoteProtocol: remote?.protocol || null
        }
      }

      const config = {
        iceServers: [{urls: [turnUrl], username, credential}],
        iceTransportPolicy: "relay",
        bundlePolicy: "max-bundle",
        rtcpMuxPolicy: "require"
      }
      const pcA = new RTCPeerConnection(config)
      const pcB = new RTCPeerConnection(config)
      const candidatesA = []
      const candidatesB = []
      const remoteTracksA = []
      const remoteTracksB = []
      pcA.onicecandidate = (event) => { if (event.candidate) candidatesA.push(event.candidate.candidate) }
      pcB.onicecandidate = (event) => { if (event.candidate) candidatesB.push(event.candidate.candidate) }
      pcA.ontrack = (event) => remoteTracksA.push(event.track)
      pcB.ontrack = (event) => remoteTracksB.push(event.track)

      const streamA = await navigator.mediaDevices.getUserMedia({audio: true, video: false})
      const streamB = await navigator.mediaDevices.getUserMedia({audio: true, video: false})
      const trackA = streamA.getAudioTracks()[0]
      const trackB = streamB.getAudioTracks()[0]
      pcA.addTrack(trackA, streamA)
      pcB.addTrack(trackB, streamB)

      await pcA.setLocalDescription(await pcA.createOffer())
      await waitForGathering(pcA)
      await pcB.setRemoteDescription(pcA.localDescription)
      await pcB.setLocalDescription(await pcB.createAnswer())
      await waitForGathering(pcB)
      await pcA.setRemoteDescription(pcB.localDescription)

      await waitFor(
        () => ["connected", "completed"].includes(pcA.iceConnectionState) && ["connected", "completed"].includes(pcB.iceConnectionState),
        "relay-only ICE connection"
      )
      await waitFor(() => remoteTracksA.length > 0 && remoteTracksB.length > 0, "bidirectional remote audio tracks")

      if (candidatesA.length === 0 || candidatesB.length === 0) throw new Error("No ICE candidates gathered")
      const nonRelayA = candidatesA.filter((candidate) => !candidate.includes(" typ relay "))
      const nonRelayB = candidatesB.filter((candidate) => !candidate.includes(" typ relay "))
      if (nonRelayA.length || nonRelayB.length) {
        throw new Error(`relay-only policy leaked non-relay candidates: A=${JSON.stringify(nonRelayA)} B=${JSON.stringify(nonRelayB)}`)
      }

      const pairA = await selectedPair(pcA)
      const pairB = await selectedPair(pcB)
      if (!pairA || !pairB) throw new Error("Selected ICE candidate pair unavailable")
      if (pairA.localCandidateType !== "relay" || pairB.localCandidateType !== "relay") {
        throw new Error(`selected local candidate is not relay: ${JSON.stringify({pairA, pairB})}`)
      }

      const beforeA = await inboundAudioPackets(pcA)
      const beforeB = await inboundAudioPackets(pcB)
      await sleep(900)
      const afterA = await inboundAudioPackets(pcA)
      const afterB = await inboundAudioPackets(pcB)
      if (!(afterA > beforeA && afterB > beforeB)) {
        throw new Error(`audio packets did not advance through relay: ${JSON.stringify({beforeA, afterA, beforeB, afterB})}`)
      }

      const continuity = {
        trackA: remoteTracksA[0]?.readyState,
        trackB: remoteTracksB[0]?.readyState,
        pcA: pcA.connectionState,
        pcB: pcB.connectionState
      }
      if (continuity.trackA !== "live" || continuity.trackB !== "live") {
        throw new Error(`remote media continuity not live: ${JSON.stringify(continuity)}`)
      }

      streamA.getTracks().forEach((track) => track.stop())
      streamB.getTracks().forEach((track) => track.stop())
      pcA.close()
      pcB.close()

      return {
        candidatesA,
        candidatesB,
        pairA,
        pairB,
        packets: {beforeA, afterA, beforeB, afterB},
        continuity
      }
    }, {turnUrl: TURN_URL, username: TURN_USERNAME, credential: TURN_CREDENTIAL})

    assert.equal(pageErrors.length, 0, `page errors: ${pageErrors.join(" | ")}`)
    assert.equal(consoleErrors.length, 0, `console errors: ${consoleErrors.join(" | ")}`)
    assert.ok(result.candidatesA.every((candidate) => candidate.includes(" typ relay ")))
    assert.ok(result.candidatesB.every((candidate) => candidate.includes(" typ relay ")))
    assert.equal(result.pairA.localCandidateType, "relay")
    assert.equal(result.pairB.localCandidateType, "relay")
    assert.ok(result.packets.afterA > result.packets.beforeA)
    assert.ok(result.packets.afterB > result.packets.beforeB)
    console.log("T09_LOCAL_REAL_TURN_RELAY", JSON.stringify(result))
  } finally {
    await browser.close()
  }
})

test("T09 Chromium runtime confirms fatal timeout, dedupe, and stale-attempt isolation on candidate coordinator", async () => {
  const browser = await launchBrowser()
  const page = await browser.newPage()
  const pageErrors = []
  page.on("pageerror", (error) => pageErrors.push(String(error)))

  try {
    await page.goto(`${STATIC_BASE}/`, {waitUntil: "domcontentloaded"})
    const result = await page.evaluate(async () => {
      const {LiveCallCoordinator, CALL_STATUS} = await import("/priv/static/assets/live_call.mjs")

      class Push {
        constructor() { this.handlers = new Map() }
        receive(kind, callback) { this.handlers.set(kind, callback); return this }
        fire(kind, payload) { this.handlers.get(kind)?.(payload) }
      }
      const events = []
      const credentialPushes = []
      const channel = {
        push(event, payload) {
          events.push({event, payload})
          const push = new Push()
          if (event === "call:request_credentials") credentialPushes.push(push)
          return push
        }
      }
      const ends = () => events.filter(({event}) => event === "call:end")

      const timeoutCoordinator = new LiveCallCoordinator({channel, participantId: "browser-self", conversationId: "browser-conv"})
      timeoutCoordinator.callAttemptId = "browser-timeout"
      timeoutCoordinator.mediaGeneration = 1
      timeoutCoordinator.status = CALL_STATUS.CONNECTING
      const pending = timeoutCoordinator.initializeWebRTC(false)
      await Promise.resolve()
      if (credentialPushes.length !== 1) throw new Error("browser credential push not registered")
      credentialPushes[0].fire("timeout")
      await Promise.race([
        pending,
        new Promise((_, reject) => setTimeout(() => reject(new Error("browser credential timeout hung")), 250))
      ])
      if (ends().length !== 1 || ends()[0].payload.call_attempt_id !== "browser-timeout") {
        throw new Error(`browser fatal timeout call:end mismatch: ${JSON.stringify(ends())}`)
      }

      const dedupeEvents = []
      const dedupeChannel = {push(event, payload) { dedupeEvents.push({event, payload}); return new Push() }}
      const dedupe = new LiveCallCoordinator({channel: dedupeChannel, participantId: "browser-self"})
      const pc = {closed: 0, close() { this.closed += 1 }}
      dedupe.callAttemptId = "browser-dedupe"
      dedupe.mediaGeneration = 4
      dedupe.status = CALL_STATUS.ACTIVE
      dedupe.peerConnection = pc
      const first = dedupe.fatalTerminateCurrentAttempt({callAttemptId: "browser-dedupe", mediaGeneration: 4, peerConnection: pc})
      const second = dedupe.fatalTerminateCurrentAttempt({callAttemptId: "browser-dedupe", mediaGeneration: 4, peerConnection: pc})
      const dedupeEnds = dedupeEvents.filter(({event}) => event === "call:end")
      if (!first || second || dedupeEnds.length !== 1 || pc.closed !== 1) {
        throw new Error(`browser fatal dedupe failed: ${JSON.stringify({first, second, dedupeEnds, closed: pc.closed})}`)
      }

      const staleEvents = []
      const staleChannel = {push(event, payload) { staleEvents.push({event, payload}); return new Push() }}
      const stale = new LiveCallCoordinator({channel: staleChannel, participantId: "browser-self"})
      const pcB = {closed: 0, close() { this.closed += 1 }}
      const mediaB = {id: "browser-media-B", getTracks: () => []}
      stale.callAttemptId = "browser-B"
      stale.mediaGeneration = 9
      stale.status = CALL_STATUS.ACTIVE
      stale.peerConnection = pcB
      stale.localStream = mediaB
      const staleFatal = stale.fatalTerminateCurrentAttempt({callAttemptId: "browser-A", mediaGeneration: 8, peerConnection: {close() {}}})
      stale.handleCallEnded({call_attempt_id: "browser-A", reason: "late-A"})
      if (staleFatal || stale.callAttemptId !== "browser-B" || stale.peerConnection !== pcB || stale.localStream !== mediaB || pcB.closed !== 0) {
        throw new Error("browser stale-attempt isolation failed")
      }

      return {
        timeoutEndCount: ends().length,
        dedupeEndCount: dedupeEnds.length,
        staleEndCount: staleEvents.filter(({event}) => event === "call:end").length,
        staleCurrentAttempt: stale.callAttemptId,
        stalePeerClosed: pcB.closed
      }
    })

    assert.equal(pageErrors.length, 0, `page errors: ${pageErrors.join(" | ")}`)
    assert.deepEqual(result, {
      timeoutEndCount: 1,
      dedupeEndCount: 1,
      staleEndCount: 0,
      staleCurrentAttempt: "browser-B",
      stalePeerClosed: 0
    })
    console.log("T09_BROWSER_FATAL_AUTHORITY", JSON.stringify(result))
  } finally {
    await browser.close()
  }
})
