import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

const liveSource = readFileSync(new URL("../../priv/static/assets/live_call.mjs", import.meta.url), "utf8")
const appSource = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const htmlSource = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")

test("T4-SCREEN-001: V1 contains no display-capture API or Share Screen control", () => {
  assert.doesNotMatch(liveSource, /getDisplayMedia/)
  assert.doesNotMatch(appSource, /getDisplayMedia/)
  assert.doesNotMatch(htmlSource, /Share Screen|btn-call-screen-share/i)
})

test("T4-SCREEN-002: stale or forged screen-share media projection cannot create client capture authority", () => {
  const coordinator = new LiveCallCoordinator({participantId: "p1", conversationId: "c1"})
  coordinator.callAttemptId = "a1"
  coordinator.status = CALL_STATUS.ACTIVE

  coordinator.handleMediaUpdated({
    call_attempt_id: "a1",
    media_generation: 2,
    active_media: {screen_share: {requester_id: "p1", media_request_id: "forged"}}
  })

  const state = coordinator.getState()
  assert.equal(state.screenSharing, false)
  assert.equal(coordinator.localScreenStream, null)
})

test("T4-SCREEN-003: forged projection fails closed by stopping and clearing any stale local display track", () => {
  let stops = 0
  const staleTrack = {kind: "video", stop() { stops++ }}
  const coordinator = new LiveCallCoordinator({participantId: "p1", conversationId: "c1"})
  coordinator.callAttemptId = "a1"
  coordinator.status = CALL_STATUS.ACTIVE
  coordinator.screenSharing = true
  coordinator.localScreenStream = {getTracks: () => [staleTrack]}

  coordinator.handleMediaUpdated({
    call_attempt_id: "a1",
    media_generation: 2,
    active_media: {screen_share: {requester_id: "p1", media_request_id: "forged"}}
  })

  assert.equal(stops, 1)
  assert.equal(coordinator.screenSharing, false)
  assert.equal(coordinator.localScreenStream, null)
})

test("T4-SCREEN-004: even a stale wrong-attempt projection cannot preserve hidden screen-share authority", () => {
  let stops = 0
  const coordinator = new LiveCallCoordinator({participantId: "p1", conversationId: "c1"})
  coordinator.callAttemptId = "current-attempt"
  coordinator.status = CALL_STATUS.ACTIVE
  coordinator.screenSharing = true
  coordinator.localScreenStream = {getTracks: () => [{kind: "video", stop() { stops++ }}]}

  coordinator.handleMediaUpdated({
    call_attempt_id: "stale-attempt",
    media_generation: 99,
    active_media: {screen_share: {requester_id: "p1", media_request_id: "stale-forged"}}
  })

  assert.equal(stops, 1)
  assert.equal(coordinator.screenSharing, false)
  assert.equal(coordinator.localScreenStream, null)
  assert.equal(coordinator.callAttemptId, "current-attempt")
})

test("T4-SCREEN-005: Conversation replacement clears any stale display stream and keeps V1 screen share absent", () => {
  let stops = 0
  const coordinator = new LiveCallCoordinator({participantId: "p1", conversationId: "conversation-a"})
  coordinator.screenSharing = true
  coordinator.localScreenStream = {getTracks: () => [{kind: "video", stop() { stops++ }}]}

  coordinator.setConversationId("conversation-b")

  assert.equal(stops, 1)
  assert.equal(coordinator.conversationId, "conversation-b")
  assert.equal(coordinator.screenSharing, false)
  assert.equal(coordinator.localScreenStream, null)
})

test("T4-SCREEN-006: reconnect-style forged projection remains false/null with zero display capability", () => {
  const coordinator = new LiveCallCoordinator({participantId: "p1", conversationId: "c1"})
  coordinator.callAttemptId = "reconnected-attempt"
  coordinator.status = CALL_STATUS.ACTIVE

  for (const generation of [2, 3, 4]) {
    coordinator.handleMediaUpdated({
      call_attempt_id: "reconnected-attempt",
      media_generation: generation,
      active_media: {screen_share: {requester_id: "p1", media_request_id: `forged-${generation}`}}
    })
    assert.equal(coordinator.screenSharing, false)
    assert.equal(coordinator.localScreenStream, null)
  }
})
