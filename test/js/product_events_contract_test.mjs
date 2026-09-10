import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {DOORS, CONVERSATION_LANGUAGES} from "../../priv/static/assets/conversation_catalog.mjs"
import {
  PRODUCT_EVENT_NAMES,
  captureFlowCancelled,
  createEntranceAttemptCoordinator,
  createIntentSelectionObserver,
  createProductEventTracker,
  createQueueEventObserver,
  createTalkLanguageObserver
} from "../../priv/static/assets/product_events.mjs"

function recordingTracker(ids = ["flow-1", "flow-2", "flow-3"]) {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => ids.shift(),
    sink: async (event) => events.push(event)
  })
  return {events, tracker}
}

const doorValues = DOORS.map(({value}) => value)
const languageValues = CONVERSATION_LANGUAGES.map(({value}) => value)

test("product event names stay explicit and provider-neutral", () => {
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

  const source = readFileSync(new URL("../../priv/static/assets/product_events.mjs", import.meta.url), "utf8").toLowerCase()
  assert.match(source, /__strangertalksproducteventsink/)
  for (const vendor of ["posthog", "mixpanel", "amplitude", "segment.com", "google-analytics"]) {
    assert.equal(source.includes(vendor), false, `vendor transport must stay disabled: ${vendor}`)
  }
})

test("analytics derives Door and conversation-language validity from the canonical catalog", async () => {
  const {events, tracker} = recordingTracker()
  const intents = createIntentSelectionObserver(tracker)
  const languages = createTalkLanguageObserver(tracker)

  for (const intent of doorValues) {
    tracker.resetFlow()
    assert.equal(await intents.select(intent), true)
  }

  for (const language of languageValues) {
    tracker.resetFlow()
    assert.equal(await languages.selected(language, languageValues), true)
  }

  tracker.resetFlow()
  assert.equal(await intents.select("INVENTED_DOOR"), false)
  assert.equal(await languages.selected("zz", [...languageValues, "zz"]), false)
  assert.equal(events.some(({properties}) => properties.intent_value === "INVENTED_DOOR"), false)
  assert.equal(events.some(({properties}) => properties.language_code === "zz"), false)
})

test("privacy allowlist drops content, identity, location and token-shaped payloads", async () => {
  const {events, tracker} = recordingTracker()
  assert.equal(await tracker.capture("st_queue_requested", {
    intent_code: doorValues[0],
    interaction_language: languageValues[0],
    content: "private words",
    message_body: "private words",
    participant_id: "private-id",
    participant_token: "secret",
    email: "private@example.test",
    name: "private name",
    latitude: 17.3,
    longitude: 78.4,
    arbitrary_dom_dump: {secret: true}
  }), true)

  assert.deepEqual(events[0], {
    name: "st_queue_requested",
    properties: {
      flow_attempt_id: "flow-1",
      test_traffic: false,
      intent_code: doorValues[0],
      interaction_language: languageValues[0]
    }
  })

  assert.equal(await tracker.capture("st_first_message_accepted", {
    message_id: "private",
    content: "private"
  }), true)
  assert.deepEqual(events[1].properties, {flow_attempt_id: "flow-1", test_traffic: false})
})

test("authoritative funnel cannot skip request, joined or match stages", async () => {
  const {events, tracker} = recordingTracker()
  const queue = createQueueEventObserver(tracker)
  assert.equal(await queue.joined(), false)
  assert.equal(await queue.matched(), false)
  assert.equal(await queue.firstMessageAccepted(), false)

  assert.equal(await queue.requested(doorValues[1], languageValues[0]), true)
  assert.equal(await queue.matched(), false)
  assert.equal(await queue.joined(), true)
  assert.equal(await queue.firstMessageAccepted(), false)
  assert.equal(await queue.matched(), true)
  assert.equal(await queue.firstMessageAccepted(), true)
  assert.equal(await queue.firstMessageAccepted(), false)

  assert.deepEqual(events.map(({name}) => name), [
    "st_queue_requested",
    "st_queue_joined",
    "st_match_created",
    "st_first_message_accepted"
  ])
})

