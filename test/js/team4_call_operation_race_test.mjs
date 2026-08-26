import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

function controllablePush() {
  const handlers = new Map()
  return {
    receive(kind, callback) { handlers.set(kind, callback); return this },
    fire(kind, payload) {
      const callback = handlers.get(kind)
      if (!callback) throw new Error(`missing ${kind} handler`)
      callback(payload)
    }
  }
}

test("T4-008: late Initiate error from dead operation cannot teardown a newer same-Conversation call", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  const oldPromise = coordinator.initiate("voice")
  coordinator.teardown("blocked")
  coordinator.status = CALL_STATUS.IDLE
  const newPromise = coordinator.initiate("voice")

  pushes[0].fire("error", {reason: "late-old-error"})
  await oldPromise.catch(() => {})

  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.callAttemptId, null)
  assert.equal(coordinator.role, "caller")

  pushes[1].fire("ok", {call_attempt_id: "new-authoritative-attempt"})
  await newPromise
  assert.equal(coordinator.callAttemptId, "new-authoritative-attempt")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
})

test("T4-009: late Accept error cannot teardown a newer incoming call", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  coordinator.callAttemptId = "old-attempt"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING
  const oldPromise = coordinator.accept()

  coordinator.teardown("ended")
  coordinator.status = CALL_STATUS.IDLE
  coordinator.handleIncomingCall({call_attempt_id: "new-attempt", caller_id: "p2", call_type: "voice"})

  pushes[0].fire("error", {reason: "late-old-error"})
  await oldPromise.catch(() => {})

  assert.equal(coordinator.callAttemptId, "new-attempt")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_INCOMING)
  assert.equal(coordinator.role, "callee")
})

test("T4-010: Accept re-applies outgoing audio gate before CONNECTING", async () => {
  const push = controllablePush()
  const audioTrack = {kind: "audio", enabled: true, stop() {}}
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })
  coordinator.callAttemptId = "attempt-a"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING
  coordinator.rawAudioTrack = audioTrack

  const pending = coordinator.accept()
  push.fire("ok", {call_attempt_id: "attempt-a"})
  await pending

  assert.equal(coordinator.status, CALL_STATUS.CONNECTING)
  assert.equal(audioTrack.enabled, false)
  assert.equal(coordinator.canTransmitOutgoingAudio(), false)
})

test("T4-011: Conversation A async success cannot mutate Conversation B", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  const oldPromise = coordinator.initiate("voice")
  coordinator.teardown("ended")
  coordinator.status = CALL_STATUS.IDLE
  coordinator.setConversationId("conversation-b")
  const newPromise = coordinator.initiate("voice")

  pushes[0].fire("ok", {call_attempt_id: "attempt-from-a"})
  const oldResult = await oldPromise
  assert.equal(oldResult.stale, true)
  assert.equal(coordinator.conversationId, "conversation-b")
  assert.equal(coordinator.callAttemptId, null)
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)

  pushes[1].fire("ok", {call_attempt_id: "attempt-from-b"})
  await newPromise
  assert.equal(coordinator.callAttemptId, "attempt-from-b")
})

test("T4-012: superseded Initiate error resolves stale and cannot reject or terminate the newer attempt", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  const oldPromise = coordinator.initiate("voice")
  coordinator.teardown("superseded")
  coordinator.status = CALL_STATUS.IDLE
  const newPromise = coordinator.initiate("voice")

  pushes[0].fire("error", {reason: "late-old-error"})
  const oldResult = await oldPromise

  assert.equal(oldResult.stale, true)
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.callAttemptId, null)
  assert.equal(coordinator.role, "caller")

  pushes[1].fire("ok", {call_attempt_id: "new-authoritative-attempt"})
  await newPromise
  assert.equal(coordinator.callAttemptId, "new-authoritative-attempt")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
})

test("T4-013: superseded Initiate timeout is stale and cannot terminate the replacement attempt", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  const oldPromise = coordinator.initiate("voice")
  coordinator.teardown("superseded")
  coordinator.status = CALL_STATUS.IDLE
  const newPromise = coordinator.initiate("voice")

  pushes[0].fire("timeout")
  const oldResult = await oldPromise

  assert.equal(oldResult.stale, true)
  assert.equal(oldResult.timeout, true)
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.role, "caller")

  pushes[1].fire("ok", {call_attempt_id: "new-authoritative-attempt"})
  await newPromise
  assert.equal(coordinator.callAttemptId, "new-authoritative-attempt")
})

