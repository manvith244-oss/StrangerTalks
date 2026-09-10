import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  captureFirstMessageAccepted,
  createProductEventTracker
} from "../../priv/static/assets/product_events.mjs"

function setup() {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => "flow-message",
    sink: async (event) => events.push(event)
  })
  return {events, tracker}
}

test("first accepted human message emits once without message content or identifiers", async () => {
  const {events, tracker} = setup()

  assert.equal(await captureFirstMessageAccepted(tracker), true)
  assert.equal(await captureFirstMessageAccepted(tracker), false)

  assert.deepEqual(events, [{
    name: "st_first_message_accepted",
    properties: {
      flow_attempt_id: "flow-message",
      test_traffic: false
    }
  }])
})

test("message event schema cannot carry body, reply, media text, or message IDs", async () => {
  const {events, tracker} = setup()

  await tracker.captureOnce("st_first_message_accepted", {
    message_body: "private",
    body: "private",
    reply_content: "private",
    sticker_text: "private",
    message_id: "private-id",
    client_message_id: "private-client-id"
  })

  assert.deepEqual(events[0].properties, {
    flow_attempt_id: "flow-message",
    test_traffic: false
  })
})

test("runtime attaches first-message success only to the message:send ok receiver", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")

  const helperStart = source.indexOf("function withFirstMessageAcceptance(push)")
  const helperEnd = source.indexOf("function patchParticipantChannel", helperStart)
  const helper = source.slice(helperStart, helperEnd)
  assert.match(helper, /push\.receive\("ok"/)
  assert.match(helper, /captureFirstMessageAccepted\(productEvents\)/)
  assert.doesNotMatch(helper, /receive\("error"[\s\S]*captureFirstMessageAccepted/)
  assert.doesNotMatch(helper, /receive\("timeout"[\s\S]*captureFirstMessageAccepted/)

  const conversationStart = source.indexOf("function patchConversationChannel(channel)")
  const conversationEnd = source.indexOf("const originalSocketChannel", conversationStart)
  const conversationBlock = source.slice(conversationStart, conversationEnd)
  assert.match(conversationBlock, /event === "message:send"/)
  assert.match(conversationBlock, /withFirstMessageAcceptance\(push\)/)
  assert.doesNotMatch(conversationBlock, /withFirstMessageAcceptance\(push, payload\)/)
})
