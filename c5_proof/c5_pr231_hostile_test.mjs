import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

function controlledPush() {
  const handlers = new Map()
  return {
    receive(kind, callback) {
      handlers.set(kind, callback)
      return this
    },
    fire(kind, payload = {}) {
      handlers.get(kind)?.(payload)
    }
  }
}

function coordinatorWithPushes(pushFactory = controlledPush) {
  const pushes = []
  const channel = {
    push(event, payload) {
      assert.equal(event, "call:end")
      const push = pushFactory(event, payload)
      pushes.push({event, payload, push})
      return push
    }
  }
  return {coord: new LiveCallCoordinator({participantId: "c5-user", conversationId: "c5-conv", channel}), pushes}
}

function makeCurrent(coord, attemptId, generation = 1, peerConnection = null) {
  coord.callAttemptId = attemptId
  coord.mediaGeneration = generation
  coord.status = CALL_STATUS.CONNECTING
  coord.peerConnection = peerConnection
}

function resurface(coord, attemptId, generation = 1) {
  assert.equal(coord.applyCallStateSync({
    call_attempt_id: attemptId,
    status: "ACTIVE",
    role: "caller",
    call_type: "voice",
    media_generation: generation
  }), true)
}

test("C5 hostile: timeout/error release exact-attempt retry authority and first settlement wins", () => {
  for (const terminalSignal of ["timeout", "error"]) {
    const {coord, pushes} = coordinatorWithPushes()
    const attempt = `attempt-${terminalSignal}`
    makeCurrent(coord, attempt, 3)

    assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: 3, peerConnection: null}), true)
    assert.equal(pushes.length, 1)
    assert.equal(coord.fatalTerminationPendingAttemptIds.has(attempt), true)
    assert.equal(coord.fatalTerminatedAttemptIds.has(attempt), false)

    pushes[0].push.fire(terminalSignal)
    assert.equal(coord.fatalTerminationPendingAttemptIds.has(attempt), false)
    assert.equal(coord.fatalTerminatedAttemptIds.has(attempt), false)

    // A late success after timeout/error must not retroactively consume retry authority.
    pushes[0].push.fire("ok")
    assert.equal(coord.fatalTerminatedAttemptIds.has(attempt), false)

    resurface(coord, attempt, 3)
    assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: 3, peerConnection: null}), true)
    assert.equal(pushes.length, 2)
    pushes[1].push.fire("ok")
    assert.equal(coord.fatalTerminationPendingAttemptIds.has(attempt), false)
    assert.equal(coord.fatalTerminatedAttemptIds.has(attempt), true)

    resurface(coord, attempt, 3)
    assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: 3, peerConnection: null}), false)
    assert.equal(pushes.length, 2)
  }
})

test("C5 hostile: authoritative call:ended acknowledges a pending fatal termination even when push acknowledgement is lost", () => {
  const {coord, pushes} = coordinatorWithPushes()
  const attempt = "attempt-authoritative-ended"
  makeCurrent(coord, attempt, 4)

  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: 4, peerConnection: null}), true)
  assert.equal(pushes.length, 1)
  assert.equal(coord.fatalTerminationPendingAttemptIds.has(attempt), true)

  coord.handleCallEnded({call_attempt_id: attempt, reason: "ended"})
  assert.equal(coord.fatalTerminationPendingAttemptIds.has(attempt), false)
  assert.equal(coord.fatalTerminatedAttemptIds.has(attempt), true)
  assert.equal(coord.status, CALL_STATUS.TERMINAL)
})

test("C5 hostile: late Attempt A acknowledgement and ended event cannot tear down newer Attempt B", () => {
  const {coord, pushes} = coordinatorWithPushes()
  const attemptA = "attempt-A"
  const attemptB = "attempt-B"
  makeCurrent(coord, attemptA, 1)

  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attemptA, mediaGeneration: 1, peerConnection: null}), true)
  assert.equal(coord.fatalTerminationPendingAttemptIds.has(attemptA), true)

  const peerB = {closed: false, close() { this.closed = true }}
  makeCurrent(coord, attemptB, 9, peerB)
  coord.status = CALL_STATUS.ACTIVE

  pushes[0].push.fire("ok")
  assert.equal(coord.callAttemptId, attemptB)
  assert.equal(coord.mediaGeneration, 9)
  assert.equal(coord.status, CALL_STATUS.ACTIVE)
  assert.equal(coord.peerConnection, peerB)
  assert.equal(peerB.closed, false)

  coord.handleCallEnded({call_attempt_id: attemptA, reason: "late_A"})
  assert.equal(coord.callAttemptId, attemptB)
  assert.equal(coord.status, CALL_STATUS.ACTIVE)
  assert.equal(coord.peerConnection, peerB)
  assert.equal(peerB.closed, false)
})

test("C5 hostile: stale attempt, generation mismatch, and peerConnection mismatch never emit call:end", () => {
  const {coord, pushes} = coordinatorWithPushes()
  const currentPeer = {close() {}}
  const otherPeer = {close() {}}
  makeCurrent(coord, "current-attempt", 7, currentPeer)
  coord.status = CALL_STATUS.ACTIVE

  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: "stale-attempt", mediaGeneration: 7, peerConnection: currentPeer}), false)
  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: "current-attempt", mediaGeneration: 6, peerConnection: currentPeer}), false)
  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: "current-attempt", mediaGeneration: 7, peerConnection: otherPeer}), false)
  assert.equal(pushes.length, 0)
  assert.equal(coord.callAttemptId, "current-attempt")
  assert.equal(coord.status, CALL_STATUS.ACTIVE)
})

test("C5 hostile: pending and acknowledged bookkeeping stay bounded", () => {
  const {coord, pushes} = coordinatorWithPushes()

  for (let index = 0; index < 40; index += 1) {
    const attempt = `pending-${index}`
    makeCurrent(coord, attempt, index + 1)
    assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: index + 1, peerConnection: null}), true)
  }
  assert.ok(coord.fatalTerminationPendingAttemptIds.size <= 32)

  for (const {push} of pushes) push.fire("ok")
  assert.ok(coord.fatalTerminationPendingAttemptIds.size <= 32)
  assert.ok(coord.fatalTerminatedAttemptIds.size <= 32)
})

test("C5 hostile: missing Phoenix receive callback does not strand pending authority", () => {
  const pushes = []
  const channel = {
    push(event, payload) {
      pushes.push({event, payload})
      return {}
    }
  }
  const coord = new LiveCallCoordinator({participantId: "c5-user", conversationId: "c5-conv", channel})
  const attempt = "attempt-no-receive"
  makeCurrent(coord, attempt, 2)

  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: 2, peerConnection: null}), true)
  assert.equal(coord.fatalTerminationPendingAttemptIds.has(attempt), false)
  assert.equal(coord.fatalTerminatedAttemptIds.has(attempt), false)
  assert.equal(pushes.length, 1)

  resurface(coord, attempt, 2)
  assert.equal(coord.fatalTerminateCurrentAttempt({callAttemptId: attempt, mediaGeneration: 2, peerConnection: null}), true)
  assert.equal(pushes.length, 2)
})
