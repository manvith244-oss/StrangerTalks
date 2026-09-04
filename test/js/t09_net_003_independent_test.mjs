import test from "node:test"
import assert from "node:assert/strict"

import {LiveCallCoordinator, CALL_STATUS} from "../../priv/static/assets/live_call.mjs"

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const nextTurn = () => new Promise((resolve) => setImmediate(resolve))

class ControlledPush {
  constructor() {
    this.handlers = new Map()
  }

  receive(kind, callback) {
    this.handlers.set(kind, callback)
    return this
  }

  fire(kind, payload) {
    const callback = this.handlers.get(kind)
    if (callback) callback(payload)
  }
}

function makeChannel({credentialMode = "manual", credentialPayload = {ice_servers: [{urls: "turn:127.0.0.1:3478"}]}} = {}) {
  const events = []
  const credentialPushes = []

  return {
    events,
    credentialPushes,
    push(event, payload) {
      events.push({event, payload})
      const push = new ControlledPush()
      if (event === "call:request_credentials") {
        credentialPushes.push(push)
        if (credentialMode !== "manual") {
          queueMicrotask(() => push.fire(credentialMode, credentialPayload))
        }
      }
      return push
    }
  }
}

class FakePeerConnection {
  static instances = []

  constructor(config = {}) {
    this.config = config
    this.iceConnectionState = "new"
    this.remoteDescription = null
    this.localDescription = null
    this.closed = 0
    this.restartCount = 0
    this.configurations = []
    this.remoteDescriptionCalls = 0
    this.iceCandidateCalls = 0
    this.audioSender = {track: null, replaceTrack: async (track) => { this.audioSender.track = track }}
    this.videoSender = {track: null, replaceTrack: async (track) => { this.videoSender.track = track }}
    FakePeerConnection.instances.push(this)
  }

  addTransceiver(kind) {
    return {sender: kind === "audio" ? this.audioSender : this.videoSender}
  }

  async createOffer() {
    return {type: "offer", sdp: "fake-offer"}
  }

  async createAnswer() {
    return {type: "answer", sdp: "fake-answer"}
  }

  async setLocalDescription(description) {
    this.localDescription = description
  }

  async setRemoteDescription(description) {
    this.remoteDescriptionCalls += 1
    this.remoteDescription = description
  }

  async addIceCandidate() {
    this.iceCandidateCalls += 1
  }

  setConfiguration(config) {
    this.configurations.push(config)
    this.config = config
  }

  restartIce() {
    this.restartCount += 1
  }

  getSenders() {
    return [this.audioSender, this.videoSender]
  }

  close() {
    this.closed += 1
  }
}

async function withGlobals(values, fn) {
  const previous = new Map()
  for (const [key, value] of Object.entries(values)) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, {value, configurable: true, writable: true})
  }

  try {
    return await fn()
  } finally {
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor)
      else delete globalThis[key]
    }
  }
}

function coordinator(channel = makeChannel()) {
  return new LiveCallCoordinator({
    channel,
    participantId: "self",
    conversationId: "conv-t09"
  })
}

function armCurrent(c, {attempt = "call-A", generation = 1, status = CALL_STATUS.CONNECTING, peerConnection = null} = {}) {
  c.callAttemptId = attempt
  c.mediaGeneration = generation
  c.status = status
  c.peerConnection = peerConnection
  return c
}

function endEvents(channel) {
  return channel.events.filter(({event}) => event === "call:end")
}

async function settleWithin(promise, ms = 150) {
  const marker = Symbol("timeout")
  const result = await Promise.race([
    promise.then(() => ({kind: "settled"}), (error) => ({kind: "rejected", error})),
    delay(ms).then(() => marker)
  ])
  return result === marker ? {kind: "hung"} : result
}

test("fatal current-attempt termination emits exactly one call:end and stale authority cannot terminate Call B", async () => {
  const channel = makeChannel()
  const c = coordinator(channel)
  const pcA = new FakePeerConnection()
  armCurrent(c, {attempt: "call-A", generation: 7, peerConnection: pcA})

  assert.equal(typeof c.fatalTerminateCurrentAttempt, "function", "NET-003 fatal authority helper must exist")
  assert.equal(c.fatalTerminateCurrentAttempt({callAttemptId: "call-A", mediaGeneration: 7, peerConnection: pcA, reason: "connection_error"}), true)
  assert.equal(c.fatalTerminateCurrentAttempt({callAttemptId: "call-A", mediaGeneration: 7, peerConnection: pcA, reason: "connection_error"}), false)
  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["call-A"])
  assert.equal(pcA.closed, 1)

  const pcB = new FakePeerConnection()
  armCurrent(c, {attempt: "call-B", generation: 11, status: CALL_STATUS.ACTIVE, peerConnection: pcB})
  const localB = {id: "local-B", getTracks: () => []}
  c.localStream = localB

  assert.equal(c.fatalTerminateCurrentAttempt({callAttemptId: "call-A", mediaGeneration: 7, peerConnection: pcA, reason: "stale_fatal"}), false)
  assert.equal(c.callAttemptId, "call-B")
  assert.equal(c.peerConnection, pcB)
  assert.equal(c.localStream, localB)
  assert.equal(pcB.closed, 0)
  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["call-A"])
})