test("T4-014: superseded Accept timeout is stale and cannot terminate a newer incoming call", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  coordinator.callAttemptId = "old-attempt"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING
  const oldPromise = coordinator.accept()

  coordinator.teardown("superseded")
  coordinator.status = CALL_STATUS.IDLE
  coordinator.handleIncomingCall({call_attempt_id: "new-attempt", caller_id: "p2", call_type: "voice"})

  pushes[0].fire("timeout")
  const oldResult = await oldPromise

  assert.equal(oldResult.stale, true)
  assert.equal(oldResult.timeout, true)
  assert.equal(coordinator.callAttemptId, "new-attempt")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_INCOMING)
  assert.equal(coordinator.role, "callee")
})

test("T4-015: old Initiate success after same-Conversation supersession is inert", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }}
  })

  const oldPromise = coordinator.initiate("voice")
  coordinator.teardown("superseded")
  coordinator.status = CALL_STATUS.IDLE
  const newPromise = coordinator.initiate("voice")

  pushes[0].fire("ok", {call_attempt_id: "old-attempt"})
  const oldResult = await oldPromise
  assert.equal(oldResult.stale, true)
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.callAttemptId, null)

  pushes[1].fire("ok", {call_attempt_id: "new-attempt"})
  await newPromise
  assert.equal(coordinator.callAttemptId, "new-attempt")
})

test("T4-016: old Accept success after supersession is inert and cannot begin WebRTC", async () => {
  const pushes = []
  let stateChanges = 0
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { const push = controllablePush(); pushes.push(push); return push }},
    onStateChange: () => { stateChanges++ }
  })

  coordinator.callAttemptId = "old-attempt"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING
  const oldPromise = coordinator.accept()

  coordinator.teardown("superseded")
  coordinator.status = CALL_STATUS.IDLE
  coordinator.handleIncomingCall({call_attempt_id: "new-attempt", caller_id: "p2", call_type: "voice"})
  const beforeLateSuccess = stateChanges

  pushes[0].fire("ok", {call_attempt_id: "old-attempt"})
  const oldResult = await oldPromise
  assert.equal(oldResult.stale, true)
  assert.equal(coordinator.callAttemptId, "new-attempt")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_INCOMING)
  assert.equal(coordinator.peerConnection, null)
  assert.equal(stateChanges, beforeLateSuccess)
})

test("T4-017: current Initiate error still rejects and terminates the current operation", async () => {
  const push = controllablePush()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })

  const pending = coordinator.initiate("voice")
  push.fire("error", {reason: "current-initiate-error"})
  await assert.rejects(pending, (error) => error?.reason === "current-initiate-error")
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.equal(coordinator.callAttemptId, null)
})

test("T4-018: current Initiate timeout still rejects and terminates the current operation", async () => {
  const push = controllablePush()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })

  const pending = coordinator.initiate("voice")
  push.fire("timeout")
  await assert.rejects(pending, /Call initiation timed out/)
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
})

test("T4-019: current Accept error still rejects and terminates the current operation", async () => {
  const push = controllablePush()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })
  coordinator.callAttemptId = "attempt-a"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING

  const pending = coordinator.accept()
  push.fire("error", {reason: "current-accept-error"})
  await assert.rejects(pending, (error) => error?.reason === "current-accept-error")
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.equal(coordinator.callAttemptId, null)
})

test("T4-020: current Accept timeout still rejects and terminates the current operation", async () => {
  const push = controllablePush()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })
  coordinator.callAttemptId = "attempt-a"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING

  const pending = coordinator.accept()
  push.fire("timeout")
  await assert.rejects(pending, /Call acceptance timed out/)
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
})

test("T4-021: teardown invalidates an outstanding Initiate success", async () => {
  const push = controllablePush()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })

  const pending = coordinator.initiate("voice")
  coordinator.teardown("blocked")
  push.fire("ok", {call_attempt_id: "late-attempt"})
  const result = await pending
  assert.equal(result.stale, true)
  assert.equal(coordinator.callAttemptId, null)
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
})

test("T4-022: teardown invalidates an outstanding Accept success", async () => {
  const push = controllablePush()
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "conversation-a",
    channel: {push() { return push }}
  })
  coordinator.callAttemptId = "attempt-a"
  coordinator.role = "callee"
  coordinator.status = CALL_STATUS.PENDING_INCOMING

  const pending = coordinator.accept()
  coordinator.teardown("blocked")
  push.fire("ok", {call_attempt_id: "attempt-a"})
  const result = await pending
  assert.equal(result.stale, true)
  assert.equal(coordinator.callAttemptId, null)
  assert.equal(coordinator.status, CALL_STATUS.TERMINAL)
  assert.equal(coordinator.peerConnection, null)
})