test("a failed upstream sink write truncates later funnel stages", async () => {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => "flow-failure",
    sink: async (event) => {
      if (event.name === "st_queue_joined") throw new Error("measurement unavailable")
      events.push(event)
    }
  })
  const queue = createQueueEventObserver(tracker)

  assert.equal(await queue.requested(doorValues[2], languageValues[0]), true)
  assert.equal(await queue.joined(), false)
  assert.equal(await queue.matched(), false)
  assert.equal(await queue.firstMessageAccepted(), false)
  assert.deepEqual(events.map(({name}) => name), ["st_queue_requested"])
})

test("confirmed cancellation rotates ephemeral flow authority and resets observers", async () => {
  const {events, tracker} = recordingTracker()
  const intents = createIntentSelectionObserver(tracker)
  const queue = createQueueEventObserver(tracker)

  await intents.select(doorValues[0])
  await queue.requested(doorValues[0], languageValues[0])
  await queue.joined()
  assert.equal(await captureFlowCancelled(tracker, {stage: "queue", reasonCode: "user_requested"}), true)
  assert.equal(tracker.flowAttemptId, "flow-2")
  assert.equal(await queue.joined(), false)
  assert.equal(await intents.select(doorValues[0]), true)
  assert.ok(events.some(({name, properties}) => name === "st_flow_cancelled" && properties.flow_attempt_id === "flow-1"))
})

test("returning to Doors creates one new entrance attempt but a pre-rotated flow is not rotated twice", async () => {
  const {events, tracker} = recordingTracker()
  const entrances = createEntranceAttemptCoordinator(tracker)
  const ready = {rememberedTalkLanguage: languageValues[0], viewportWidth: 390}

  assert.equal(await entrances.entranceReady(ready), true)
  assert.equal(await entrances.entranceReady(ready), false)
  assert.equal(await entrances.entranceReady(ready, {newAttempt: true}), true)
  assert.equal(tracker.flowAttemptId, "flow-2")
  tracker.resetFlow()
  assert.equal(await entrances.entranceReady(ready, {newAttempt: true}), true)
  assert.equal(tracker.flowAttemptId, "flow-3")
  assert.deepEqual(events.filter(({name}) => name === "st_entrance_ready").map(({properties}) => properties.flow_attempt_id), ["flow-1", "flow-2", "flow-3"])
})

test("runtime milestones are bound to authoritative server outcomes, not optimistic UI", () => {
  const runtime = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const arrival = readFileSync(new URL("../../priv/static/assets/arrival_first_minute.mjs", import.meta.url), "utf8")

  assert.match(runtime, /queueEvents\.requested\(/)
  assert.match(runtime, /payload\?\.status === "queued"[\s\S]*queueEvents\.joined\(/)
  assert.match(runtime, /event === "match_found"[\s\S]*queueEvents\.matched\(/)
  assert.match(runtime, /event === "message:send"[\s\S]*push\.receive\("ok"[\s\S]*queueEvents\.firstMessageAccepted\(/)

  const leaveStart = runtime.indexOf('if (event === "queue:leave")')
  const reconcileStart = runtime.indexOf('if (event === "session:reconcile")', leaveStart)
  const leaveBlock = runtime.slice(leaveStart, reconcileStart)
  assert.ok(leaveBlock.indexOf('result?.status === "left"') < leaveBlock.indexOf("captureFlowCancelled(productEvents"))

  const reconcileEnd = runtime.indexOf("function withBlockCompletion", reconcileStart)
  const reconcileBlock = runtime.slice(reconcileStart, reconcileEnd)
  assert.doesNotMatch(reconcileBlock, /queueEvents\.(joined|matched)\(/)

  assert.match(arrival, /intentEvents\.select\(/)
  assert.match(arrival, /talkLanguageEvents\.opened\("required_after_intent"\)/)
  assert.match(arrival, /talkLanguageEvents\.selected\(/)
})
