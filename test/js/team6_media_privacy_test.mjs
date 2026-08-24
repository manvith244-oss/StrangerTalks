import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
const live = readFileSync(new URL("../../priv/static/assets/live_call.mjs", import.meta.url), "utf8")
const app = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

test("live calling has no recording, transcription, biometric, or display-capture implementation", () => {
  assert.doesNotMatch(live, /MediaRecorder/)
  assert.doesNotMatch(live, /getDisplayMedia/)
  assert.doesNotMatch(live, /transcript|transcription|voice biometric|face biometric|emotion detection/i)
})

test("Screen Share is not presented as an implemented capture control", () => {
  assert.doesNotMatch(app, /getDisplayMedia/)
  assert.doesNotMatch(app, /screen[- ]?share/i)
})

test("active-call V1 UI has no Screen Share action", () => {
  const html = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
  assert.doesNotMatch(html, /btn-call-screen-share|Share Screen/i)
})
