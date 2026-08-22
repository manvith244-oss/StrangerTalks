import assert from "node:assert/strict"
import test from "node:test"
import {CONVERSATION_LANGUAGES, DOORS, backendDoorFor, doorLabelForBackend, queuePayloadFor} from "../../priv/static/assets/door_mapping.mjs"

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

test("unmapped labels cannot produce a queue value", () => {
  assert.equal(backendDoorFor("Something invented"), null)
  assert.equal(doorLabelForBackend("UNKNOWN"), null)
  assert.equal(queuePayloadFor("Something invented"), null)
})

test("browser queue payload requires a controlled explicit Conversation Language", () => {
  assert.deepEqual(CONVERSATION_LANGUAGES.map(({value}) => value), ["en", "te", "hi"])
  assert.equal(queuePayloadFor("Deep Talk", null), null)
  assert.equal(queuePayloadFor("Deep Talk", "xx"), null)
  assert.deepEqual(queuePayloadFor("Deep Talk", "te"), {
    door_type: "SOMETHING_REAL",
    conversation_language: "te"
  })
})
