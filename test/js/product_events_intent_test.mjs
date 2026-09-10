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

test("changing intent before queue join emits a bounded reversal", async () => {
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

test("intent changes stop after authoritative queue join", async () => {
  const {events, observer} = setup()

  await observer.select("SOMETHING_REAL")
  observer.markQueueJoined()
  assert.equal(await observer.select("EXPLORE"), false)
  assert.equal(events.length, 1)
})

test("arrival and queue runtime share one flow-scoped intent observer", () => {
  const arrival = readFileSync(new URL("../../priv/static/assets/arrival_first_minute.mjs", import.meta.url), "utf8")
  const runtime = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")

  assert.match(arrival, /import \{[^}]*intentEvents[^}]*\} from "\.\/product_events\.mjs"/)
  assert.match(arrival, /intentEvents\.select\(door\.dataset\.door\)/)
  assert.doesNotMatch(arrival, /createIntentSelectionObserver\(productEvents\)/)
  assert.doesNotMatch(arrival, /intentEvents\.select\([^)]*textContent/)

  const statusStart = runtime.indexOf('if (event === "queue:status")')
  const statusEnd = runtime.indexOf('} else if (event === "match_found")', statusStart)
  const statusBlock = runtime.slice(statusStart, statusEnd)
  const guardIndex = statusBlock.indexOf("queuedAttemptCanPresent(payload.queue_attempt_id)")
  const joinedIndex = statusBlock.indexOf("queueEvents.joined()")
  const intentLockIndex = statusBlock.indexOf("intentEvents.markQueueJoined()")

  assert.ok(guardIndex >= 0)
  assert.ok(joinedIndex > guardIndex)
  assert.ok(intentLockIndex > guardIndex, "intent reversal must freeze only after authoritative queue join")
  assert.doesNotMatch(arrival, /Deep Talk person|Vent user|personality/i)
})
