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

function controllablePush(onAck = () => {}) {
  const handlers = new Map()
  return {
    handlers,
    receive(kind, callback) {
      handlers.set(kind, callback)
      return this
    },
    fire(kind, payload = {}) {
      if (kind === "ok") onAck(payload)
      handlers.get(kind)?.(payload)
    }
  }
}

async function flush() {
  await new Promise((resolve) => setImmediate(resolve))
  await new Promise((resolve) => setImmediate(resolve))
}

function installRtcHarness() {
  const originalRTC = globalThis.RTCPeerConnection
  const pcs = []

  class FakeRTCPeerConnection {
    constructor() {
      this.iceConnectionState = "new"
      this.localDescription = null
      this.remoteDescription = null
      this.closed = false
      this.senders = []
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

    async createOffer() { return { type: "offer", sdp: "fake-offer" } }
    async setLocalDescription(desc) { this.localDescription = desc }
    async setRemoteDescription(desc) { this.remoteDescription = desc }
    async addIceCandidate() {}
    setConfiguration() {}
    restartIce() {}
    close() { this.closed = true }
  }

  globalThis.RTCPeerConnection = FakeRTCPeerConnection

  return {
    pcs,
    restore() {
      if (originalRTC === undefined) delete globalThis.RTCPeerConnection
      else globalThis.RTCPeerConnection = originalRTC
    }
  }
}

test("T05-P1: fatal call:end timeout preserves exact-attempt retry authority until server acknowledgement", async () => {
  const attemptId = "attempt-fatal-ack"
  const events = []
  const endPushes = []
  const serverAttempt = { call_attempt_id: attemptId, status: "ACTIVE" }
  let credentialRequests = 0

  const channel = {
    push(event, payload) {
      events.push({ event, payload })

      if (event === "call:request_credentials") {
        credentialRequests += 1
        if (credentialRequests > 1) return phoenixPushError()
        return phoenixPushOk({
          ice_servers: [{ urls: ["turn:127.0.0.1:3478?transport=udp"] }]
        })
      }

      if (event === "call:end") {
        const push = controllablePush(() => {
          serverAttempt.status = "ENDED"
        })
        endPushes.push(push)
        return push
      }

      return phoenixPushOk({})
    }
  }

  const harness = installRtcHarness()

  try {
    const coord = new LiveCallCoordinator({
      participantId: "user-a",
      conversationId: "conv-a",
      channel
    })
    coord.callAttemptId = attemptId
    coord.role = "caller"
    coord.status = CALL_STATUS.CONNECTING
    coord.mediaGeneration = 1

    await coord.initializeWebRTC(true)
    const firstPeerConnection = harness.pcs.at(-1)

    firstPeerConnection.iceConnectionState = "failed"
    firstPeerConnection.oniceconnectionstatechange()
    await flush()

    assert.equal(firstPeerConnection.closed, true)
    assert.equal(coord.callAttemptId, null)
    assert.equal(coord.status, CALL_STATUS.TERMINAL)
    assert.equal(serverAttempt.status, "ACTIVE", "no call:end acknowledgement means server authority is still ACTIVE")
    assert.equal(
      events.filter(({ event, payload }) => event === "call:end" && payload?.call_attempt_id === attemptId).length,
      1
    )

    assert.equal(
      coord.applyCallStateSync({
        call_attempt_id: attemptId,
        status: serverAttempt.status,
        role: "caller",
        call_type: "voice",
        media_generation: 1
      }),
      true,
      "reconnect/sync must be able to surface the still-ACTIVE exact server attempt"
    )

    assert.equal(
      coord.fatalTerminateCurrentAttempt({
        callAttemptId: attemptId,
        mediaGeneration: 1,
        peerConnection: null,
        reason: "ice_failed_retry_before_timeout"
      }),
      false,
      "an in-flight fatal termination remains bounded while its first call:end push is unresolved"
    )
    assert.equal(endPushes.length, 1)

    endPushes[0].fire("timeout")
    assert.equal(serverAttempt.status, "ACTIVE")

    assert.equal(
      coord.fatalTerminateCurrentAttempt({
        callAttemptId: attemptId,
        mediaGeneration: 1,
        peerConnection: null,
        reason: "ice_failed_retry_after_timeout"
      }),
      true,
      "timeout must release local retry authority for the same exact ACTIVE server attempt"
    )
    assert.equal(endPushes.length, 2)

    endPushes[1].fire("ok", { status: "ended" })
    assert.equal(serverAttempt.status, "ENDED")

    assert.equal(
      coord.applyCallStateSync({
        call_attempt_id: attemptId,
        status: "ACTIVE",
        role: "caller",
        call_type: "voice",
        media_generation: 1
      }),
      true
    )
    assert.equal(
      coord.fatalTerminateCurrentAttempt({
        callAttemptId: attemptId,
        mediaGeneration: 1,
        peerConnection: null,
        reason: "duplicate_after_ack"
      }),
      false,
      "server-acknowledged fatal termination remains bounded/idempotent"
    )
    assert.equal(endPushes.length, 2)

    const newerPeerConnection = {
      closed: false,
      close() { this.closed = true }
    }
    coord.callAttemptId = "attempt-newer"
    coord.status = CALL_STATUS.ACTIVE
    coord.mediaGeneration = 9
    coord.peerConnection = newerPeerConnection

    assert.equal(
      coord.fatalTerminateCurrentAttempt({
        callAttemptId: attemptId,
        mediaGeneration: 1,
        peerConnection: null,
        reason: "stale_attempt_cleanup"
      }),
      false
    )
    assert.equal(coord.callAttemptId, "attempt-newer")
    assert.equal(coord.status, CALL_STATUS.ACTIVE)
    assert.equal(coord.peerConnection, newerPeerConnection)
    assert.equal(newerPeerConnection.closed, false)
    assert.equal(endPushes.length, 2)
  } finally {
    harness.restore()
  }
})
