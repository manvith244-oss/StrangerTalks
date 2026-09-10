import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  createProductEventTracker,
  createQueueEventObserver
} from "../../priv/static/assets/product_events.mjs"

function setup(options = {}) {
  const events = []
  const sink = options.sink || (async (event) => events.push(event))
  const tracker = createProductEventTracker({uuid: () => "flow-recovery", sink})
  return {events, observer: createQueueEventObserver(tracker)}
}

test("match cannot skip a missing authoritative queue-joined stage", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.requested("EXPLORE", "en"), true)
  assert.equal(await observer.matched(), false)
  assert.deepEqual(events.map(({name}) => name), ["st_queue_requested"])
})

test("failed queue-request delivery truncates analytics rather than allowing downstream success", async () => {
  const events = []
  const {observer} = setup({
    sink: async (event) => {
      if (event.name === "st_queue_requested") throw new Error("measurement sink unavailable")
      events.push(event)
    }
  })

  assert.equal(await observer.requested("EXPLORE", "en"), false)
  assert.equal(await observer.joined(), false)
  assert.equal(await observer.matched(), false)
  assert.equal(await observer.firstMessageAccepted(), false)
  assert.deepEqual(events, [])
})

test("failed queue-joined delivery truncates analytics rather than allowing downstream success", async () => {
  const events = []
  const {observer} = setup({
    sink: async (event) => {
      if (event.name === "st_queue_joined") throw new Error("measurement sink unavailable")
      events.push(event)
    }
  })

  assert.equal(await observer.requested("SOMETHING_REAL", "te"), true)
  assert.equal(await observer.joined(), false)
  assert.equal(await observer.matched(), false)
  assert.equal(await observer.firstMessageAccepted(), false)
  assert.deepEqual(events.map(({name}) => name), ["st_queue_requested"])
})

test("first accepted message cannot skip a missing successfully recorded match stage", async () => {
  const events = []
  const {observer} = setup({
    sink: async (event) => {
      if (event.name === "st_match_created") throw new Error("measurement sink unavailable")
      events.push(event)
    }
  })

  assert.equal(await observer.requested("JUST_TALK", "hi"), true)
  assert.equal(await observer.joined(), true)
  assert.equal(await observer.matched(), false)
  assert.equal(await observer.firstMessageAccepted(), false)
  assert.deepEqual(events.map(({name}) => name), ["st_queue_requested", "st_queue_joined"])
})

test("session reconciliation restores product state but never fabricates missing funnel timestamps", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const reconcileStart = source.indexOf('if (event === "session:reconcile")')
  const reconcileEnd = source.indexOf("function withBlockCompletion", reconcileStart)
  const reconcileBlock = source.slice(reconcileStart, reconcileEnd)

  assert.ok(reconcileStart >= 0 && reconcileEnd > reconcileStart)
  assert.match(reconcileBlock, /applyQueueSnapshot\(result\?\.snapshot\)/)
  assert.doesNotMatch(reconcileBlock, /queueEvents\.joined\(/)
  assert.doesNotMatch(reconcileBlock, /queueEvents\.matched\(/)
})

test("normal observed funnel still records canonical stages in order", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.requested("KEEP_IT_LIGHT", "en"), true)
  assert.equal(await observer.joined(), true)
  assert.equal(await observer.matched(), true)
  assert.equal(await observer.firstMessageAccepted(), true)

  assert.deepEqual(events.map(({name}) => name), [
    "st_queue_requested",
    "st_queue_joined",
    "st_match_created",
    "st_first_message_accepted"
  ])
})
