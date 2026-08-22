import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {ATMOSPHERES, approvedAtmosphere, transitionAtmosphere} from "../../priv/static/assets/atmospheres.mjs"

const appSource = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const cssSource = readFileSync(new URL("../../priv/static/assets/app.css", import.meta.url), "utf8")
const htmlSource = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const atmosphereRuntimeSource = appSource.slice(appSource.indexOf("function setAtmosphere"), appSource.indexOf('document.addEventListener("visibilitychange"'))
const atmosphereCssSource = cssSource.slice(cssSource.indexOf('[data-atmosphere="rain-window"]'), cssSource.indexOf('section[data-screen="conversation"][data-door'))

const expected = [
  ["rain-window", "Rain Window"],
  ["late-night-library", "Late Night Library"],
  ["train-journey", "Train Journey"],
  ["coffee-shop", "Coffee Shop"],
  ["night-observatory", "Night Observatory"]
]

test("1H catalog contains exactly the five approved meaningful identities", () => {
  assert.deepEqual(ATMOSPHERES.map(({id, label}) => [id, label]), expected)
  assert.equal(new Set(ATMOSPHERES.map(({id}) => id)).size, 5)
  assert.ok(ATMOSPHERES.every(({description}) => description.length > 20))
})

test("1H local transition matrix proves APPLY, NO_OP, RESET, and invalid fallback", () => {
  assert.deepEqual(transitionAtmosphere(null, "rain-window"), {status: "applied", atmosphereId: "rain-window"})
  assert.deepEqual(transitionAtmosphere("rain-window", "rain-window"), {status: "no_op", atmosphereId: "rain-window"})
  assert.deepEqual(transitionAtmosphere("rain-window", null), {status: "reset", atmosphereId: null})
  assert.deepEqual(transitionAtmosphere(null, null), {status: "no_op", atmosphereId: null})
  assert.deepEqual(transitionAtmosphere("coffee-shop", "https://evil.example/theme.css"), {status: "invalid", atmosphereId: "coffee-shop"})
  assert.equal(approvedAtmosphere("unknown"), null)
})

for (const [id, label] of expected) {
  test(`1H ${label} maps to its controlled CSS-only atmosphere`, () => {
    assert.match(cssSource, new RegExp(`data-atmosphere=["']${id}["']`))
    assert.match(cssSource, new RegExp(`data-preview=["']${id}["']`))
    assert.equal(approvedAtmosphere(id)?.label, label)
  })
}

test("1H default and failure fallback retain the existing Conversation appearance", () => {
  assert.match(cssSource, /--atmosphere-background:\s*#12141C/)
  assert.match(cssSource, /--atmosphere-decoration:\s*none/)
  assert.match(appSource, /if \(transition\.status === "invalid"\) return transition/)
  assert.match(appSource, /else delete conversation\.dataset\.atmosphere/)
})

test("1H lifecycle is RAM-only: reconnect preserves while end, replacement, and epoch change reset", () => {
  assert.match(appSource, /atmosphereId:\s*null/)
  assert.match(appSource, /app\.currentEpochId !== epoch_id\) \{[\s\S]*?resetAtmosphere\(\)/)
  assert.match(appSource, /conversation:ended[\s\S]*?resetQuietMode\(\)[\s\S]*?resetAtmosphere\(\)/)
  assert.match(appSource, /handleMatchedConversation[\s\S]*?resetQuietMode\(\)[\s\S]*?resetAtmosphere\(\)/)
  assert.doesNotMatch(appSource, /localStorage|sessionStorage|BroadcastChannel/)
  assert.doesNotMatch(appSource, /putRecord\([^\n]*atmosphere|sync[^\n]*atmosphere/i)
})

test("1H has zero Channel, peer, diagnostic, arbitrary style, and external asset authority", () => {
  assert.doesNotMatch(atmosphereRuntimeSource, /theme:changed|atmosphere:changed|push\(/i)
  assert.doesNotMatch(atmosphereRuntimeSource, /telemetry|analytics|logger/i)
  assert.doesNotMatch(atmosphereRuntimeSource, /style\.setProperty|setAttribute\(["']style|https?:/i)
  assert.doesNotMatch(atmosphereCssSource, /url\(/)
})

test("1H chooser is textual, keyboard-native, selected-state aware, and hover independent", () => {
  assert.match(htmlSource, /id="atmosphere-control"[^>]*aria-expanded="false"/)
  assert.match(htmlSource, /id="atmosphere-chooser"[^>]*role="dialog"/)
  assert.match(htmlSource, /role="group" aria-label="Available atmospheres"/)
  assert.match(appSource, /option\.type = "button"/)
  assert.match(appSource, /option\.setAttribute\("aria-pressed"/)
  assert.match(appSource, /event\.key === "Escape"/)
  assert.ok(expected.every(([, label]) => appSource.includes(label) || ATMOSPHERES.some((item) => item.label === label)))
})

test("1H preserves functional tokens, responsive layout, focus, and forced-color operation", () => {
  for (const token of ["--bubble-peer-bg", "--bubble-mine-bg", "--atmosphere-composer", "--mood-primary", "--mood-light"]) {
    assert.ok(cssSource.includes(token), `${token} is controlled`)
  }
  assert.match(cssSource, /\.atmosphere-option\[aria-pressed="true"\]/)
  assert.match(cssSource, /@media \(max-width: 40rem\)/)
  assert.match(cssSource, /@media \(forced-colors: active\)/)
  assert.match(cssSource, /outline:\s*3px solid Highlight/)
})

test("1H adds no optional motion and Quiet Mode leaves static atmosphere state untouched", () => {
  assert.doesNotMatch(atmosphereCssSource, /animation|@keyframes/)
  assert.doesNotMatch(appSource.match(/function setQuietMode[\s\S]*?function toggleQuietMode/)?.[0] || "", /atmosphere/)
  assert.match(cssSource, /prefers-reduced-motion: reduce/)
})

test("1H canonical message, delivery, presence, reconnect, reconcile, safety, and error owners remain atmosphere-independent", () => {
  for (const owner of ["message:new", "delivery:progress", "conversation:presence", "sync:reconcile", "conversation:report", "handleDomainError"]) {
    assert.ok(appSource.includes(owner), `${owner} owner remains present`)
  }
  for (const snippet of appSource.matchAll(/(?:message:new|delivery:progress|conversation:presence|sync:reconcile)[\s\S]{0,500}/g)) {
    assert.doesNotMatch(snippet[0], /isAtmosphere|atmosphereId/)
  }
})
