import assert from "node:assert/strict"
import test from "node:test"
import {
  PRODUCT_EVENT_NAMES,
  createProductEventTracker
} from "../../priv/static/assets/product_events.mjs"

function recordingSink() {
  const events = []
  return {
    events,
    sink: async (event) => {
      events.push(event)
    }
  }
}

test("creates a fresh flow_attempt_id from an injectable UUID source", () => {
  const ids = ["flow-1", "flow-2"]
  const tracker = createProductEventTracker({uuid: () => ids.shift()})

  assert.equal(tracker.flowAttemptId, "flow-1")
  assert.equal(tracker.resetFlow(), "flow-2")
  assert.equal(tracker.flowAttemptId, "flow-2")
})

test("accepts only the frozen allowlisted product event names", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.ok(PRODUCT_EVENT_NAMES.includes("st_entrance_ready"))
  assert.ok(PRODUCT_EVENT_NAMES.includes("st_queue_requested"))
  assert.ok(PRODUCT_EVENT_NAMES.includes("st_queue_joined"))
  assert.equal(PRODUCT_EVENT_NAMES.includes("st_queue_admitted"), false)
  assert.ok(PRODUCT_EVENT_NAMES.includes("st_match_created"))
  assert.ok(PRODUCT_EVENT_NAMES.includes("st_first_message_accepted"))

  assert.equal(await tracker.capture("st_not_real", {anything: "value"}), false)
  assert.deepEqual(events, [])
})

test("sanitizes properties through the allowlist for each event", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.equal(await tracker.capture("st_intent_selected", {
    intent_family: "four_doors",
    intent_value: "SOMETHING_REAL",
    selection_kind: "first"
  }), true)

  assert.deepEqual(events, [{
    name: "st_intent_selected",
    properties: {
      flow_attempt_id: "flow-1",
      test_traffic: false,
      intent_family: "four_doors",
      intent_value: "SOMETHING_REAL",
      selection_kind: "first"
    }
  }])
})

test("drops unknown payload properties instead of leaking them to the sink", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  await tracker.capture("st_queue_requested", {
    intent_code: "EXPLORE",
    interaction_language: "te",
    message_body: "private words",
    email: "person@example.test",
    arbitrary_dom_dump: {secret: true}
  })

  assert.deepEqual(events[0], {
    name: "st_queue_requested",
    properties: {
      flow_attempt_id: "flow-1",
      test_traffic: false,
      intent_code: "EXPLORE",
      interaction_language: "te"
    }
  })
})

test("delivers a sanitized event to an injected provider-neutral sink", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.equal(await tracker.capture("st_talk_language_opened", {trigger: "direct"}), true)
  assert.equal(events.length, 1)
  assert.equal(events[0].name, "st_talk_language_opened")
  assert.deepEqual(events[0].properties, {
    flow_attempt_id: "flow-1",
    test_traffic: false,
    trigger: "direct"
  })
})

test("swallows synchronous and asynchronous sink failures", async () => {
  const syncFailure = createProductEventTracker({
    uuid: () => "flow-1",
    sink: () => { throw new Error("analytics unavailable") }
  })
  const asyncFailure = createProductEventTracker({
    uuid: () => "flow-2",
    sink: async () => { throw new Error("network rejected") }
  })

  assert.equal(await syncFailure.capture("st_entrance_ready", {
    remembered_talk_language: false,
    device_class: "desktop"
  }), false)
  assert.equal(await asyncFailure.capture("st_entrance_ready", {
    remembered_talk_language: false,
    device_class: "desktop"
  }), false)
})

test("uses a no-op sink when none is configured", async () => {
  const tracker = createProductEventTracker({uuid: () => "flow-1"})

  assert.equal(await tracker.capture("st_entrance_ready", {
    remembered_talk_language: false,
    device_class: "unknown"
  }), true)
})

test("captureOnce emits an event only once per flow and resets with a new flow", async () => {
  const ids = ["flow-1", "flow-2"]
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => ids.shift(), sink})

  assert.equal(await tracker.captureOnce("st_first_message_accepted", {}), true)
  assert.equal(await tracker.captureOnce("st_first_message_accepted", {}), false)
  assert.equal(events.length, 1)

  tracker.resetFlow()

  assert.equal(await tracker.captureOnce("st_first_message_accepted", {}), true)
  assert.equal(events.length, 2)
  assert.deepEqual(events.map((event) => event.properties.flow_attempt_id), ["flow-1", "flow-2"])
})

test("marks test traffic without attaching person identity", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({
    uuid: () => "flow-test",
    sink,
    testTraffic: true
  })

  await tracker.capture("st_talk_language_selected", {
    language_code: "hi",
    source: "new",
    participant_id: "must-not-leak",
    name: "must-not-leak"
  })

  assert.deepEqual(events[0], {
    name: "st_talk_language_selected",
    properties: {
      flow_attempt_id: "flow-test",
      test_traffic: true,
      language_code: "hi",
      source: "new"
    }
  })
})
