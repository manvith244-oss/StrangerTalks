import assert from "node:assert/strict"
import test from "node:test"

import {
  CALL_STATUS,
  LiveCallCoordinator
} from "../../priv/static/assets/live_call.mjs"
import {
  voiceCaptureStillAuthorized
} from "../../priv/static/assets/voice_notes.mjs"
import {
  viewOnceDraftMatchesRuntime
} from "../../priv/static/assets/view_once.mjs"

function deferredChannel() {
  const pushes = []
  return {
    pushes,
    push(event, payload) {
      const handlers = new Map()
      const push = {
        receive(kind, callback) {
          handlers.set(kind, callback)
          return push
        }
      }
      pushes.push({event, payload, handlers})
      return push
    }
  }
}

function fakeStream({audio = false, video = false} = {}) {
  const tracks = []
  const makeTrack = (kind) => ({
    kind,
    enabled: true,
    stopped: false,
    stop() { this.stopped = true }
  })
  if (audio) tracks.push(makeTrack("audio"))
  if (video) tracks.push(makeTrack("video"))
  return {
    tracks,
    getTracks: () => tracks,
    getAudioTracks: () => tracks.filter((track) => track.kind === "audio"),
    getVideoTracks: () => tracks.filter((track) => track.kind === "video")
  }
}

function installNavigator(value) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "navigator")
  Object.defineProperty(globalThis, "navigator", {configurable: true, value})
  return () => {
    if (previous) Object.defineProperty(globalThis, "navigator", previous)
    else delete globalThis.navigator
  }
}

test("T11-CALL-001: late Accept success after terminal teardown cannot resurrect CONNECTING", async () => {
  const channel = deferredChannel()
  const coordinator = new LiveCallCoordinator({
    channel,
    participantId: "callee",
    conversationId: "conversation-a"
  })

  coordinator.handleIncomingCall({
    call_attempt_id: "call-a",
    caller_id: "caller",
    call_type: "voice"
  })
  assert.equal(coordinator.status, CALL_STATUS.PENDING_INCOMING)

  const acceptPromise = coordinator.accept()
  assert.equal(channel.pushes.length, 1)
  assert.equal(channel.pushes[0].event, "call:accept")
  assert.equal(channel.pushes[0].payload.call_attempt_id, "call-a")

  coordinator.teardown("conversation_terminal")
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.equal(coordinator.callAttemptId, null)

  channel.pushes[0].handlers.get("ok")({call_attempt_id: "call-a"})
  await acceptPromise

  const state = coordinator.getState()
  assert.equal(state.callAttemptId, null)
  assert.equal(state.hasActiveCall, false)
  assert.notEqual(state.status, CALL_STATUS.CONNECTING)
  assert.notEqual(state.status, CALL_STATUS.ACTIVE)
})

test("T11-CALL-002: late initiate success after terminal teardown cannot rebind stale call authority", async () => {
  const channel = deferredChannel()
  const coordinator = new LiveCallCoordinator({
    channel,
    participantId: "caller",
    conversationId: "conversation-a"
  })

  const initiatePromise = coordinator.initiate("voice")
  assert.equal(channel.pushes.length, 1)
  assert.equal(channel.pushes[0].event, "call:initiate")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)

  coordinator.teardown("conversation_terminal")
  assert.equal(coordinator.callAttemptId, null)
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)

  channel.pushes[0].handlers.get("ok")({call_attempt_id: "late-call-a"})
  await initiatePromise

  const state = coordinator.getState()
  assert.equal(state.callAttemptId, null)
  assert.equal(state.hasActiveCall, false)
  assert.notEqual(state.status, CALL_STATUS.CONNECTING)
  assert.notEqual(state.status, CALL_STATUS.ACTIVE)
})

test("T11-VOICE-001: voice permission authority is invalidated by terminal, request supersession, and Conversation A to B", () => {
  const base = {
    requestId: 8,
    currentRequestId: 8,
    conversationId: "conversation-a",
    currentConversationId: "conversation-a",
    epochId: "epoch-a",
    currentEpochId: "epoch-a",
    conversationAvailable: true
  }

  assert.equal(voiceCaptureStillAuthorized(base), true)
  assert.equal(voiceCaptureStillAuthorized({...base, conversationAvailable: false}), false)
  assert.equal(voiceCaptureStillAuthorized({...base, currentRequestId: 9}), false)
  assert.equal(voiceCaptureStillAuthorized({...base, currentConversationId: "conversation-b"}), false)
  assert.equal(voiceCaptureStillAuthorized({...base, currentEpochId: "epoch-b"}), false)
})

test("T11-VOICE-002: late camera permission after terminal teardown stops the acquired track and returns no stream", async () => {
  let resolvePermission
  const permission = new Promise((resolve) => { resolvePermission = resolve })
  const stream = fakeStream({video: true})
  const restoreNavigator = installNavigator({mediaDevices: {getUserMedia: () => permission}})

  try {
    const coordinator = new LiveCallCoordinator({
      participantId: "participant-a",
      conversationId: "conversation-a"
    })
    coordinator.callAttemptId = "call-a"
    coordinator.status = CALL_STATUS.ACTIVE

    const acquisition = coordinator.acquireCameraStream()
    coordinator.teardown("conversation_terminal")
    resolvePermission(stream)

    assert.equal(await acquisition, null)
    assert.equal(stream.tracks[0].stopped, true)
    assert.equal(coordinator.localCameraStream, null)
    assert.equal(coordinator.rawCameraTrack, null)
  } finally {
    restoreNavigator()
  }
})

test("T11-CALL-003: CONNECTING keeps outgoing audio closed until ACTIVE authority", () => {
  const coordinator = new LiveCallCoordinator({participantId: "participant-a", conversationId: "conversation-a"})
  const stream = fakeStream({audio: true})
  coordinator.callAttemptId = "call-a"
  coordinator.localStream = stream
  coordinator.rawAudioTrack = stream.tracks[0]
  coordinator.status = CALL_STATUS.CONNECTING

  coordinator.applyOutgoingAudioGate()
  assert.equal(stream.tracks[0].enabled, false)
  assert.equal(coordinator.canTransmitOutgoingAudio(), false)

  coordinator.status = CALL_STATUS.ACTIVE
  coordinator.applyOutgoingAudioGate()
  assert.equal(stream.tracks[0].enabled, true)
  assert.equal(coordinator.canTransmitOutgoingAudio(), true)
})

test("T11-MODE-001: ephemeral drafts remain bound to their originating Conversation/epoch", () => {
  const draft = {originConversationId: "conversation-a", originEpochId: "epoch-a"}
  assert.equal(viewOnceDraftMatchesRuntime(draft, "conversation-a", "epoch-a"), true)
  assert.equal(viewOnceDraftMatchesRuntime(draft, "conversation-b", "epoch-a"), false)
  assert.equal(viewOnceDraftMatchesRuntime(draft, "conversation-a", "epoch-b"), false)
})
