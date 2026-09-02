import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator, attachMediaStream} from "../../priv/static/assets/live_call.mjs"

function phoenixPushOk(payload) {
  return {receive(kind, callback) { if (kind === "ok") queueMicrotask(() => callback(payload)); return this }}
}

function installWebRTC({getUserMedia}) {
  const originalNavigator = globalThis.navigator
  const originalRTC = globalThis.RTCPeerConnection
  let pc
  class FakeRTCPeerConnection {
    constructor(config) { this.config = config; this.iceConnectionState = "new"; this.localDescription = null; this.remoteDescription = null; this.transceivers = []; pc = this }
    addTransceiver(kind) {
      const sender = {track: null, async replaceTrack(track) { this.track = track }}
      const transceiver = {kind, sender, receiver: {track: {kind}}, direction: "sendrecv"}
      this.transceivers.push(transceiver)
      return transceiver
    }
    getSenders() { return this.transceivers.map(({sender}) => sender) }
    async createOffer() { return {type: "offer", sdp: "fake"} }
    async setLocalDescription(desc) { this.localDescription = desc }
    close() { this.closed = true }
  }
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: {mediaDevices: {getUserMedia}}})
  globalThis.RTCPeerConnection = FakeRTCPeerConnection
  return {
    get pc() { return pc },
    restore() {
      if (originalNavigator === undefined) delete globalThis.navigator
      else Object.defineProperty(globalThis, "navigator", {configurable: true, value: originalNavigator})
      if (originalRTC === undefined) delete globalThis.RTCPeerConnection
      else globalThis.RTCPeerConnection = originalRTC
    }
  }
}

function channel() {
  return {push(event) { return phoenixPushOk(event === "call:request_credentials" ? {ice_servers: [{urls: ["turn:relay.invalid:3478"]}]} : {}) }}
}

test("T4-001: CONNECTING establishes transport without requesting microphone or camera", async () => {
  let requests = 0
  const audio = {kind: "audio", enabled: true, stop() {}}
  const stream = {getAudioTracks: () => [audio], getVideoTracks: () => [], getTracks: () => [audio]}
  const env = installWebRTC({getUserMedia: async () => { requests++; return stream }})
  try {
    const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel: channel()})
    coord.callAttemptId = "a1"; coord.role = "caller"; coord.status = CALL_STATUS.CONNECTING
    await coord.initializeWebRTC(true)
    assert.equal(coord.status, CALL_STATUS.CONNECTING)
    assert.equal(requests, 0, "CONNECTING must not even request hardware capture")
    assert.equal(env.pc.transceivers.length, 2, "transport uses empty transceivers before capture")

    env.pc.iceConnectionState = "connected"
    env.pc.oniceconnectionstatechange()
    await new Promise((resolve) => setImmediate(resolve))
    assert.equal(coord.status, CALL_STATUS.ACTIVE)
    assert.equal(requests, 1, "hardware capture opens only after ACTIVE authority")
    assert.equal(audio.enabled, true)
    assert.equal(coord.transportAudioTransceiver.sender.track, audio)
  } finally { env.restore() }
})

test("T4-002: initial Video Call camera request is also deferred until ACTIVE", async () => {
  const constraints = []
  const audio = {kind: "audio", enabled: true, stop() {}}
  const video = {kind: "video", enabled: true, stop() {}}
  const stream = {getAudioTracks: () => [audio], getVideoTracks: () => [video], getTracks: () => [audio, video]}
  const env = installWebRTC({getUserMedia: async (c) => { constraints.push(c); return stream }})
  try {
    const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel: channel()})
    coord.callAttemptId = "a1"; coord.role = "caller"; coord.callType = "video"; coord.status = CALL_STATUS.CONNECTING
    await coord.initializeWebRTC(true)
    assert.deepEqual(constraints, [])
    env.pc.iceConnectionState = "connected"; env.pc.oniceconnectionstatechange()
    await new Promise((resolve) => setImmediate(resolve))
    assert.deepEqual(constraints, [{audio: true, video: true}])
    assert.equal(coord.transportVideoTransceiver.sender.track, video)
    assert.equal(coord.selfVideo, true)
  } finally { env.restore() }
})

