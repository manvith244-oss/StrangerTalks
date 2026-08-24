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

test("quick-heart only accepts actual taps, not swipes or long presses", () => {
  const start = {time: 1000, x: 40, y: 60}
  assert.equal(isTapGesture(start, {time: 1120, x: 44, y: 64}), true)
  assert.equal(isTapGesture(start, {time: 1120, x: 80, y: 60}), false)
  assert.equal(isTapGesture(start, {time: 1500, x: 41, y: 61}), false)
  assert.equal(isTapGesture(null, {time: 1100, x: 40, y: 60}), false)
})

test("system edge reserve protects both left and right navigation gestures", () => {
  assert.equal(isSystemEdgeStart(0, 390), true)
  assert.equal(isSystemEdgeStart(24, 390), true)
  assert.equal(isSystemEdgeStart(25, 390), false)
  assert.equal(isSystemEdgeStart(365, 390), false)
  assert.equal(isSystemEdgeStart(366, 390), true)
  assert.equal(isSystemEdgeStart(389, 390), true)
})

test("message release arbitration prevents system-edge and post-long-press double actions", () => {
  const edgeStart = {time: 1000, x: 10, y: 300}
  assert.equal(shouldSuppressMessageRelease(edgeStart, {time: 1180, x: 72, y: 304}, {viewportWidth: 390}), true)

  const centerStart = {time: 1000, x: 180, y: 300}
  assert.equal(shouldSuppressMessageRelease(centerStart, {time: 1180, x: 242, y: 304}, {viewportWidth: 390}), false)
  assert.equal(shouldSuppressMessageRelease(centerStart, {time: 1520, x: 244, y: 304}, {viewportWidth: 390}), true)

  const verticalScrollAtEdge = {time: 1000, x: 10, y: 300}
  assert.equal(shouldSuppressMessageRelease(verticalScrollAtEdge, {time: 1180, x: 18, y: 365}, {viewportWidth: 390}), false)
})

test("coarse-pointer mainstream target floor is 48px without changing visual icon size", () => {
  assert.equal(coarseTargetMinimumPx(), 48)
  assert.match(thumbSource, /@media \(hover: none\) and \(pointer: coarse\)/)
  assert.match(thumbSource, /\.ig-chat-back,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.compose #view-once-picker-btn[\s\S]*min-width: \$\{COARSE_TARGET_PX\}px/)
  assert.match(thumbSource, /\.message-action-btn,[\s\S]*min-height: \$\{COARSE_TARGET_PX\}px/)
})

test("composer tools tray supports outside-tap escape without hiding essential actions behind gestures", () => {
  assert.match(thumbSource, /document\.addEventListener\("pointerdown"/)
  assert.match(thumbSource, /!form\.classList\.contains\("ig-tray-open"\) \|\| form\.contains\(event\.target\)/)
  assert.match(thumbSource, /form\.classList\.remove\("ig-tray-open"\)/)
  assert.match(moduleSource, /\.reply-action-btn/)
  assert.match(moduleSource, /\.react-action-btn/)
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
  assert.match(thumbSource, /COARSE_TARGET_PX = 48/)
})

test("short Conversation panels remain scrollable instead of clipping escape controls", () => {
  assert.match(moduleSource, /body\.st-chat-mode \.voice-sheet,[\s\S]*body\.st-chat-mode \.atmosphere-chooser/)
  assert.match(moduleSource, /body\.st-chat-mode #report-form,[\s\S]*body\.st-chat-mode \.live-call-active-panel/)
  assert.match(moduleSource, /max-height: calc\(var\(--ig-vh, 100vh\) - 112px\)/)
  assert.match(moduleSource, /overflow-y: auto/)
  assert.match(moduleSource, /overscroll-behavior-y: contain/)
})

test("media and info controls describe and dismiss their real behavior", () => {
  assert.match(moduleSource, /iconButton\(photo, "camera", "Choose a view-once photo"\)/)
  assert.match(moduleSource, /summary\.setAttribute\("aria-expanded"/)
  assert.match(moduleSource, /event\.key !== "Escape" \|\| !overflow\?\.open/)
  assert.match(moduleSource, /!overflow\?\.open \|\| overflow\.contains\(event\.target\)/)
})

test("programmatic prompt insertion and send clearing cannot desync composer visuals", () => {
  assert.match(moduleSource, /observeProgrammaticComposerValue\(input, updateState\)/)
  assert.match(moduleSource, /Object\.getOwnPropertyDescriptor\(HTMLTextAreaElement\.prototype, "value"\)/)
  assert.match(moduleSource, /queueMicrotask\(onChange\)/)
  assert.match(moduleSource, /input\.addEventListener\("focus", \(\) => \{\s*updateState\(\)/)
})

test("tray decoration is idempotent so its subtree observer cannot self-trigger forever", () => {
  assert.match(moduleSource, /button\.dataset\.igTrayLabel === label/)
  assert.match(moduleSource, /if \(!alreadyDecorated\)/)
  assert.match(moduleSource, /button\.dataset\.igTrayLabel = label/)
})

test("chat enhancement loads Companion and preserves human Send authority", () => {
  assert.match(moduleSource, /import "\.\/companion\.mjs"/)
  assert.match(moduleSource, /#bottom-nav \[data-go="chats"\]/)
  assert.match(moduleSource, /#voice-start/)
  assert.match(moduleSource, /#view-once-picker-btn/)
  assert.doesNotMatch(moduleSource, /fetch\([^\n]*message:send/)
  assert.doesNotMatch(moduleSource, /\.submit\(\)/)
})
