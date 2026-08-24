import assert from "node:assert/strict"
import test from "node:test"
import { CALL_STATUS, LiveCallCoordinator } from "../../priv/static/assets/live_call.mjs"

function phoenixPushOk(payload) {
  return {
    receive(kind, callback) {
      if (kind === "ok") queueMicrotask(() => callback(payload))
      return this
    }
  }
}

test("accepted call remains CONNECTING until WebRTC transport establishes media authority", async () => {
  const coord = new LiveCallCoordinator({ participantId: "user-1", conversationId: "conv-1" })
  coord.callAttemptId = "attempt-1"
  coord.role = "caller"
  coord.status = CALL_STATUS.PENDING_OUTGOING

  let observedStatus = null
  coord.initializeWebRTC = async () => {
    observedStatus = coord.status
  }

  await coord.handleCallAccepted({ call_attempt_id: "attempt-1", active_at: 1_700_000_000 })

  assert.equal(observedStatus, CALL_STATUS.CONNECTING)
  assert.equal(coord.status, CALL_STATUS.CONNECTING)
})

test("outgoing microphone is fail-closed during CONNECTING and opens exactly with ICE authority", async () => {
  const originalNavigator = globalThis.navigator
  const originalRTC = globalThis.RTCPeerConnection

  const audioTrack = { kind: "audio", enabled: true, stop() {} }
  const stream = {
    getAudioTracks: () => [audioTrack],
    getTracks: () => [audioTrack]
  }

  let pc
  class FakeRTCPeerConnection {
    constructor(config) {
      this.config = config
      this.iceConnectionState = "new"
      this.localDescription = null
      this.remoteDescription = null
      this.senders = []
      pc = this
    }
    addTrack(track) { this.senders.push({ track }); return { track } }
    getSenders() { return this.senders }
    async createOffer() { return { type: "offer", sdp: "fake" } }
    async setLocalDescription(desc) { this.localDescription = desc }
    close() {}
  }

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { mediaDevices: { getUserMedia: async () => stream } }
  })
  globalThis.RTCPeerConnection = FakeRTCPeerConnection

  const channel = {
    push(event) {
      if (event === "call:request_credentials") {
        return phoenixPushOk({ ice_servers: [{ urls: ["turn:relay.invalid:3478"] }] })
      }
      return phoenixPushOk({})
    }
  }

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-1",
      conversationId: "conv-1",
      channel
    })
    coord.callAttemptId = "attempt-1"
    coord.role = "caller"
    coord.status = CALL_STATUS.CONNECTING

    await coord.initializeWebRTC(true)

    assert.equal(coord.status, CALL_STATUS.CONNECTING)
    assert.equal(audioTrack.enabled, false, "mic must be gated while UI/state is CONNECTING")
    assert.equal(pc.config.iceTransportPolicy, "relay")

    pc.iceConnectionState = "connected"
    pc.oniceconnectionstatechange()

    assert.equal(coord.status, CALL_STATUS.ACTIVE)
    assert.equal(audioTrack.enabled, true, "mic may open only when media authority becomes ACTIVE")
  } finally {
    if (originalNavigator === undefined) delete globalThis.navigator
    else Object.defineProperty(globalThis, "navigator", { configurable: true, value: originalNavigator })
    if (originalRTC === undefined) delete globalThis.RTCPeerConnection
    else globalThis.RTCPeerConnection = originalRTC
  }
})

test("mute toggles cannot open a CONNECTING microphone", async () => {
  const coord = new LiveCallCoordinator({ participantId: "user-1", conversationId: "conv-1" })
  const audioTrack = { kind: "audio", enabled: false, stop() {} }
  coord.callAttemptId = "attempt-1"
  coord.status = CALL_STATUS.CONNECTING
  coord.rawAudioTrack = audioTrack
  coord.localStream = { getAudioTracks: () => [audioTrack], getTracks: () => [audioTrack] }

  coord.selfMuted = true
  await coord.toggleMute()

  assert.equal(coord.selfMuted, false)
  assert.equal(audioTrack.enabled, false, "unmute intent cannot bypass CONNECTING media gate")
})

