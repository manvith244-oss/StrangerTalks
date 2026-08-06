import assert from "node:assert/strict"
import test from "node:test"
import {createMatchedTransitionTracker, createReconnectCountdownController, matchedConversationId, reconnectDisplayState, reconnectStateRecord, remainingAvailabilitySeconds, unavailableReconnectState} from "../../priv/static/assets/bond_reconnect.mjs"

test("private availability restores only the participant's own Door and expiry", () => {
  const expires = "2026-08-06T00:15:00Z"
  const state = reconnectDisplayState({status: "waiting_for_mutual_availability", door_type: "EXPLORE", expires_at: expires}, "bond-a", Date.parse("2026-08-06T00:00:00Z"))
  assert.deepEqual(state, {relationship_id: "bond-a", status: "waiting_for_mutual_availability", door_type: "EXPLORE", expires_at: expires})
  assert.equal(Object.keys(state).some((key) => key.startsWith("other_")), false)
})

test("expired availability returns to idle without trusting stale display state", () => {
  const result = reconnectDisplayState({status: "waiting_for_mutual_availability", door_type: "JUST_TALK", expires_at: "2026-08-06T00:00:00Z"}, "bond-a", Date.parse("2026-08-06T00:00:01Z"))
  assert.deepEqual(result, {relationship_id: "bond-a", status: "idle"})
  assert.equal(remainingAvailabilitySeconds("2026-08-06T00:00:00Z", Date.parse("2026-08-06T00:00:01Z")), 0)
})

test("change and cancel display states replace only one stable Bond cache record", () => {
  const first = reconnectStateRecord({relationship_id: "bond-a", status: "waiting_for_mutual_availability", door_type: "JUST_TALK"}, "2026-08-06T00:00:00Z")
  const changed = reconnectStateRecord({relationship_id: "bond-a", status: "waiting_for_mutual_availability", door_type: "EXPLORE"}, "2026-08-06T00:01:00Z")
  const cancelled = reconnectStateRecord({relationship_id: "bond-a", status: "idle"}, "2026-08-06T00:02:00Z")
  assert.equal(first.id, changed.id)
  assert.equal(changed.id, cancelled.id)
  assert.equal(cancelled.value.status, "idle")
})

test("start and status matched responses use one canonical conversation transition", () => {
  const tracker = createMatchedTransitionTracker()
  const start = {status: "matched", conversation_id: "conversation-a", origin: "bond_reconnect"}
  const status = {status: "matched", conversation_id: "conversation-b"}
  assert.equal(tracker.claim(start), "conversation-a")
  tracker.release("conversation-a")
  assert.equal(tracker.claim(status), "conversation-b")
  assert.equal(matchedConversationId(status), "conversation-b")
})

test("direct matched response plus duplicate match_found push joins once", () => {
  const tracker = createMatchedTransitionTracker()
  const payload = {status: "matched", conversation_id: "conversation-a"}
  assert.equal(tracker.claim(payload), "conversation-a")
  assert.equal(tracker.claim(payload), null)
  assert.equal(tracker.current(), "conversation-a")
})

test("temporary join failure releases the transition for safe retry without losing matched state", () => {
  const tracker = createMatchedTransitionTracker()
  const state = reconnectDisplayState({status: "matched", conversation_id: "conversation-a"}, "bond-a")
  assert.deepEqual(state, {relationship_id: "bond-a", status: "matched", conversation_id: "conversation-a"})
  tracker.claim(state)
  tracker.release("conversation-a")
  assert.equal(tracker.claim(state), "conversation-a")
})

test("unavailable state clears prior sensitive match and waiting fields", () => {
  assert.deepEqual(unavailableReconnectState("bond-a"), {relationship_id: "bond-a", status: "unavailable"})
  assert.equal(Object.values(unavailableReconnectState("bond-a")).some((value) => String(value).includes("participant")), false)
  assert.equal("conversation_id" in unavailableReconnectState("bond-a"), false)
})

test("countdown controller replaces and cleans timers after every terminal UI transition", () => {
  const started = []
  const stopped = []
  const controller = createReconnectCountdownController((callback, delay) => { const id = {callback, delay}; started.push(id); return id }, (id) => stopped.push(id))
  controller.start(() => {})
  controller.start(() => {})
  assert.equal(stopped[0], started[0])
  controller.stop()
  assert.equal(stopped[1], started[1])
  assert.equal(controller.active(), false)
})
