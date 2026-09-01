import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

function installRtcDescriptionMocks() {
  const previous = {
    RTCSessionDescription: globalThis.RTCSessionDescription,
    RTCIceCandidate: globalThis.RTCIceCandidate
  }
  globalThis.RTCSessionDescription = class RTCSessionDescription {
    constructor(value) { Object.assign(this, value) }
  }
  globalThis.RTCIceCandidate = class RTCIceCandidate {
    constructor(value) { Object.assign(this, value) }
  }
  return () => {
    if (previous.RTCSessionDescription === undefined) delete globalThis.RTCSessionDescription
    else globalThis.RTCSessionDescription = previous.RTCSessionDescription
    if (previous.RTCIceCandidate === undefined) delete globalThis.RTCIceCandidate
    else globalThis.RTCIceCandidate = previous.RTCIceCandidate
  }
}

function createPeerConnection() {
  return {
    remoteDescription: null,
    localDescription: null,
    candidates: [],
    async setRemoteDescription(description) { this.remoteDescription = description },
    async createAnswer() { return {type: "answer", sdp: "answer-sdp"} },
    async setLocalDescription(description) { this.localDescription = description },
    async addIceCandidate(candidate) { this.candidates.push(candidate) }
  }
}

function createCoordinator(sentSignals = []) {
  const channel = {
    push(event, payload) {
      sentSignals.push({event, payload})
      return {receive() { return this }}
    }
  }
  const coord = new LiveCallCoordinator({
    participantId: "callee",
    conversationId: "conv-1",
    channel
  })
  coord.callAttemptId = "attempt-1"
  coord.status = CALL_STATUS.CONNECTING
  coord.mediaGeneration = 1
  return coord
}

test("queued SDP offer received before peer connection is applied and answered once peer connection exists", async () => {
  const restore = installRtcDescriptionMocks()
  const sentSignals = []
  try {
    const coord = createCoordinator(sentSignals)
    await coord.handleSignal({
      call_attempt_id: "attempt-1",
      media_generation: 1,
      sender_id: "caller",
      signal: {type: "offer", sdp: "offer-sdp"}
    })
    assert.equal(coord.pendingCandidates.length, 1)

    coord.peerConnection = createPeerConnection()
    await coord.flushPendingCandidates()

    assert.equal(coord.peerConnection.remoteDescription?.type, "offer")
    assert.equal(coord.peerConnection.localDescription?.type, "answer")
    assert.equal(coord.pendingCandidates.length, 0)
    const answers = sentSignals.filter(({event, payload}) => event === "call:signal" && payload.signal?.type === "answer")
    assert.equal(answers.length, 1)
  } finally {
    restore()
  }
})

test("queued SDP answer received before peer connection is applied once peer connection exists", async () => {
  const restore = installRtcDescriptionMocks()
  const sentSignals = []
  try {
    const coord = createCoordinator(sentSignals)
    coord.participantId = "caller"
    await coord.handleSignal({
      call_attempt_id: "attempt-1",
      media_generation: 1,
      sender_id: "callee",
      signal: {type: "answer", sdp: "answer-sdp"}
    })
    assert.equal(coord.pendingCandidates.length, 1)

    coord.peerConnection = createPeerConnection()
    await coord.flushPendingCandidates()

    assert.equal(coord.peerConnection.remoteDescription?.type, "answer")
    assert.equal(coord.pendingCandidates.length, 0)
    assert.equal(sentSignals.length, 0)
  } finally {
    restore()
  }
})

test("SDP offer received after peer connection exists is still answered immediately", async () => {
  const restore = installRtcDescriptionMocks()
  const sentSignals = []
  try {
    const coord = createCoordinator(sentSignals)
    coord.peerConnection = createPeerConnection()

    await coord.handleSignal({
      call_attempt_id: "attempt-1",
      media_generation: 1,
      sender_id: "caller",
      signal: {type: "offer", sdp: "offer-sdp"}
    })

    assert.equal(coord.peerConnection.remoteDescription?.type, "offer")
    assert.equal(coord.peerConnection.localDescription?.type, "answer")
    const answers = sentSignals.filter(({event, payload}) => event === "call:signal" && payload.signal?.type === "answer")
    assert.equal(answers.length, 1)
  } finally {
    restore()
  }
})
