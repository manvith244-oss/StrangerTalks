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

test("entrance-ready uses only the bounded device-class enum", () => {
  assert.equal(deviceClassForWidth(390), "mobile")
  assert.equal(deviceClassForWidth(768), "tablet")
  assert.equal(deviceClassForWidth(1024), "desktop")
  assert.equal(deviceClassForWidth(undefined), "unknown")
  assert.equal(deviceClassForWidth(Number.NaN), "unknown")
})

test("canonical boot emits entrance-ready only after the entrance is made interactive", () => {
  const source = readFileSync(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
  const start = source.indexOf("function finishBoot(snapshot)")
  const end = source.indexOf("function renderBootFailure()", start)
  const finishBoot = source.slice(start, end)

  assert.ok(start >= 0 && end > start, "finishBoot must remain the canonical boot-success boundary")
  const interactiveIndex = finishBoot.indexOf('document.body.classList.remove("flow-booting")')
  const eventIndex = finishBoot.indexOf("captureEntranceReady(")
  assert.ok(interactiveIndex >= 0, "finishBoot must make the entrance interactive")
  assert.ok(eventIndex > interactiveIndex, "entrance-ready must be captured after interactivity is restored")
  assert.equal((finishBoot.match(/captureEntranceReady\(/g) || []).length, 1)
})
