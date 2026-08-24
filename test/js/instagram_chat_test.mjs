import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {
  composerVisualState,
  isTapGesture,
  messageGrouping,
  normalizedViewportHeight,
  shouldTriggerQuickHeart
} from "../../priv/static/assets/instagram_chat.mjs"
import {
  coarseTargetMinimumPx,
  isSystemEdgeStart,
  shouldSuppressMessageRelease
} from "../../priv/static/assets/thumb_interactions.mjs"

const css = fs.readFileSync(new URL("../../priv/static/assets/instagram_chat.css", import.meta.url), "utf8")
const moduleSource = fs.readFileSync(new URL("../../priv/static/assets/instagram_chat.mjs", import.meta.url), "utf8")
const thumbSource = fs.readFileSync(new URL("../../priv/static/assets/thumb_interactions.mjs", import.meta.url), "utf8")
const appSource = fs.readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

test("message grouping follows Instagram-like grouped bubble corners", () => {
  assert.deepEqual(messageGrouping([false]), ["solo"])
  assert.deepEqual(messageGrouping([true, true]), ["start", "end"])
  assert.deepEqual(messageGrouping([false, false, false]), ["start", "middle", "end"])
  assert.deepEqual(messageGrouping([false, true, true, false]), ["solo", "start", "end", "solo"])
})

test("composer exposes whether text is present so CSS can switch voice and Send", () => {
  assert.deepEqual(composerVisualState(""), {hasText: false})
  assert.deepEqual(composerVisualState("   "), {hasText: false})
  assert.deepEqual(composerVisualState("hello"), {hasText: true})
})

test("quick-heart only accepts actual taps and a qualifying second tap", () => {
  const start = {time: 100, x: 40, y: 50}
  const tap = {time: 220, x: 42, y: 53}
  const swipe = {time: 220, x: 58, y: 51}
  const hold = {time: 720, x: 41, y: 51}
  assert.equal(isTapGesture(start, tap), true)
  assert.equal(isTapGesture(start, swipe), false)
  assert.equal(isTapGesture(start, hold), false)
  assert.equal(shouldTriggerQuickHeart(start, tap), true)
  assert.equal(shouldTriggerQuickHeart(start, swipe), true)
  assert.equal(shouldTriggerQuickHeart(start, hold), false)
})

test("system edge reserve protects both left and right navigation gestures", () => {
  assert.equal(isSystemEdgeStart(0, 390), true)
  assert.equal(isSystemEdgeStart(24, 390), true)
  assert.equal(isSystemEdgeStart(25, 390), false)
  assert.equal(isSystemEdgeStart(365, 390), false)
  assert.equal(isSystemEdgeStart(366, 390), true)
  assert.equal(isSystemEdgeStart(389, 390), true)
})

test("message release arbitration reserves horizontal edge gestures, preserves edge scrolling, and suppresses long press release", () => {
  const edgeStart = {time: 0, x: 10, y: 100}
  assert.equal(shouldSuppressMessageRelease(edgeStart, {time: 120, x: 70, y: 102}, {viewportWidth: 390}), true)
  assert.equal(shouldSuppressMessageRelease(edgeStart, {time: 120, x: 12, y: 170}, {viewportWidth: 390}), false)
  const centralStart = {time: 0, x: 180, y: 100}
  assert.equal(shouldSuppressMessageRelease(centralStart, {time: 500, x: 181, y: 101}, {viewportWidth: 390}), true)
  assert.equal(shouldSuppressMessageRelease(centralStart, {time: 120, x: 181, y: 101}, {viewportWidth: 390}), false)
})

test("coarse-pointer mainstream target floor is 48px without changing visual icon size", () => {
  assert.equal(coarseTargetMinimumPx(), 48)
  assert.match(thumbSource, /const COARSE_TARGET_PX = 48/)
  assert.match(thumbSource, /\.ig-chat-back,[\s\S]*min-width: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.ig-compose-icon,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.message-action-btn,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.reaction-picker \.reaction-btn,[\s\S]*min-width: \$\{COARSE_TARGET_PX\}px/)
})

test("composer tools tray supports outside-tap escape without hiding essential actions behind gestures", () => {
  assert.match(thumbSource, /document\.addEventListener\("pointerdown"/)
  assert.match(thumbSource, /!form\.classList\.contains\("ig-tray-open"\) \|\| form\.contains\(event\.target\)/)
  assert.match(thumbSource, /form\.classList\.remove\("ig-tray-open"\)/)
  assert.match(appSource, /className = "message-action-btn reply-action-btn"/)
  assert.match(appSource, /className = "message-action-btn react-action-btn"/)
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

test("chat hardening covers short keyboards, landscape notches, iOS zoom and vertical message scrolling", () => {
  assert.match(moduleSource, /Math\.max\(1, Math\.round\(candidate\)\)/)
  assert.match(moduleSource, /safe-area-inset-left/)
  assert.match(moduleSource, /safe-area-inset-right/)
  assert.match(css, /touch-action: pan-y/)
  assert.match(css, /touch-action: manipulation/)
  assert.match(css, /-webkit-text-size-adjust: 100%/)
})
