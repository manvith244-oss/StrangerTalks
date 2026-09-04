import assert from "node:assert/strict"
import test from "node:test"
import { LiveCallCoordinator } from "../../priv/static/assets/live_call.mjs"

function controllablePush() {
  const handlers = new Map()
  return {
    handlers,
    receive(kind, callback) {
      handlers.set(kind, callback)
      return this
    },
    fire(kind, payload) {
      handlers.get(kind)?.(payload)
    }
  }
}

test("T05-NET-003 RED: TURN credential request registers the existing Phoenix timeout path and rejects cleanly", async () => {
  const push = controllablePush()
  const events = []
  const coord = new LiveCallCoordinator({
    participantId: "user-a",
    conversationId: "conv-a",
    channel: {
      push(event, payload) {
        events.push({ event, payload })
        return push
      }
    }
  })
  coord.callAttemptId = "attempt-timeout"

  const pending = coord.fetchCredentials()

  assert.equal(events.length, 1)
  assert.equal(events[0].event, "call:request_credentials")
  assert.equal(events[0].payload.call_attempt_id, "attempt-timeout")
  assert.equal(
    push.handlers.has("timeout"),
    true,
    "credential fetch must not remain unresolved after the Channel push timeout"
  )

  push.fire("timeout")
  await assert.rejects(pending, /timed out/i)
})
