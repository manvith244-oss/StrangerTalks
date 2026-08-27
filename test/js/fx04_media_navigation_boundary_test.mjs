import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"

import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

function track(kind, stopped) {
  return {
    kind,
    enabled: true,
    stop() { stopped.push(kind) }
  }
}

function stream(tracks) {
  return {
    getTracks: () => tracks,
    getAudioTracks: () => tracks.filter((item) => item.kind === "audio"),
    getVideoTracks: () => tracks.filter((item) => item.kind === "video")
  }
}

function controlledChannel() {
  const pushes = []
  return {
    pushes,
    push(event, payload) {
      const handlers = new Map()
      const token = {
        event,
        payload,
        receive(status, callback) {
          handlers.set(status, callback)
          return token
        },
        reply(status, value = {}) {
          handlers.get(status)?.(value)
        }
      }
      pushes.push(token)
      return token
    }
  }
}

function activeCoordinator({callType = "voice"} = {}) {
  const channel = controlledChannel()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conv-1",
    channel
  })
  coordinator.status = CALL_STATUS.ACTIVE
  coordinator.callAttemptId = "attempt-1"
  coordinator.role = "caller"
  coordinator.callType = callType
  return {coordinator, channel}
}

test("X04-01 voice active -> navigate /chats ends call and stops microphone", () => {
  const {coordinator, channel} = activeCoordinator({callType: "voice"})
  const stopped = []
  coordinator.localStream = stream([track("audio", stopped)])

  coordinator.setConversationSurfaceActive(false)

  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.equal(coordinator.callAttemptId, null)
  assert.deepEqual(stopped, ["audio"])
  assert.deepEqual(channel.pushes.map(({event}) => event), ["call:end"])
})

test("X04-02 video active -> navigate /you ends call and stops camera + mic", () => {
  const {coordinator, channel} = activeCoordinator({callType: "video"})
  const stopped = []
  coordinator.localStream = stream([track("audio", stopped), track("video", stopped)])

  coordinator.setConversationSurfaceActive(false)

  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.deepEqual(stopped.sort(), ["audio", "video"])
  assert.deepEqual(channel.pushes.map(({event}) => event), ["call:end"])
})

test("X04-03 camera active -> browser Back closes camera authority", () => {
  const {coordinator} = activeCoordinator({callType: "video"})
  const stopped = []
  const camera = track("camera", stopped)
  coordinator.localCameraStream = stream([camera])
  coordinator.rawCameraTrack = camera

  // Browser Back resolves through the same Conversation -> non-Conversation surface boundary.
  coordinator.setConversationSurfaceActive(false)

  assert.ok(stopped.length >= 1)
  assert.equal(coordinator.localCameraStream, null)
  assert.equal(coordinator.rawCameraTrack, null)
  assert.equal(coordinator.selfVideo, false)
})

test("X04-04 screen share active -> route change closes defensive screen-share stream", () => {
  const {coordinator} = activeCoordinator()
  const stopped = []
  coordinator.localScreenStream = stream([track("screen", stopped)])
  coordinator.screenSharing = true

  coordinator.setConversationSurfaceActive(false)

  assert.deepEqual(stopped, ["screen"])
  assert.equal(coordinator.localScreenStream, null)
  assert.equal(coordinator.screenSharing, false)

  const source = fs.readFileSync(new URL("../../priv/static/assets/live_call.mjs", import.meta.url), "utf8")
  assert.equal(source.includes("getDisplayMedia("), false, "V1 must not silently invent screen-share acquisition")
})

test("X04-05 ringing -> navigate away declines and hidden surface cannot ring", () => {
  const channel = controlledChannel()
  const coordinator = new LiveCallCoordinator({participantId: "p2", conversationId: "conv-1", channel})
  coordinator.handleIncomingCall({call_attempt_id: "attempt-ring", caller_id: "p1", call_type: "voice"})
  assert.equal(coordinator.status, CALL_STATUS.PENDING_INCOMING)

  coordinator.setConversationSurfaceActive(false)

  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.equal(channel.pushes.at(-1).event, "call:decline")

  coordinator.handleIncomingCall({call_attempt_id: "attempt-hidden", caller_id: "p1", call_type: "voice"})
  assert.notEqual(coordinator.callAttemptId, "attempt-hidden")
  assert.equal(channel.pushes.at(-1).payload.call_attempt_id, "attempt-hidden")
  assert.equal(channel.pushes.at(-1).event, "call:decline")
})

