import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  captureFlowCancelled,
  createIntentSelectionObserver,
  createProductEventTracker,
  createQueueEventObserver,
  createTalkLanguageObserver
} from "../../priv/static/assets/product_events.mjs"

function setup() {
  const events = []
  const ids = ["flow-one", "flow-two", "flow-three"]
  const tracker = createProductEventTracker({
    uuid: () => ids.shift(),
    sink: async (event) => events.push(event)
  })
  return {events, tracker}
}

test("successful explicit queue cancellation closes the old flow and rotates its ephemeral id", async () => {
  const {events, tracker} = setup()

  assert.equal(tracker.flowAttemptId, "flow-one")
  assert.equal(await captureFlowCancelled(tracker, {stage: "queue", reasonCode: "user_requested"}), true)
  assert.deepEqual(events[0], {
    name: "st_flow_cancelled",
    properties: {
      flow_attempt_id: "flow-one",
      test_traffic: false,
      stage: "queue",
      reason_code: "user_requested"
    }
  })
  assert.equal(tracker.flowAttemptId, "flow-two")
})

test("unknown cancellation stages or reasons are rejected without rotating the flow", async () => {
  const {events, tracker} = setup()

  assert.equal(await captureFlowCancelled(tracker, {stage: "conversation", reasonCode: "rage_quit"}), false)
  assert.equal(tracker.flowAttemptId, "flow-one")
  assert.deepEqual(events, [])
})

test("flow-scoped observers forget prior context after a successful cancellation", async () => {
  const {events, tracker} = setup()
  const intents = createIntentSelectionObserver(tracker)
  const languages = createTalkLanguageObserver(tracker)
  const queue = createQueueEventObserver(tracker)

  await intents.select("JUST_TALK")
  await languages.selected("en", ["en", "te", "hi"])
  await queue.requested("JUST_TALK", "en")
  await queue.admitted()

  await captureFlowCancelled(tracker, {stage: "queue", reasonCode: "user_requested"})

  assert.equal(await intents.select("JUST_TALK"), true)
  assert.equal(await languages.selected("en", ["en", "te", "hi"]), true)
  assert.equal(await queue.admitted(), false)
  assert.equal(await queue.requested("JUST_TALK", "en"), true)

  const secondFlowEvents = events.filter(({properties}) => properties.flow_attempt_id === "flow-two")
  assert.ok(secondFlowEvents.some(({name}) => name === "st_intent_selected"))
  assert.ok(secondFlowEvents.some(({name}) => name === "st_talk_language_selected"))
  assert.ok(secondFlowEvents.some(({name}) => name === "st_queue_requested"))
})

test("runtime emits cancellation only after server confirms queue leave", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const leaveStart = source.indexOf('if (event === "queue:leave")')
  const leaveEnd = source.indexOf('if (event === "session:reconcile")', leaveStart)
  const leaveBlock = source.slice(leaveStart, leaveEnd)

  const successIndex = leaveBlock.indexOf('result?.status === "left"')
  const cancelIndex = leaveBlock.indexOf("captureFlowCancelled(productEvents")
  assert.ok(successIndex >= 0)
  assert.ok(cancelIndex > successIndex, "flow cancellation must follow server-confirmed leave")

  const errorIndex = leaveBlock.indexOf('push.receive("error"')
  const timeoutIndex = leaveBlock.indexOf('push.receive("timeout"')
  assert.ok(cancelIndex < errorIndex, "error handler must not emit cancellation")
  assert.ok(cancelIndex < timeoutIndex, "timeout handler must not emit cancellation")
})

test("confirmed cancellation re-arms entrance-ready only after canonical state returns to Doors", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")

  assert.match(source, /pendingFreshEntranceAfterCancellation = true/)
  assert.match(source, /freshEntranceAfterCallback = pendingFreshEntranceAfterCancellation/)
  assert.match(source, /queueMicrotask\(\(\) => \{[\s\S]*activeScreen === "doors"[\s\S]*captureEntranceReady\(productEvents/)
})