test("voice-expression changes cannot open a CONNECTING microphone", async () => {
  const coord = new LiveCallCoordinator({ participantId: "user-1", conversationId: "conv-1" })
  const audioTrack = { kind: "audio", enabled: false, stop() {} }
  coord.callAttemptId = "attempt-1"
  coord.status = CALL_STATUS.CONNECTING
  coord.rawAudioTrack = audioTrack
  coord.localStream = { getAudioTracks: () => [audioTrack], getTracks: () => [audioTrack] }
  coord.voiceEffectPreset = "warm_radio"

  await coord.setVoiceExpression("plain")

  assert.equal(audioTrack.enabled, false, "effect reset cannot bypass CONNECTING media gate")
})
test("late getUserMedia resolution cannot resurrect a terminal call", async () => {
  const originalNavigator = globalThis.navigator
  const originalRTC = globalThis.RTCPeerConnection
  let resolveMedia
  const stopped = []
  const audioTrack = {kind: "audio", enabled: true, stop() { stopped.push("audio") }}
  const stream = {getAudioTracks: () => [audioTrack], getTracks: () => [audioTrack]}
  class FakePC { constructor() { this.iceConnectionState = "new"; this.senders = [] } addTrack(track) { this.senders.push({track}) } getSenders() { return this.senders } close() {} }
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: {mediaDevices: {getUserMedia: () => new Promise(resolve => { resolveMedia = resolve })}}})
  globalThis.RTCPeerConnection = FakePC
  const channel = {push() { return phoenixPushOk({ice_servers: [{urls: ["turn:relay.invalid:3478"]}]}) }}
  try {
    const coord = new LiveCallCoordinator({participantId: "user-1", conversationId: "conv-1", channel})
    coord.callAttemptId = "attempt-1"; coord.role = "caller"; coord.status = CALL_STATUS.CONNECTING
    const initializing = coord.initializeWebRTC(false)
    await new Promise(resolve => setImmediate(resolve))
    coord.teardown("conversation_ended")
    resolveMedia(stream)
    await initializing
    assert.deepEqual(stopped, ["audio"])
    assert.equal(coord.localStream, null)
    assert.notEqual(coord.status, CALL_STATUS.ACTIVE)
  } finally {
    if (originalNavigator === undefined) delete globalThis.navigator
    else Object.defineProperty(globalThis, "navigator", {configurable: true, value: originalNavigator})
    if (originalRTC === undefined) delete globalThis.RTCPeerConnection
    else globalThis.RTCPeerConnection = originalRTC
  }
})

test("stale previous-attempt authority cannot become current", () => {
  const coord = new LiveCallCoordinator({participantId: "user-1", conversationId: "conv-1"})
  coord.callAttemptId = "attempt-new"; coord.mediaGeneration = 2; coord.status = CALL_STATUS.CONNECTING
  assert.equal(coord.mediaAttemptIsCurrent("attempt-old", 2, null), false)
  assert.equal(coord.mediaAttemptIsCurrent("attempt-new", 1, null), false)
})

test("terminal teardown stops local hardware and closes peer connection", () => {
  const stopped = []; let closed = false
  const audio = {kind: "audio", enabled: false, stop() { stopped.push("audio") }}
  const video = {kind: "video", enabled: true, stop() { stopped.push("video") }}
  const coord = new LiveCallCoordinator({participantId: "user-1", conversationId: "conv-1"})
  coord.callAttemptId = "attempt"; coord.status = CALL_STATUS.CONNECTING
  coord.localStream = {getTracks: () => [audio], getAudioTracks: () => [audio]}
  coord.localCameraStream = {getTracks: () => [video]}
  coord.peerConnection = {close() { closed = true }}
  coord.teardown("blocked")
  assert.deepEqual(stopped.sort(), ["audio", "video"])
  assert.equal(closed, true)
  assert.equal(coord.callAttemptId, null)
  assert.equal(coord.status, CALL_STATUS.TERMINAL)
})
