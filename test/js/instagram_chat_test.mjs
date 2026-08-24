import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {
  composerVisualState,
  messageGrouping,
  normalizedViewportHeight,
  shouldTriggerQuickHeart
} from "../../priv/static/assets/instagram_chat.mjs"

const css = fs.readFileSync(new URL("../../priv/static/assets/instagram_chat.css", import.meta.url), "utf8")
const moduleSource = fs.readFileSync(new URL("../../priv/static/assets/instagram_chat.mjs", import.meta.url), "utf8")

test("composer uses Instagram-like text/voice state without treating whitespace as a message", () => {
  assert.deepEqual(composerVisualState(""), {hasText: false})
  assert.deepEqual(composerVisualState("   \n"), {hasText: false})
  assert.deepEqual(composerVisualState("hey"), {hasText: true})
})

test("message grouping identifies solo, start, middle, and end bubbles", () => {
  assert.deepEqual(messageGrouping([false]), ["solo"])
  assert.deepEqual(messageGrouping([false, false]), ["start", "end"])
  assert.deepEqual(messageGrouping([true, true, true]), ["start", "middle", "end"])
  assert.deepEqual(
    messageGrouping([false, false, true, true, false]),
    ["start", "end", "start", "end", "solo"]
  )
})

test("quick-heart requires a nearby second tap inside the gesture window", () => {
  const first = {time: 1000, x: 40, y: 60}
  assert.equal(shouldTriggerQuickHeart(first, {time: 1250, x: 45, y: 63}), true)
  assert.equal(shouldTriggerQuickHeart(first, {time: 1400, x: 45, y: 63}), false)
  assert.equal(shouldTriggerQuickHeart(first, {time: 1200, x: 100, y: 120}), false)
  assert.equal(shouldTriggerQuickHeart(null, {time: 1200, x: 40, y: 60}), false)
})

test("visual viewport height follows the live viewport even when a landscape keyboard leaves very little space", () => {
  assert.equal(normalizedViewportHeight(640.4, 800), 640)
  assert.equal(normalizedViewportHeight(undefined, 812), 812)
  assert.equal(normalizedViewportHeight(120, 812), 120)
  assert.equal(normalizedViewportHeight(1, 812), 1)
  assert.equal(normalizedViewportHeight(undefined, undefined), 720)
})

test("chat CSS is scoped and explicitly supports phones, tablets, desktop, landscape and accessibility", () => {
  assert.match(css, /body\.st-chat-mode/)
  assert.match(css, /env\(safe-area-inset-top/)
  assert.match(css, /env\(safe-area-inset-bottom/)
  assert.match(css, /@media \(max-width: 390px\)/)
  assert.match(css, /@media \(min-width: 768px\)/)
  assert.match(css, /@media \(min-width: 1100px\)/)
  assert.match(css, /@media \(max-height: 520px\) and \(orientation: landscape\)/)
  assert.match(css, /@media \(hover: none\) and \(pointer: coarse\)/)
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/)
  assert.match(css, /@media \(prefers-contrast: more\)/)
  assert.match(css, /font-size: 16px; \/\* prevents iOS focus zoom \*\//)
})

test("chat hardening covers short keyboards, landscape notches, iOS zoom and coarse-pointer targets", () => {
  assert.match(moduleSource, /Math\.max\(1, Math\.round\(candidate\)\)/)
  assert.match(moduleSource, /safe-area-inset-left/)
  assert.match(moduleSource, /safe-area-inset-right/)
  assert.match(moduleSource, /input\.style\.fontSize = "16px"/)
  assert.match(moduleSource, /\.reaction-picker \.reaction-btn[\s\S]*width: 44px/)
  assert.match(moduleSource, /\.message-action-btn,[\s\S]*min-height: 44px/)
})

test("chat enhancement loads Companion and preserves human Send authority", () => {
  assert.match(moduleSource, /import "\.\/companion\.mjs"/)
  assert.match(moduleSource, /#bottom-nav \[data-go="chats"\]/)
  assert.match(moduleSource, /#voice-start/)
  assert.match(moduleSource, /#view-once-picker-btn/)
  assert.doesNotMatch(moduleSource, /fetch\([^\n]*message:send/)
  assert.doesNotMatch(moduleSource, /\.submit\(\)/)
})
