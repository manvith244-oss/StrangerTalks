import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

function controllablePush() {
  const handlers = new Map()
  return {
    receive(kind, callback) {
      handlers.set(kind, callback)
      return this
    },
    fire(kind, payload) {
      handlers.get(kind)?.(payload)
    }
  }
}

test("late call A initiate error cannot teardown newer same-shaped call B", async () => {
  const pushes = []
  const coordinator = new LiveCallCoordinator({
    participantId: "p1",
    conversationId: "c1",
    channel: {
      push(event) {
        assert.equal(event, "call:initiate")
        const push = controllablePush()
        pushes.push(push)
        return push
      }
    }
  })

  const callA = coordinator.initiate("voice").catch((error) => error)
  coordinator.teardown("ended")

  const callB = coordinator.initiate("voice")
  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.callAttemptId, null)

  pushes[0].fire("error", {reason: "late_call_a_transport_error"})
  await callA

  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.callAttemptId, null)

  pushes[1].fire("ok", {call_attempt_id: "call-b-authoritative"})
  await callB

  assert.equal(coordinator.status, CALL_STATUS.PENDING_OUTGOING)
  assert.equal(coordinator.callAttemptId, "call-b-authoritative")
})
