import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"

import {
  DEFAULT_RAPID_TAP_WINDOW_MS,
  createRapidTapGate,
  isMobileInteractionSurface,
  rapidTapActionKey
} from "../../priv/static/assets/mobile_flow.mjs"

const indexHtml = fs.readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")

test("F-09 safe-area viewport opts into full cutout-aware layout without disabling zoom", () => {
  const viewport = indexHtml.match(/<meta\s+name="viewport"\s+content="([^"]+)"/i)?.[1] || ""
  assert.match(viewport, /width=device-width/)
  assert.match(viewport, /initial-scale=1/)
  assert.match(viewport, /viewport-fit=cover/)
  assert.doesNotMatch(viewport, /user-scalable\s*=\s*no/i)
  assert.doesNotMatch(viewport, /maximum-scale/i)
})

test("F-09 rapid-tap gate accepts one action and rejects immediate duplicates", () => {
  const gate = createRapidTapGate(DEFAULT_RAPID_TAP_WINDOW_MS)
  assert.equal(gate.accept("queue:start", 1000), true)
  assert.equal(gate.accept("queue:start", 1001), false)
  assert.equal(gate.accept("queue:start", 1000 + DEFAULT_RAPID_TAP_WINDOW_MS - 1), false)
  assert.equal(gate.accept("queue:start", 1000 + DEFAULT_RAPID_TAP_WINDOW_MS), true)
})

test("F-09 rapid-tap gate keeps start and leave actions independent", () => {
  const gate = createRapidTapGate(900)
  assert.equal(gate.accept("queue:start", 10), true)
  assert.equal(gate.accept("queue:leave", 11), true)
  assert.equal(gate.accept("queue:start", 12), false)
  gate.clear("queue:start")
  assert.equal(gate.accept("queue:start", 13), true)
})

test("F-09 identifies only current matchmaking primary actions for tap gating", () => {
  const startTarget = {closest: (selector) => selector === "#doors button" ? {} : null}
  const leaveTarget = {closest: (selector) => selector === "#leave-queue" ? {} : null}
  const unrelatedTarget = {closest: () => null}

  assert.equal(rapidTapActionKey(startTarget), "queue:start")
  assert.equal(rapidTapActionKey(leaveTarget), "queue:leave")
  assert.equal(rapidTapActionKey(unrelatedTarget), null)
})

test("F-09 limits mobile-flow gating to narrow or coarse-pointer interaction surfaces", () => {
  assert.equal(isMobileInteractionSurface({innerWidth: 390, matchMedia: () => ({matches: false})}), true)
  assert.equal(isMobileInteractionSurface({innerWidth: 1280, matchMedia: () => ({matches: true})}), true)
  assert.equal(isMobileInteractionSurface({innerWidth: 1280, matchMedia: () => ({matches: false})}), false)
})