test("fatal attempt dedupe is bounded and pre-attempt negative control is safe", () => {
  const channel = makeChannel()
  const c = coordinator(channel)

  assert.equal(typeof c.fatalTerminateCurrentAttempt, "function")
  assert.equal(c.fatalTerminateCurrentAttempt(), false)
  assert.equal(endEvents(channel).length, 0)

  for (let index = 0; index < 40; index += 1) {
    const attempt = `bounded-${index}`
    const pc = new FakePeerConnection()
    armCurrent(c, {attempt, generation: index + 1, peerConnection: pc})
    assert.equal(c.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: index + 1, peerConnection: pc}), true)
  }

  assert.ok(c.fatalTerminatedAttemptIds instanceof Set)
  assert.ok(c.fatalTerminatedAttemptIds.size <= 32, `fatal dedupe leaked to ${c.fatalTerminatedAttemptIds.size} entries`)
  assert.equal(c.fatalTerminatedAttemptIds.has("bounded-0"), false, "oldest fatal attempt should be pruned")
  assert.equal(c.fatalTerminatedAttemptIds.has("bounded-39"), true)
})

test("Phoenix Push credential timeout settles instead of hanging", async () => {
  const channel = makeChannel()
  const c = coordinator(channel)
  armCurrent(c, {attempt: "timeout-direct", generation: 1})

  const pending = c.fetchCredentials()
  await nextTurn()
  assert.equal(channel.credentialPushes.length, 1)
  channel.credentialPushes[0].fire("timeout")

  const outcome = await settleWithin(pending)
  assert.notEqual(outcome.kind, "hung", "credential timeout did not settle")
  assert.equal(outcome.kind, "rejected")
  assert.match(String(outcome.error?.message || outcome.error), /TURN credential request timed out/)
})

test("fatal TURN credential timeout terminates the exact current attempt once", async () => {
  const channel = makeChannel()
  const c = coordinator(channel)
  armCurrent(c, {attempt: "timeout-fatal", generation: 3})

  const initializing = c.initializeWebRTC(false)
  await nextTurn()
  assert.equal(channel.credentialPushes.length, 1)
  channel.credentialPushes[0].fire("timeout")

  const outcome = await settleWithin(initializing)
  assert.equal(outcome.kind, "settled", "initializeWebRTC must settle after credential timeout")
  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["timeout-fatal"])
  assert.equal(c.callAttemptId, null)
  assert.equal(c.status, CALL_STATUS.TERMINAL)
})

test("fatal credential error terminates the exact current attempt once", async () => {
  const channel = makeChannel({credentialMode: "error", credentialPayload: {reason: "relay_credentials_unavailable"}})
  const c = coordinator(channel)
  armCurrent(c, {attempt: "credential-error", generation: 4})

  await c.initializeWebRTC(false)

  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["credential-error"])
  assert.equal(c.callAttemptId, null)
  assert.equal(c.status, CALL_STATUS.TERMINAL)
})

test("stale credential timeout from Call A settles but cannot kill newer Call B", async () => {
  const channel = makeChannel()
  const c = coordinator(channel)
  armCurrent(c, {attempt: "call-A", generation: 1})

  const initializingA = c.initializeWebRTC(false)
  await nextTurn()
  assert.equal(channel.credentialPushes.length, 1)

  const pcB = new FakePeerConnection()
  const mediaB = {id: "media-B", getTracks: () => []}
  armCurrent(c, {attempt: "call-B", generation: 2, status: CALL_STATUS.ACTIVE, peerConnection: pcB})
  c.localStream = mediaB

  channel.credentialPushes[0].fire("timeout")
  const outcome = await settleWithin(initializingA)

  assert.equal(outcome.kind, "settled", "stale credential timeout must still settle its abandoned async operation")
  assert.equal(c.callAttemptId, "call-B")
  assert.equal(c.status, CALL_STATUS.ACTIVE)
  assert.equal(c.peerConnection, pcB)
  assert.equal(c.localStream, mediaB)
  assert.equal(pcB.closed, 0)
  assert.equal(endEvents(channel).length, 0)
})

test("required media permission denial terminates the exact ACTIVE attempt once", async () => {
  FakePeerConnection.instances = []
  const channel = makeChannel({credentialMode: "ok"})
  const c = coordinator(channel)
  armCurrent(c, {attempt: "permission-denied", generation: 5})

  await withGlobals({
    RTCPeerConnection: FakePeerConnection,
    navigator: {mediaDevices: {getUserMedia: async () => { throw new Error("NotAllowedError") }}}
  }, async () => {
    await c.initializeWebRTC(false)
    const pc = c.peerConnection
    assert.ok(pc)
    c.status = CALL_STATUS.ACTIVE
    await c.activateLocalMedia("permission-denied", 5, pc)
  })

  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["permission-denied"])
  assert.equal(c.callAttemptId, null)
  assert.equal(c.status, CALL_STATUS.TERMINAL)
})

