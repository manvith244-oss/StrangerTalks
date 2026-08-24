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
  assert.equal(messageGrouping({previousMine: false, currentMine: false, nextMine: false}), "single")
  assert.equal(messageGrouping({previousMine: false, currentMine: true, nextMine: true}), "first")
  assert.equal(messageGrouping({previousMine: true, currentMine: true, nextMine: true}), "middle")
  assert.equal(messageGrouping({previousMine: true, currentMine: true, nextMine: false}), "last")
})

test("composer switches between voice and Send without hiding camera or tools", () => {
  assert.deepEqual(composerVisualState(""), {showSend: false, showVoice: true, showCamera: true, showTools: true})
  assert.deepEqual(composerVisualState("   "), {showSend: false, showVoice: true, showCamera: true, showTools: true})
  assert.deepEqual(composerVisualState("hello"), {showSend: true, showVoice: false, showCamera: true, showTools: true})
})

test("quick-heart only accepts actual taps, not swipes or long presses", () => {
  assert.equal(isTapGesture({dx: 2, dy: 3, elapsedMs: 120}), true)
  assert.equal(isTapGesture({dx: 18, dy: 1, elapsedMs: 120}), false)
  assert.equal(isTapGesture({dx: 1, dy: 1, elapsedMs: 620}), false)
  assert.equal(shouldTriggerQuickHeart({dx: 2, dy: 3, elapsedMs: 120}), true)
  assert.equal(shouldTriggerQuickHeart({dx: 18, dy: 1, elapsedMs: 120}), false)
})

test("system edge reserve protects both left and right navigation gestures", () => {
  assert.equal(isSystemEdgeStart(0, 390), true)
  assert.equal(isSystemEdgeStart(23, 390), true)
  assert.equal(isSystemEdgeStart(24, 390), false)
  assert.equal(isSystemEdgeStart(366, 390), false)
  assert.equal(isSystemEdgeStart(367, 390), true)
  assert.equal(isSystemEdgeStart(389, 390), true)
})

test("message release arbitration prevents system-edge and post-long-press double actions", () => {
  assert.equal(shouldSuppressMessageRelease({edgeReserved: true, longPressRecognized: false}), true)
  assert.equal(shouldSuppressMessageRelease({edgeReserved: false, longPressRecognized: true}), true)
  assert.equal(shouldSuppressMessageRelease({edgeReserved: false, longPressRecognized: false}), false)
})

test("coarse-pointer mainstream target floor is 48px without changing visual icon size", () => {
  assert.equal(coarseTargetMinimumPx(), 48)
  assert.match(thumbSource, /const COARSE_TARGET_PX = 48/)
  assert.match(thumbSource, /\.ig-header-icon,[\s\S]*min-width: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.ig-header-icon,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.ig-plus,[\s\S]*min-width: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.ig-plus,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.message-action-btn,[\s\S]*min-width: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.message-action-btn,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
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

test("chat hardening covers short keyboards, landscape notches, iOS zoom and coarse-pointer targets", () => {
  assert.match(moduleSource, /Math\.max\(1, Math\.round\(candidate\)\)/)
  assert.match(moduleSource, /safe-area-inset-left/)
  assert.match(moduleSource, /safe-area-inset-right/)
  assert.match(moduleSource, /touch-action: pan-y/)
  assert.match(moduleSource, /touch-action: manipulation/)
  assert.match(moduleSource, /-webkit-text-size-adjust: 100%/)
  assert.match(moduleSource, /min-height: 44px/)
})