test("X04-06 Accept and navigation race fails closed and ends server-active winner", async () => {
  const channel = controlledChannel()
  const coordinator = new LiveCallCoordinator({participantId: "p2", conversationId: "conv-1", channel})
  coordinator.handleIncomingCall({call_attempt_id: "attempt-race", caller_id: "p1", call_type: "voice"})

  const accepting = coordinator.accept()
  const acceptPush = channel.pushes.find(({event}) => event === "call:accept")
  coordinator.setConversationSurfaceActive(false)
  const declinePush = channel.pushes.find(({event}) => event === "call:decline")

  // Server serialized Accept first. Local navigation still wins privacy authority.
  acceptPush.reply("ok", {status: "active", call_attempt_id: "attempt-race"})
  declinePush.reply("error", {reason: "invalid_transition"})
  const accepted = await accepting

  assert.equal(accepted.stale, true)
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.ok(channel.pushes.some(({event, payload}) => event === "call:end" && payload.call_attempt_id === "attempt-race"))
})

test("X04-07 End and navigation race is idempotent", async () => {
  const {coordinator, channel} = activeCoordinator()

  await coordinator.end()
  coordinator.setConversationSurfaceActive(false)

  assert.equal(channel.pushes.filter(({event}) => event === "call:end").length, 1)
  assert.equal(coordinator.callAttemptId, null)
})

test("X04-08 rapid Back/Forward cannot resurrect old media attempt", async () => {
  const channel = controlledChannel()
  const coordinator = new LiveCallCoordinator({participantId: "p2", conversationId: "conv-1", channel})
  coordinator.handleIncomingCall({call_attempt_id: "attempt-old", caller_id: "p1", call_type: "voice"})

  coordinator.setConversationSurfaceActive(false)
  coordinator.setConversationSurfaceActive(true)
  coordinator.setConversationSurfaceActive(false)
  coordinator.setConversationSurfaceActive(true)

  await coordinator.handleCallAccepted({call_attempt_id: "attempt-old", active_at: 123})

  assert.notEqual(coordinator.callAttemptId, "attempt-old")
  assert.notEqual(coordinator.status, CALL_STATUS.CONNECTING)
  assert.equal(coordinator.peerConnection, null)
})

test("X04-09 background -> foreground after navigation cannot restore ringing/capture", () => {
  const channel = controlledChannel()
  const coordinator = new LiveCallCoordinator({participantId: "p2", conversationId: "conv-1", channel})
  coordinator.setConversationSurfaceActive(false)

  // Reconnect/event replay after background/foreground while still away.
  coordinator.handleIncomingCall({call_attempt_id: "attempt-replayed", caller_id: "p1", call_type: "video"})

  assert.notEqual(coordinator.callAttemptId, "attempt-replayed")
  assert.equal(coordinator.localStream, null)
  assert.equal(coordinator.localCameraStream, null)
  assert.equal(channel.pushes.at(-1).event, "call:decline")
})

test("X04-10 navigation End cleans every track, playback and peer resource", () => {
  const {coordinator} = activeCoordinator({callType: "video"})
  const stopped = []
  const audio = track("audio", stopped)
  const video = track("video", stopped)
  const camera = track("camera", stopped)
  const screen = track("screen", stopped)
  coordinator.localStream = stream([audio, video])
  coordinator.localCameraStream = stream([camera])
  coordinator.localScreenStream = stream([screen])
  coordinator.rawAudioTrack = audio
  coordinator.rawCameraTrack = camera
  coordinator.remoteElement = {srcObject: {}, pause() { this.paused = true }}
  let closed = false
  coordinator.peerConnection = {close() { closed = true }}

  coordinator.setConversationSurfaceActive(false)

  assert.ok(stopped.includes("audio"))
  assert.ok(stopped.includes("video"))
  assert.ok(stopped.includes("camera"))
  assert.ok(stopped.includes("screen"))
  assert.equal(coordinator.localStream, null)
  assert.equal(coordinator.localCameraStream, null)
  assert.equal(coordinator.localScreenStream, null)
  assert.equal(coordinator.remoteElement, null)
  assert.equal(coordinator.peerConnection, null)
  assert.equal(closed, true)

  const appSource = fs.readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(appSource, /app\.liveCall\?\.setConversationSurfaceActive\(name === "conversation"\)/)
  assert.match(appSource, /function releaseVoiceCaptureForNavigation\(\)[\s\S]*app\.voice\.captureRequestId\+\+[\s\S]*closeVoiceStream\(\)/)
})
