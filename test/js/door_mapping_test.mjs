import assert from "node:assert/strict"
import test from "node:test"
import {DOORS, backendDoorFor} from "../../priv/static/assets/door_mapping.mjs"

test("every visible Door maps to its locked canonical backend value", () => {
  assert.deepEqual(Object.fromEntries(DOORS.map(({label, value}) => [label, value])), {
    "Deep Talk": "SOMETHING_REAL",
    "Vent": "JUST_TALK",
    "Distract": "KEEP_IT_LIGHT",
    "Advice": "EXPLORE"
  })
})

test("unmapped labels cannot produce a queue value", () => {
  assert.equal(backendDoorFor("Something invented"), null)
})
