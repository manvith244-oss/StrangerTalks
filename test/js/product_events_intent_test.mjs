import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  createIntentSelectionObserver,
  createProductEventTracker
} from "../../priv/static/assets/product_events.mjs"

function setup() {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => "flow-intent",
    sink: async (event) => events.push(event)
  })
  return {events, observer: createIntentSelectionObserver(tracker)}
}

test("first intent emits selected with a stable canonical code", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.select("SOMETHING_REAL"), true)
  assert.deepEqual(events, [{
    name: "st_intent_selected",
    properties: {
      flow_attempt_id: "flow-intent",
      test_traffic: false,
      intent_family: "four_doors",
      intent_value: "SOMETHING_REAL",
      selection_kind: "first"
    }
  }])
})

test("changing intent before admission emits a bounded reversal", async () => {
  const {events, observer} = setup()

  await observer.select("JUST_TALK")
  assert.equal(await observer.select("EXPLORE"), true)

  assert.deepEqual(events[1], {
    name: "st_intent_changed",
    properties: {
      flow_attempt_id: "flow-intent",
      test_traffic: false,
      from_intent: "JUST_TALK",
      to_intent: "EXPLORE"
    }
  })
})

test("repeating the same Door does not manufacture an intent change", async () => {
  const {events, observer} = setup()

  await observer.select("KEEP_IT_LIGHT")
  assert.equal(await observer.select("KEEP_IT_LIGHT"), false)
  assert.equal(events.length, 1)
})

test("intent changes stop after authoritative queue admission", async () => {
  const {events, observer} = setup()

  await observer.select("SOMETHING_REAL")
  observer.markQueueAdmitted()
  assert.equal(await observer.select("EXPLORE"), false)
  assert.equal(events.length, 1)
})

test("arrival instrumentation reads the canonical data-door code rather than visible Door copy", () => {
  const source = readFileSync(new URL("../../priv/static/assets/arrival_first_minute.mjs", import.meta.url), "utf8")

  assert.match(source, /createIntentSelectionObserver\(productEvents\)/)
  assert.match(source, /intentEvents\.select\(door\.dataset\.door\)/)
  assert.doesNotMatch(source, /intentEvents\.select\([^)]*textContent/)
  assert.doesNotMatch(source, /Deep Talk person|Vent user|personality/i)
})
