import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  createProductEventTracker,
  createTalkLanguageObserver
} from "../../priv/static/assets/product_events.mjs"

function setup() {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => "flow-language",
    sink: async (event) => events.push(event)
  })
  return {events, observer: createTalkLanguageObserver(tracker)}
}

const VALID = ["en", "te", "hi"]

test("direct and required-after-intent language opens stay distinguishable", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.opened("direct"), true)
  assert.equal(await observer.opened("required_after_intent"), true)
  assert.equal(await observer.opened("invented_trigger"), false)
  assert.deepEqual(events.map(({properties}) => properties.trigger), ["direct", "required_after_intent"])
})

test("a valid remembered language is interaction context, not identity", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.remembered("te", VALID), true)
  assert.deepEqual(events[0], {
    name: "st_talk_language_selected",
    properties: {
      flow_attempt_id: "flow-language",
      test_traffic: false,
      language_code: "te",
      source: "remembered"
    }
  })
  assert.equal("participant_id" in events[0].properties, false)
  assert.equal("user_language" in events[0].properties, false)
})

test("new and changed valid language selections are classified without free text", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.selected("en", VALID), true)
  assert.equal(await observer.selected("hi", VALID), true)
  assert.equal(await observer.selected("hi", VALID), false)

  assert.deepEqual(events.map(({properties}) => [properties.language_code, properties.source]), [
    ["en", "new"],
    ["hi", "changed"]
  ])
})

test("invalid or free-form language values are never emitted", async () => {
  const {events, observer} = setup()

  assert.equal(await observer.selected("fr", VALID), false)
  assert.equal(await observer.remembered("<script>", VALID), false)
  assert.deepEqual(events, [])
})

test("arrival hooks observe existing language control without redesigning it", () => {
  const source = readFileSync(new URL("../../priv/static/assets/arrival_first_minute.mjs", import.meta.url), "utf8")

  assert.match(source, /talkLanguageEvents\.opened\("direct"\)/)
  assert.match(source, /talkLanguageEvents\.opened\("required_after_intent"\)/)
  assert.match(source, /talkLanguageEvents\.selected\(languageSelect\.value, validLanguageValues\(\)\)/)
  assert.doesNotMatch(source, /Custom Language Tag|language_tag/)
})
