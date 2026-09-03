import assert from "node:assert/strict"
import test from "node:test"
import { CALL_STATUS, LiveCallCoordinator } from "../../priv/static/assets/live_call.mjs"

function phoenixPushOk(payload = {}) {
  return {
    receive(kind, callback) {
      if (kind === "ok") queueMicrotask(() => callback(payload))
      return this
    }
  }
}

async function flush() {
  await new Promise((resolve) => setImmediate(resolve))
}

function installRtcHarness({ mediaStream }) {
  const originalNavigator = globalThis.navigator
  const originalRTC = globalThis.RTCPeerConnection
  const pcs = []
  let mediaRequests = 0

  class FakeRTCPeerConnection {
    constructor(config) {
      this.config = config
      this.iceConnectionState = "new"
      this.localDescription = null
      this.remoteDescription = null
      this.senders = []
      this.closed = false
      pcs.push(this)
    }

    addTransceiver(kind) {
      const sender = {
        track: null,
        async replaceTrack(track) { this.track = track }
      }
      this.senders.push(sender)
      return { kind, sender, receiver: { track: { kind } }, direction: "sendrecv" }
    }

    getSenders() { return this.senders }
    async createOffer() { return { type: "offer", sdp: "fake-offer" } }
    async setLocalDescription(desc) { this.localDescription = desc }
    async setRemoteDescription(desc) { this.remoteDescription = desc }
    async addIceCandidate() {}
    close() { this.closed = true }
  }

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        getUserMedia: async () => {
          mediaRequests += 1
          return mediaStream
        }
      }
    }
  })
  globalThis.RTCPeerConnection = FakeRTCPeerConnection

  return {
    pcs,
    mediaRequests: () => mediaRequests,
    restore() {
      if (originalNavigator === undefined) delete globalThis.navigator
      else Object.defineProperty(globalThis, "navigator", { configurable: true, value: originalNavigator })
      if (originalRTC === undefined) delete globalThis.RTCPeerConnection
      else globalThis.RTCPeerConnection = originalRTC
    }
  }
}

function makeChannel(events) {
  return {
    push(event, payload) {
      events.push({ event, payload })
      if (event === "call:request_credentials") {
        return phoenixPushOk({ ice_servers: [{ urls: ["turn:127.0.0.1:3478?transport=udp"] }] })
      }
      return phoenixPushOk({})
    }
  }
}

test("T05-NET-003 RED: hard ICE failure during CONNECTING closes the PeerConnection and terminates only the current attempt", async () => {
  const events = []
  const media = { getTracks: () => [], getAudioTracks: () => [], getVideoTracks: () => [] }
  const harness = installRtcHarness({ mediaStream: media })

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-a",
      conversationId: "conv-a",
      channel: makeChannel(events)
    })
    coord.callAttemptId = "attempt-current"
    coord.role = "caller"
    coord.status = CALL_STATUS.CONNECTING

    await coord.initializeWebRTC(true)
    const pc = harness.pcs.at(-1)
    assert.equal(pc.config.iceTransportPolicy, "relay")
    assert.equal(coord.status, CALL_STATUS.CONNECTING)
    assert.equal(harness.mediaRequests(), 0)

    pc.iceConnectionState = "failed"
    pc.oniceconnectionstatechange()
    await flush()

    assert.equal(pc.closed, true, "hard ICE failure must close the current PeerConnection")
    assert.equal(coord.peerConnection, null)
    assert.equal(coord.callAttemptId, null)
    assert.equal(coord.status, CALL_STATUS.TERMINAL)
    assert.equal(harness.mediaRequests(), 0, "failed CONNECTING transport must never open microphone hardware")
    assert.equal(
      events.filter(({ event, payload }) => event === "call:end" && payload?.call_attempt_id === "attempt-current").length,
      1,
      "hard transport failure must terminate the matching server attempt exactly once"
    )
  } finally {
    harness.restore()
  }
})

test("T05-NET-003 RED: transient disconnect may recover, but hard failure after ACTIVE releases microphone and PeerConnection", async () => {
  const stopped = []
  const audioTrack = {
    kind: "audio",
    enabled: true,
    stop() { stopped.push("audio") }
  }
  const media = {
    getTracks: () => [audioTrack],
    getAudioTracks: () => [audioTrack],
    getVideoTracks: () => []
  }
  const events = []
  const harness = installRtcHarness({ mediaStream: media })

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-a",
      conversationId: "conv-a",
      channel: makeChannel(events)
    })
    coord.callAttemptId = "attempt-active"
    coord.role = "caller"
    coord.status = CALL_STATUS.CONNECTING

    await coord.initializeWebRTC(true)
    const pc = harness.pcs.at(-1)

    pc.iceConnectionState = "connected"
    pc.oniceconnectionstatechange()
    await flush()

    assert.equal(coord.status, CALL_STATUS.ACTIVE)
    assert.equal(harness.mediaRequests(), 1)
    assert.equal(coord.transportAudioTransceiver.sender.track, audioTrack)

    pc.iceConnectionState = "disconnected"
    pc.oniceconnectionstatechange()
    await flush()

    assert.equal(coord.status, CALL_STATUS.ACTIVE, "transient disconnected state must not destroy a recoverable active call")
    assert.equal(pc.closed, false)
    assert.deepEqual(stopped, [])

    pc.iceConnectionState = "failed"
    pc.oniceconnectionstatechange()
    await flush()

    assert.equal(pc.closed, true)
    assert.equal(coord.peerConnection, null)
    assert.equal(coord.status, CALL_STATUS.TERMINAL)
    assert.deepEqual(stopped, ["audio"], "hard failure must release acquired microphone hardware")
    assert.equal(
      events.filter(({ event, payload }) => event === "call:end" && payload?.call_attempt_id === "attempt-active").length,
      1
    )
  } finally {
    harness.restore()
  }
})

test("T05-NET-003: stale failed ICE callback from superseded Call A cannot terminate current Call B", async () => {
  const events = []
  const media = { getTracks: () => [], getAudioTracks: () => [], getVideoTracks: () => [] }
  const harness = installRtcHarness({ mediaStream: media })

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-a",
      conversationId: "conv-a",
      channel: makeChannel(events)
    })
    coord.callAttemptId = "attempt-a"
    coord.role = "caller"
    coord.status = CALL_STATUS.CONNECTING
    await coord.initializeWebRTC(true)
    const oldPc = harness.pcs.at(-1)

    const currentPc = { close() { throw new Error("Call B PeerConnection must not be closed by stale Call A") } }
    coord.callAttemptId = "attempt-b"
    coord.status = CALL_STATUS.ACTIVE
    coord.mediaGeneration = 7
    coord.peerConnection = currentPc
    coord.activeAt = 123

    oldPc.iceConnectionState = "failed"
    oldPc.oniceconnectionstatechange()
    await flush()

    assert.equal(coord.callAttemptId, "attempt-b")
    assert.equal(coord.status, CALL_STATUS.ACTIVE)
    assert.equal(coord.peerConnection, currentPc)
    assert.equal(coord.activeAt, 123)
    assert.equal(events.some(({ event, payload }) => event === "call:end" && payload?.call_attempt_id === "attempt-b"), false)
  } finally {
    harness.restore()
  }
})
