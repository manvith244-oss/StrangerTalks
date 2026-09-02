import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

function installRtcMocks() {
  const oldDescription = globalThis.RTCSessionDescription
  const oldCandidate = globalThis.RTCIceCandidate
  globalThis.RTCSessionDescription = class { constructor(value) { Object.assign(this, value) } }
  globalThis.RTCIceCandidate = class { constructor(value) { Object.assign(this, value) } }
  return () => {
    if (oldDescription === undefined) delete globalThis.RTCSessionDescription
    else globalThis.RTCSessionDescription = oldDescription
    if (oldCandidate === undefined) delete globalThis.RTCIceCandidate
    else globalThis.RTCIceCandidate = oldCandidate
  }
}

function activeCallB() {
  const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "conversation-a"})
  coord.callAttemptId = "call-b"
  coord.role = "caller"
  coord.status = CALL_STATUS.ACTIVE
  coord.mediaGeneration = 7
  coord.activeAt = 1_788_345_600
  return coord
}

test("V4 current Call B end remains authoritative and closes its PeerConnection", () => {
  const coord = activeCallB()
  let closed = 0
  coord.peerConnection = {close() { closed++ }}

  coord.handleCallEnded({call_attempt_id: "call-b", reason: "current_end"})

  assert.equal(closed, 1)
  assert.equal(coord.peerConnection, null)
  assert.equal(coord.callAttemptId, null)
  assert.equal(coord.status, CALL_STATUS.TERMINAL)
})

test("V5 repeated stale terminal events from Call A remain inert against Call B", () => {
  const coord = activeCallB()
  let closed = 0
  const pc = {close() { closed++ }}
  coord.peerConnection = pc

  for (let i = 0; i < 5; i++) {
    coord.handleCallEnded({call_attempt_id: "call-a", reason: `stale-${i}`})
  }

  assert.equal(coord.callAttemptId, "call-b")
  assert.equal(coord.status, CALL_STATUS.ACTIVE)
  assert.equal(coord.mediaGeneration, 7)
  assert.equal(coord.peerConnection, pc)
  assert.equal(closed, 0)
})

test("V7 stale Call A SDP cannot mutate Call B PeerConnection", async () => {
  const restore = installRtcMocks()
  try {
    const coord = activeCallB()
    let descriptions = 0
    coord.peerConnection = {
      remoteDescription: null,
      async setRemoteDescription() { descriptions++ },
      async createAnswer() { throw new Error("stale offer must not be answered") },
      async setLocalDescription() { throw new Error("stale offer must not set local description") }
    }

    await coord.handleSignal({
      call_attempt_id: "call-a",
      media_generation: 7,
      sender_id: "p2",
      signal: {type: "offer", sdp: "stale"}
    })

    assert.equal(descriptions, 0)
    assert.equal(coord.pendingCandidates.length, 0)
    assert.equal(coord.callAttemptId, "call-b")
  } finally {
    restore()
  }
})

test("V8 stale Call A ICE and stale media generation are both inert", async () => {
  const restore = installRtcMocks()
  try {
    const coord = activeCallB()
    let candidates = 0
    coord.peerConnection = {
      remoteDescription: {type: "answer"},
      async addIceCandidate() { candidates++ }
    }

    await coord.handleSignal({
      call_attempt_id: "call-a",
      media_generation: 7,
      sender_id: "p2",
      signal: {candidate: "old-call"}
    })
    await coord.handleSignal({
      call_attempt_id: "call-b",
      media_generation: 6,
      sender_id: "p2",
      signal: {candidate: "old-generation"}
    })

    assert.equal(candidates, 0)
    assert.equal(coord.pendingCandidates.length, 0)
    assert.equal(coord.callAttemptId, "call-b")
    assert.equal(coord.mediaGeneration, 7)
  } finally {
    restore()
  }
})