test("T4-003: late ACTIVE permission resolution after terminal teardown stops stale tracks", async () => {
  let resolveMedia
  const stopped = []
  const audio = {kind: "audio", enabled: true, stop() { stopped.push("audio") }}
  const stream = {getAudioTracks: () => [audio], getVideoTracks: () => [], getTracks: () => [audio]}
  const env = installWebRTC({getUserMedia: () => new Promise((resolve) => { resolveMedia = resolve })})
  try {
    const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel: channel()})
    coord.callAttemptId = "a1"; coord.role = "caller"; coord.status = CALL_STATUS.CONNECTING
    await coord.initializeWebRTC(true)
    env.pc.iceConnectionState = "connected"; env.pc.oniceconnectionstatechange()
    await new Promise((resolve) => setImmediate(resolve))
    coord.teardown("blocked")
    resolveMedia(stream)
    await new Promise((resolve) => setImmediate(resolve))
    assert.deepEqual(stopped, ["audio"])
    assert.equal(coord.localStream, null)
    assert.equal(coord.status, CALL_STATUS.TERMINAL)
  } finally { env.restore() }
})

test("T4-004: CONNECTING remote playback is fail-closed", () => {
  const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1"})
  coord.callAttemptId = "a1"; coord.status = CALL_STATUS.CONNECTING
  let plays = 0
  const element = {srcObject: null, play() { plays++; return Promise.resolve() }, pause() {}}
  attachMediaStream(element, {id: "remote"}, coord)
  assert.equal(plays, 0)
  assert.equal(element.srcObject, null)
})

test("T4-005: effects, reactions and camera capture cannot gain authority in CONNECTING", async () => {
  let gum = 0; let pushes = 0
  const originalNavigator = globalThis.navigator
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: {mediaDevices: {getUserMedia: async () => { gum++; return {getTracks: () => []} }}}})
  try {
    const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel: {push() { pushes++; return phoenixPushOk({}) }}})
    coord.callAttemptId = "a1"; coord.status = CALL_STATUS.CONNECTING
    await coord.setVoiceExpression("warm_radio")
    await coord.sendReaction("heart")
    const camera = await coord.acquireCameraStream()
    assert.equal(camera, null)
    assert.equal(gum, 0)
    assert.equal(pushes, 0)
    assert.equal(coord.voiceEffectPreset, "plain")
  } finally {
    if (originalNavigator === undefined) delete globalThis.navigator
    else Object.defineProperty(globalThis, "navigator", {configurable: true, value: originalNavigator})
  }
})


function controllablePush() {
  const handlers = new Map()
  return { receive(kind, callback) { handlers.set(kind, callback); return this }, fire(kind, payload) { handlers.get(kind)?.(payload) } }
}

test("T4-006: late Accept success after terminal teardown is inert", async () => {
  const push = controllablePush()
  const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel: {push(event) { assert.equal(event, "call:accept"); return push }}})
  coord.callAttemptId = "a1"; coord.role = "callee"; coord.status = CALL_STATUS.PENDING_INCOMING
  const pending = coord.accept()
  coord.teardown("blocked")
  push.fire("ok", {call_attempt_id: "a1"})
  const result = await pending
  assert.equal(result.stale, true)
  assert.equal(coord.callAttemptId, null)
  assert.notEqual(coord.status, CALL_STATUS.CONNECTING)
})

test("T4-007: late Initiate success after terminal teardown cannot rebind attempt authority", async () => {
  const push = controllablePush()
  const coord = new LiveCallCoordinator({participantId: "p1", conversationId: "c1", channel: {push(event) { assert.equal(event, "call:initiate"); return push }}})
  const pending = coord.initiate("voice")
  coord.teardown("ended")
  push.fire("ok", {call_attempt_id: "dead-attempt"})
  const result = await pending
  assert.equal(result.stale, true)
  assert.equal(coord.callAttemptId, null)
  assert.notEqual(coord.status, CALL_STATUS.CONNECTING)
  assert.notEqual(coord.status, CALL_STATUS.ACTIVE)
})
