import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

test("T05-COMMS-001: late call:end from Call A cannot terminate current Call B", () => {
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a"
  })

  coordinator.callAttemptId = "call-b"
  coordinator.role = "caller"
  coordinator.status = CALL_STATUS.ACTIVE
  coordinator.activeAt = 1_788_345_600

  const livePeerConnection = {
    closed: false,
    close() { this.closed = true }
  }
  coordinator.peerConnection = livePeerConnection

  coordinator.handleCallEnded({
    call_attempt_id: "call-a",
    reason: "late_end_from_superseded_attempt"
  })

  assert.equal(coordinator.callAttemptId, "call-b")
  assert.equal(coordinator.status, CALL_STATUS.ACTIVE)
  assert.equal(coordinator.role, "caller")
  assert.equal(coordinator.activeAt, 1_788_345_600)
  assert.equal(coordinator.peerConnection, livePeerConnection)
  assert.equal(livePeerConnection.closed, false)
})
