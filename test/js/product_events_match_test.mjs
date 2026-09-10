import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  createProductEventTracker,
  createQueueEventObserver
} from "../../priv/static/assets/product_events.mjs"

function setup() {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => "flow-match",
    sink: async (event) => events.push(event)
  })
  return {events, observer: createQueueEventObserver(tracker)}
}

test("queue request or UI expectation alone never emits match success", async () => {
  const {events, observer} = setup()

  await observer.requested("EXPLORE", "en")
  assert.equal(events.filter(({name}) => name === "st_match_created").length, 0)
})

test("authoritative received match emits once for the current entrance flow", async () => {
  const {events, observer} = setup()

  await observer.requested("JUST_TALK", "hi")
  assert.equal(await observer.matched(), true)
  assert.equal(await observer.matched(), false)

  assert.deepEqual(events.filter(({name}) => name === "st_match_created"), [{
    name: "st_match_created",
    properties: {
      flow_attempt_id: "flow-match",
      test_traffic: false,
      intent_code: "JUST_TALK"
    }
  }])
})

test("match cannot be attributed to a fresh entrance flow without its observed queue request", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.matched(), false)
  assert.deepEqual(events, [])
})

test("match analytics omit conversation and match identifiers", async () => {
  const {events, observer} = setup()

  await observer.requested("SOMETHING_REAL", "te")
  await observer.matched()

  const match = events.find(({name}) => name === "st_match_created")
  assert.equal("match_id" in match.properties, false)
  assert.equal("conversation_id" in match.properties, false)
  assert.equal("queue_attempt_id" in match.properties, false)
})

test("runtime match hooks are server-authoritative and reconciliation-aware", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")

  const matchStart = source.indexOf('} else if (event === "match_found")')
  const matchEnd = source.indexOf('} else if (event === "transition:recovery_failed")', matchStart)
  const matchBlock = source.slice(matchStart, matchEnd)
  assert.match(matchBlock, /queueEvents\.matched\(\)/)

  const reconcileStart = source.indexOf('if (event === "session:reconcile")')
  const reconcileEnd = source.indexOf("function withBlockCompletion", reconcileStart)
  const reconcileBlock = source.slice(reconcileStart, reconcileEnd)
  assert.match(reconcileBlock, /canonical_state === "CONVERSATION"/)
  assert.match(reconcileBlock, /queueEvents\.matched\(\)/)

  const queueRenderStart = source.indexOf("function renderQueue(")
  const queueRenderEnd = source.indexOf("function rememberRetiredQueueAttempt", queueRenderStart)
  assert.doesNotMatch(source.slice(queueRenderStart, queueRenderEnd), /st_match_created|queueEvents\.matched/)
})
