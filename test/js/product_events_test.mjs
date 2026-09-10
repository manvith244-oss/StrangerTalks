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

  assert.deepEqual(PRODUCT_EVENT_NAMES, [
    "st_entrance_ready",
    "st_intent_selected",
    "st_intent_changed",
    "st_talk_language_opened",
    "st_talk_language_selected",
    "st_queue_requested",
    "st_queue_joined",
    "st_match_created",
    "st_first_message_accepted",
    "st_flow_cancelled"
  ])

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
    content: "private words",
    message_body: "private words",
    draft: "private draft",
    email: "person@example.test",
    name: "private name",
    profile: "private profile",
    latitude: 17.3,
    longitude: 78.4,
    location: "private location",
    token: "secret",
    participant_token: "secret",
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

test("rejects malformed semantic values even when the event and property names are allowlisted", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.equal(await tracker.capture("st_intent_selected", {
    intent_family: "four_doors",
    intent_value: "INVENTED_DOOR",
    selection_kind: "first"
  }), false)
  assert.equal(await tracker.capture("st_talk_language_selected", {
    language_code: "fr",
    source: "new"
  }), false)
  assert.equal(await tracker.capture("st_queue_requested", {
    intent_code: "EXPLORE",
    interaction_language: "fr"
  }), false)
  assert.equal(await tracker.capture("st_flow_cancelled", {
    stage: "queue",
    reason_code: "felt_sad"
  }), false)
  assert.deepEqual(events, [])
})

test("rejects structurally incomplete events instead of emitting ambiguous funnel rows", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.equal(await tracker.capture("st_entrance_ready", {device_class: "desktop"}), false)
  assert.equal(await tracker.capture("st_intent_selected", {intent_value: "EXPLORE"}), false)
  assert.equal(await tracker.capture("st_queue_requested", {intent_code: "EXPLORE"}), false)
  assert.equal(await tracker.capture("st_queue_joined", {}), false)
  assert.deepEqual(events, [])
})

test("invalid captureOnce attempt does not consume the valid once-only slot", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.equal(await tracker.captureOnce("st_queue_joined", {}), false)
  assert.equal(await tracker.captureOnce("st_queue_joined", {intent_code: "EXPLORE"}), true)
  assert.equal(events.length, 1)
  assert.equal(events[0].name, "st_queue_joined")
})

test("first-message event has no application payload surface beyond flow/test context", async () => {
  const {events, sink} = recordingSink()
  const tracker = createProductEventTracker({uuid: () => "flow-1", sink})

  assert.equal(await tracker.capture("st_first_message_accepted", {
    message_type: "text",
    message_id: "private-id",
    content: "private"
  }), true)
  assert.deepEqual(events[0], {
    name: "st_first_message_accepted",
    properties: {
      flow_attempt_id: "flow-1",
      test_traffic: false
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
