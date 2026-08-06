import assert from "node:assert/strict"
import test from "node:test"
import {reconnectDisplayState, reconnectStateRecord, remainingAvailabilitySeconds} from "../../priv/static/assets/bond_reconnect.mjs"

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
