import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {
  captureEntranceReady,
  createProductEventTracker,
  deviceClassForWidth
} from "../../priv/static/assets/product_events.mjs"

function recordingTracker(options = {}) {
  const events = []
  const tracker = createProductEventTracker({
    uuid: () => "flow-arrival",
    sink: async (event) => events.push(event),
    ...options
  })
  return {events, tracker}
}

test("entrance-ready emits once only when the interactive boundary is explicitly reached", async () => {
  const {events, tracker} = recordingTracker()

  assert.equal(events.length, 0)
  assert.equal(await captureEntranceReady(tracker, {
    rememberedTalkLanguage: "te",
    viewportWidth: 390
  }), true)
  assert.equal(await captureEntranceReady(tracker, {
    rememberedTalkLanguage: "te",
    viewportWidth: 390
  }), false)

  assert.deepEqual(events, [{
    name: "st_entrance_ready",
    properties: {
      flow_attempt_id: "flow-arrival",
      test_traffic: false,
      remembered_talk_language: true,
      device_class: "mobile"
    }
  }])
})

test("invalid or manipulated remembered language is not reported as remembered context", async () => {
  const {events, tracker} = recordingTracker()

  assert.equal(await captureEntranceReady(tracker, {
    rememberedTalkLanguage: "fr",
    viewportWidth: 390
  }), true)

  assert.equal(events[0].properties.remembered_talk_language, false)
})

test("entrance-ready uses only the bounded device-class enum", () => {
  assert.equal(deviceClassForWidth(390), "mobile")
  assert.equal(deviceClassForWidth(768), "tablet")
  assert.equal(deviceClassForWidth(1024), "desktop")
  assert.equal(deviceClassForWidth(undefined), "unknown")
  assert.equal(deviceClassForWidth(Number.NaN), "unknown")
})

test("canonical boot passes the remembered language value into the validated readiness boundary", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const helperStart = source.indexOf("function captureCurrentEntrance(")
  const helperEnd = source.indexOf("function installEntranceAttemptObserver", helperStart)
  const helper = source.slice(helperStart, helperEnd)

  assert.ok(helperStart >= 0 && helperEnd > helperStart)
  assert.match(helper, /rememberedTalkLanguage: languageSelect\?\.value \|\| null/)
  assert.doesNotMatch(helper, /rememberedTalkLanguage: Boolean\(languageSelect\?\.value\)/)
})

test("canonical boot emits entrance-ready only after the actual entrance is made interactive", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const finishStart = source.indexOf("function finishBoot(snapshot)")
  const finishEnd = source.indexOf("function renderBootFailure()", finishStart)
  const finishBoot = source.slice(finishStart, finishEnd)
  const helperStart = source.indexOf("function captureCurrentEntrance(")
  const helperEnd = source.indexOf("function installEntranceAttemptObserver", helperStart)
  const helper = source.slice(helperStart, helperEnd)

  assert.ok(finishStart >= 0 && finishEnd > finishStart, "finishBoot must remain the canonical boot-success boundary")
  const interactiveIndex = finishBoot.indexOf('document.body.classList.remove("flow-booting")')
  const entranceIndex = finishBoot.indexOf("captureCurrentEntrance()")
  assert.ok(interactiveIndex >= 0, "finishBoot must make the resolved surface interactive")
  assert.ok(entranceIndex > interactiveIndex, "entrance-ready path must run only after interactivity is restored")
  assert.match(
    finishBoot,
    /if \(resolvedScreen === "doors"\) captureCurrentEntrance\(\)/,
    "restored queue/conversation states must not be counted as a fresh entrance"
  )
  assert.match(helper, /entranceAttempts\.entranceReady\(/)
})
