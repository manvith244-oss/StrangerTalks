import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import {
  createRapidTapGate,
  isMobileInteractionSurface,
  isTouchActivation,
  presentationLifecycleAction,
  rapidTapActionKey
} from "../../priv/static/assets/mobile_flow.mjs"

const indexSource = fs.readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const mobileSource = fs.readFileSync(new URL("../../priv/static/assets/mobile_flow.mjs", import.meta.url), "utf8")
const chatSource = fs.readFileSync(new URL("../../priv/static/assets/instagram_chat.mjs", import.meta.url), "utf8")
const chatCss = fs.readFileSync(new URL("../../priv/static/assets/instagram_chat.css", import.meta.url), "utf8")
const thumbSource = fs.readFileSync(new URL("../../priv/static/assets/thumb_interactions.mjs", import.meta.url), "utf8")

function targetFor(selector) {
  return {
    closest(query) {
      return query === selector ? this : null
    }
  }
}

test("mobile viewport opts into safe-area geometry without disabling zoom", () => {
  const viewport = indexSource.match(/<meta name="viewport" content="([^"]+)"/)?.[1] || ""
  assert.match(viewport, /width=device-width/)
  assert.match(viewport, /initial-scale=1/)
  assert.match(viewport, /viewport-fit=cover/)
  assert.doesNotMatch(viewport, /user-scalable\s*=\s*no/i)
  assert.doesNotMatch(viewport, /maximum-scale\s*=\s*1/i)
})

test("rapid tap gate suppresses only duplicate actions inside its window", () => {
  const gate = createRapidTapGate(900)
  assert.equal(gate.accept("queue:start", 1000), true)
  assert.equal(gate.accept("queue:start", 1200), false)
  assert.equal(gate.accept("queue:start", 1900), true)
  assert.equal(gate.accept("queue:start", 1899), false)
  gate.clear("queue:start")
  assert.equal(gate.accept("queue:start", 1900), true)
})

test("start and leave queue actions are independently gated", () => {
  const gate = createRapidTapGate(900)
  assert.equal(gate.accept("queue:start", 1000), true)
  assert.equal(gate.accept("queue:leave", 1001), true)
  assert.equal(gate.accept("queue:start", 1100), false)
  assert.equal(gate.accept("queue:leave", 1101), false)
})

test("rapid tap action scope is limited to canonical queue controls", () => {
  assert.equal(rapidTapActionKey(targetFor("#doors button.door")), "queue:start")
  assert.equal(rapidTapActionKey(targetFor("#leave-queue")), "queue:leave")
  assert.equal(rapidTapActionKey(targetFor("#doors button")), null)
  assert.equal(rapidTapActionKey(targetFor("#bottom-nav button")), null)
  assert.equal(rapidTapActionKey(null), null)
})

test("mobile interaction surface accepts narrow viewports or coarse pointers", () => {
  assert.equal(isMobileInteractionSurface({innerWidth: 390, matchMedia: () => ({matches: false})}), true)
  assert.equal(isMobileInteractionSurface({innerWidth: 1200, matchMedia: () => ({matches: true})}), true)
  assert.equal(isMobileInteractionSurface({innerWidth: 1200, matchMedia: () => ({matches: false})}), false)
})

test("rapid tap suppression distinguishes touch from keyboard, mouse, pen, and script activation", () => {
  assert.equal(isTouchActivation({pointerType: "touch", detail: 1}), true)
  assert.equal(isTouchActivation({pointerType: "mouse", detail: 1}, true), false)
  assert.equal(isTouchActivation({pointerType: "pen", detail: 1}, true), false)
  assert.equal(isTouchActivation({pointerType: "", detail: 1, sourceCapabilities: {firesTouchEvents: true}}), true)
  assert.equal(isTouchActivation({pointerType: "", detail: 0}, true), false)
  assert.equal(isTouchActivation({pointerType: "", detail: 1}, true), true)
  assert.equal(isTouchActivation({pointerType: "", detail: 1}, false), false)
})

test("foreground and background lifecycle maps to presentation-only recovery", () => {
  assert.equal(presentationLifecycleAction("pagehide", "visible"), "clear-transient")
  assert.equal(presentationLifecycleAction("visibilitychange", "hidden"), "clear-transient")
  assert.equal(presentationLifecycleAction("pageshow", "visible"), "refresh")
  assert.equal(presentationLifecycleAction("visibilitychange", "visible"), "refresh")
  assert.equal(presentationLifecycleAction("visibilitychange", "prerender"), "none")
})

test("existing Conversation shell provides safe-area, keyboard, orientation, gesture, and coarse-target authority", () => {
  assert.match(chatCss, /env\(safe-area-inset-top/)
  assert.match(chatCss, /env\(safe-area-inset-bottom/)
  assert.match(chatSource, /safe-area-inset-left/)
  assert.match(chatSource, /safe-area-inset-right/)
  assert.match(chatSource, /window\.visualViewport\?\.addEventListener\("resize"/)
  assert.match(chatCss, /@media \(max-height: 520px\) and \(orientation: landscape\)/)
  assert.match(chatCss, /touch-action: pan-y/)
  assert.match(chatCss, /font-size: 16px; \/\* prevents iOS focus zoom \*\//)
  assert.match(thumbSource, /const COARSE_TARGET_PX = 48/)
  assert.match(thumbSource, /isSystemEdgeStart/)
})

test("F-09 mobile boundary does not redefine route or browser-history authority", () => {
  assert.doesNotMatch(mobileSource, /\bpopstate\b/)
  assert.doesNotMatch(mobileSource, /\bhistory\.(?:pushState|replaceState|back|forward)\b/)
  assert.doesNotMatch(mobileSource, /\[data-go\]/)
})
