import assert from "node:assert/strict"
import test from "node:test"
import {DOORS, backendDoorFor, doorLabelForBackend, queuePayloadFor} from "../../priv/static/assets/door_mapping.mjs"

test("every visible Door maps to its locked canonical backend value", () => {
  assert.deepEqual(Object.fromEntries(DOORS.map(({label, value}) => [label, value])), {
    "Deep Talk": "SOMETHING_REAL",
    "Vent": "JUST_TALK",
    "Distract": "KEEP_IT_LIGHT",
    "Advice": "EXPLORE"
  })
  assert.equal(doorLabelForBackend("JUST_TALK"), "Vent")
  assert.equal(doorLabelForBackend("EXPLORE"), "Advice")
})

test("Hang Out stays outside the canonical pair-matching Door taxonomy", () => {
  assert.equal(DOORS.length, 4)
  assert.equal(backendDoorFor("Hang Out"), null)
  assert.equal(doorLabelForBackend("HANGOUTS"), null)
  assert.equal(queuePayloadFor("Hang Out"), null)
})

test("unmapped labels cannot produce a queue value", () => {
  assert.equal(backendDoorFor("Something invented"), null)
  assert.equal(doorLabelForBackend("UNKNOWN"), null)
  assert.equal(queuePayloadFor("Something invented"), null)
})

test("browser queue payload contains only the selected Door", () => {
  assert.deepEqual(queuePayloadFor("Deep Talk"), {door_type: "SOMETHING_REAL"})
  assert.deepEqual(Object.keys(queuePayloadFor("Advice")), ["door_type"])
})