test("first current ICE failure refreshes TURN credentials and restartIce without terminating", async () => {
  const refreshed = {ice_servers: [{urls: "turn:127.0.0.1:3478?transport=udp", username: "fresh", credential: "fresh"}]}
  const channel = makeChannel({credentialMode: "ok", credentialPayload: refreshed})
  const c = coordinator(channel)
  const pc = new FakePeerConnection({iceTransportPolicy: "relay"})
  armCurrent(c, {attempt: "ice-recover", generation: 6, peerConnection: pc})

  await c.handleIceFailure()

  assert.equal(pc.restartCount, 1)
  assert.equal(pc.configurations.length, 1)
  assert.equal(pc.configurations[0].iceTransportPolicy, "relay")
  assert.deepEqual(pc.configurations[0].iceServers, refreshed.ice_servers)
  assert.equal(c.callAttemptId, "ice-recover")
  assert.equal(c.status, CALL_STATUS.CONNECTING)
  assert.equal(endEvents(channel).length, 0)
})

test("fatal credential refresh failure after ICE failure ends current attempt exactly once", async () => {
  const channel = makeChannel({credentialMode: "error", credentialPayload: {reason: "refresh_failed"}})
  const c = coordinator(channel)
  const pc = new FakePeerConnection({iceTransportPolicy: "relay"})
  armCurrent(c, {attempt: "ice-fatal", generation: 8, peerConnection: pc})

  await c.handleIceFailure()
  await c.handleIceFailure()

  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["ice-fatal"])
  assert.equal(pc.closed, 1)
  assert.equal(c.callAttemptId, null)
})

test("transient disconnected state does not prematurely terminate current call", async () => {
  FakePeerConnection.instances = []
  const channel = makeChannel({credentialMode: "ok"})
  const c = coordinator(channel)
  armCurrent(c, {attempt: "disconnect-transient", generation: 9})

  await withGlobals({RTCPeerConnection: FakePeerConnection, navigator: {}}, async () => {
    await c.initializeWebRTC(false)
    const pc = c.peerConnection
    assert.ok(pc)

    pc.iceConnectionState = "connected"
    pc.oniceconnectionstatechange()
    await nextTurn()
    assert.equal(c.status, CALL_STATUS.ACTIVE)

    pc.iceConnectionState = "disconnected"
    pc.oniceconnectionstatechange()
    await nextTurn()

    assert.equal(c.callAttemptId, "disconnect-transient")
    assert.equal(c.status, CALL_STATUS.ACTIVE)
    assert.equal(c.peerConnection, pc)
    assert.equal(pc.closed, 0)
    assert.equal(endEvents(channel).length, 0)
  })
})

test("late call:end from superseded Call A and stale signals cannot terminate or mutate Call B", async () => {
  const channel = makeChannel()
  const c = coordinator(channel)
  const pcB = new FakePeerConnection()
  const mediaB = {id: "media-B", getTracks: () => []}
  armCurrent(c, {attempt: "call-B", generation: 12, status: CALL_STATUS.ACTIVE, peerConnection: pcB})
  c.localStream = mediaB

  c.handleCallEnded({call_attempt_id: "call-A", reason: "late_end"})
  await c.handleSignal({call_attempt_id: "call-A", media_generation: 11, signal: {type: "offer", sdp: "stale"}, sender_id: "peer"})
  await c.handleSignal({call_attempt_id: "call-B", media_generation: 11, signal: {type: "offer", sdp: "wrong-generation"}, sender_id: "peer"})

  assert.equal(c.callAttemptId, "call-B")
  assert.equal(c.status, CALL_STATUS.ACTIVE)
  assert.equal(c.peerConnection, pcB)
  assert.equal(c.localStream, mediaB)
  assert.equal(pcB.closed, 0)
  assert.equal(pcB.remoteDescriptionCalls, 0)
  assert.equal(pcB.iceCandidateCalls, 0)
  assert.equal(c.pendingCandidates.length, 0)
  assert.equal(endEvents(channel).length, 0)
})

test("navigation terminalization blocks same-attempt resurrection", () => {
  const channel = makeChannel()
  const c = coordinator(channel)
  const pc = new FakePeerConnection()
  armCurrent(c, {attempt: "nav-A", generation: 2, status: CALL_STATUS.ACTIVE, peerConnection: pc})

  c.setConversationSurfaceActive(false)

  assert.equal(c.callAttemptId, null)
  assert.equal(c.status, CALL_STATUS.TERMINAL)
  assert.equal(pc.closed, 1)
  assert.equal(c.navigationBlockedAttemptIds.has("nav-A"), true)
  assert.deepEqual(endEvents(channel).map(({payload}) => payload.call_attempt_id), ["nav-A"])

  const accepted = c.applyCallStateSync({
    call_attempt_id: "nav-A",
    role: "caller",
    call_type: "voice",
    status: "ACTIVE",
    media_generation: 2
  })
  assert.equal(accepted, false)
  assert.equal(c.callAttemptId, null)
  assert.notEqual(c.status, CALL_STATUS.ACTIVE)
})
