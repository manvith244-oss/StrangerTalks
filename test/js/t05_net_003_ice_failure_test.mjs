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

function phoenixPushError(payload = { reason: "turn_unavailable" }) {
  return {
    receive(kind, callback) {
      if (kind === "error") queueMicrotask(() => callback(payload))
      return this
    }
  }
}

async function flush() {
  await new Promise((resolve) => setImmediate(resolve))
  await new Promise((resolve) => setImmediate(resolve))
}

function installRtcHarness({ getUserMedia }) {
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
      this.restartCount = 0
      this.configurationUpdates = []
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
    setConfiguration(config) { this.configurationUpdates.push(config) }
    restartIce() { this.restartCount += 1 }
    close() { this.closed = true }
  }

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        getUserMedia: async (constraints) => {
          mediaRequests += 1
          return getUserMedia(constraints)
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

function makeChannel(events, { failCredentialRefresh = false } = {}) {
  let credentialRequests = 0

  return {
    push(event, payload) {
      events.push({ event, payload })
      if (event === "call:request_credentials") {
        credentialRequests += 1
        if (failCredentialRefresh && credentialRequests > 1) return phoenixPushError()
        return phoenixPushOk({
          ice_servers: [{ urls: ["turn:127.0.0.1:3478?transport=udp"] }]
        })
      }
      return phoenixPushOk({})
    }
  }
}

function emptyStream() {
  return { getTracks: () => [], getAudioTracks: () => [], getVideoTracks: () => [] }
}

test("T05-NET-003: first current ICE failure preserves relay-only recovery and restarts ICE without opening hardware", async () => {
  const events = []
  const harness = installRtcHarness({ getUserMedia: async () => emptyStream() })

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

    assert.equal(pc.closed, false, "the first hard failure is allowed one credential-refresh recovery path")
    assert.equal(pc.restartCount, 1)
    assert.equal(pc.configurationUpdates.length, 1)
    assert.equal(pc.configurationUpdates[0].iceTransportPolicy, "relay")
    assert.equal(coord.callAttemptId, "attempt-current")
    assert.equal(coord.status, CALL_STATUS.CONNECTING)
    assert.equal(harness.mediaRequests(), 0)
    assert.equal(events.some(({ event }) => event === "call:end"), false)
  } finally {
    harness.restore()
  }
})

test("T05-NET-003 RED: failed TURN credential refresh after ICE failure closes local authority and terminates the same server attempt", async () => {
  const events = []
  const harness = installRtcHarness({ getUserMedia: async () => emptyStream() })

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-a",
      conversationId: "conv-a",
      channel: makeChannel(events, { failCredentialRefresh: true })
    })
    coord.callAttemptId = "attempt-fatal-ice"
    coord.role = "caller"
    coord.status = CALL_STATUS.CONNECTING

    await coord.initializeWebRTC(true)
    const pc = harness.pcs.at(-1)

    pc.iceConnectionState = "failed"
    pc.oniceconnectionstatechange()
    await flush()

    assert.equal(pc.closed, true)
    assert.equal(coord.peerConnection, null)
    assert.equal(coord.callAttemptId, null)
    assert.equal(coord.status, CALL_STATUS.TERMINAL)
    assert.equal(harness.mediaRequests(), 0)
    assert.equal(
      events.filter(({ event, payload }) => event === "call:end" && payload?.call_attempt_id === "attempt-fatal-ice").length,
      1,
      "a locally fatal ICE recovery failure must not leave the server attempt active"
    )
  } finally {
    harness.restore()
  }
})

test("T05-NET-003 RED: required microphone/camera permission denial after ACTIVE closes the same server attempt", async () => {
  const events = []
  const permissionError = new Error("Permission denied")
  permissionError.name = "NotAllowedError"
  const harness = installRtcHarness({ getUserMedia: async () => { throw permissionError } })

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-a",
      conversationId: "conv-a",
      channel: makeChannel(events)
    })
    coord.callAttemptId = "attempt-permission"
    coord.role = "caller"
    coord.callType = "video"
    coord.status = CALL_STATUS.CONNECTING

    await coord.initializeWebRTC(true)
    const pc = harness.pcs.at(-1)

    pc.iceConnectionState = "connected"
    pc.oniceconnectionstatechange()
    await flush()

    assert.equal(harness.mediaRequests(), 1)
    assert.equal(pc.closed, true)
    assert.equal(coord.peerConnection, null)
    assert.equal(coord.callAttemptId, null)
    assert.equal(coord.status, CALL_STATUS.TERMINAL)
    assert.equal(
      events.filter(({ event, payload }) => event === "call:end" && payload?.call_attempt_id === "attempt-permission").length,
      1,
      "required media permission failure must terminate the accepted server attempt"
    )
  } finally {
    harness.restore()
  }
})

test("T05-NET-003: transient disconnect stays recoverable", async () => {
  const stopped = []
  const audioTrack = {
    kind: "audio",
    enabled: true,
    stop() { stopped.push("audio") }
  }
  const stream = {
    getTracks: () => [audioTrack],
    getAudioTracks: () => [audioTrack],
    getVideoTracks: () => []
  }
  const events = []
  const harness = installRtcHarness({ getUserMedia: async () => stream })

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

    assert.equal(coord.status, CALL_STATUS.ACTIVE)
    assert.equal(pc.closed, false)
    assert.deepEqual(stopped, [])
    assert.equal(events.some(({ event }) => event === "call:end"), false)
  } finally {
    coordSafeTeardown(undefined)
    harness.restore()
  }
})

function coordSafeTeardown(coord) {
  if (coord?.teardown) coord.teardown("test_cleanup")
}

test("T05-NET-003: stale failed ICE callback from superseded Call A cannot terminate current Call B", async () => {
  const events = []
  const harness = installRtcHarness({ getUserMedia: async () => emptyStream() })

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
