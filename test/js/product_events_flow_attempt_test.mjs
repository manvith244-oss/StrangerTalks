import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  createEntranceAttemptCoordinator,
  createProductEventTracker
} from "../../priv/static/assets/product_events.mjs"

function setup() {
  const ids = ["flow-1", "flow-2", "flow-3", "flow-4"]
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => ids.shift(),
    sink: async (event) => events.push(event)
  })
  return {events, tracker, coordinator: createEntranceAttemptCoordinator(tracker)}
}

const ready = {rememberedTalkLanguage: true, viewportWidth: 390}

test("initial interactive Doors uses the current ephemeral flow exactly once", async () => {
  const {events, tracker, coordinator} = setup()

  assert.equal(tracker.flowAttemptId, "flow-1")
  assert.equal(await coordinator.entranceReady(ready), true)
  assert.equal(await coordinator.entranceReady(ready), false)
  assert.deepEqual(events.map(({properties}) => properties.flow_attempt_id), ["flow-1"])
})

test("returning to Doors after another screen starts a genuinely new entrance flow", async () => {
  const {events, tracker, coordinator} = setup()

  await coordinator.entranceReady(ready)
  assert.equal(await coordinator.entranceReady(ready, {newAttempt: true}), true)
  assert.equal(tracker.flowAttemptId, "flow-2")
  assert.deepEqual(events.map(({properties}) => properties.flow_attempt_id), ["flow-1", "flow-2"])
})

test("an already rotated cancellation flow is not rotated a second time when Doors becomes active", async () => {
  const {events, tracker, coordinator} = setup()

  await coordinator.entranceReady(ready)
  tracker.resetFlow()
  assert.equal(tracker.flowAttemptId, "flow-2")

  assert.equal(await coordinator.entranceReady(ready, {newAttempt: true}), true)
  assert.equal(tracker.flowAttemptId, "flow-2")
  assert.deepEqual(events.map(({properties}) => properties.flow_attempt_id), ["flow-1", "flow-2"])
})

test("first entrance after booting into a restored non-entrance state gets a fresh flow id", async () => {
  const {events, tracker, coordinator} = setup()

  assert.equal(tracker.flowAttemptId, "flow-1")
  assert.equal(await coordinator.entranceReady(ready, {newAttempt: true}), true)
  assert.equal(tracker.flowAttemptId, "flow-2")
  assert.deepEqual(events.map(({properties}) => properties.flow_attempt_id), ["flow-2"])
})

test("runtime tracks screen transitions and starts a new attempt only when Doors becomes active", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")

  assert.match(source, /entranceAttempts\.entranceReady\(/)
  assert.match(source, /function installEntranceAttemptObserver\(/)
  assert.match(source, /nextScreen === "doors" && previousScreen !== "doors"/)
  assert.match(source, /captureCurrentEntrance\(\{newAttempt: true\}\)/)
  assert.doesNotMatch(source, /armFreshEntranceAfterCancellation/)
})
