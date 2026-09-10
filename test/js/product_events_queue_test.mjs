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
    uuid: () => "flow-queue",
    sink: async (event) => events.push(event)
  })
  return {events, observer: createQueueEventObserver(tracker)}
}

test("queue request is distinct from authoritative admission", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.requested("EXPLORE", "te"), true)
  assert.deepEqual(events, [{
    name: "st_queue_requested",
    properties: {
      flow_attempt_id: "flow-queue",
      test_traffic: false,
      intent_code: "EXPLORE",
      interaction_language: "te"
    }
  }])

  assert.equal(await observer.admitted(), true)
  assert.deepEqual(events[1], {
    name: "st_queue_admitted",
    properties: {
      flow_attempt_id: "flow-queue",
      test_traffic: false,
      intent_code: "EXPLORE"
    }
  })
})

test("admission cannot be manufactured without a request in the same flow", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.admitted(), false)
  assert.deepEqual(events, [])
})

test("duplicate authoritative queued states do not inflate admission", async () => {
  const {events, observer} = setup()

  await observer.requested("JUST_TALK", "hi")
  assert.equal(await observer.admitted(), true)
  assert.equal(await observer.admitted(), false)
  assert.equal(events.filter(({name}) => name === "st_queue_admitted").length, 1)
})

test("queue analytics never need the authoritative queue attempt identifier", async () => {
  const {events, observer} = setup()

  await observer.requested("SOMETHING_REAL", "en")
  await observer.admitted()

  for (const event of events) {
    assert.equal("queue_attempt_id" in event.properties, false)
  }
})

test("runtime request hook precedes outbound queue push and admission follows canonical queued guard", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const pushStart = source.indexOf("channel.push = function(event, payload = {}, timeout)")
  const pushEnd = source.indexOf("const originalOn = channel.on.bind(channel)", pushStart)
  const pushBlock = source.slice(pushStart, pushEnd)
  const requestIndex = pushBlock.indexOf("queueEvents.requested(")
  const outboundIndex = pushBlock.indexOf("originalPush(event, payload, timeout)")

  assert.ok(requestIndex >= 0, "queue request measurement must exist")
  assert.ok(requestIndex < outboundIndex, "queue request measurement must run before outbound queue:join")

  const statusStart = source.indexOf('if (event === "queue:status")')
  const statusEnd = source.indexOf('} else if (event === "match_found")', statusStart)
  const statusBlock = source.slice(statusStart, statusEnd)
  const guardIndex = statusBlock.indexOf("queuedAttemptCanPresent(payload.queue_attempt_id)")
  const admissionIndex = statusBlock.indexOf("queueEvents.admitted()")

  assert.ok(guardIndex >= 0, "existing stale/duplicate queued-state guard must remain")
  assert.ok(admissionIndex > guardIndex, "authoritative admission measurement must occur only after the canonical guard")
})
