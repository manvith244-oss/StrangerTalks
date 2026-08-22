import assert from "node:assert/strict"
import test from "node:test"

import {applyCanonicalSequence, createDeliveryProgress} from "../../priv/static/assets/delivery_progress.mjs"

test("retained synchronization baseline does not treat unavailable history as a gap", () => {
  let progress = createDeliveryProgress("epoch-a", 100, 0)
  assert.equal(progress.contiguous, 99)
  for (let sequence = 100; sequence <= 150; sequence++) progress = applyCanonicalSequence(progress, sequence)
  assert.equal(progress.contiguous, 150)
})

test("real post-baseline gap pins progress until reconciliation supplies it", () => {
  let progress = createDeliveryProgress("epoch-a", 100, 0)
  for (let sequence = 100; sequence <= 120; sequence++) progress = applyCanonicalSequence(progress, sequence)
  progress = applyCanonicalSequence(progress, 122)
  assert.equal(progress.contiguous, 120)
  assert.equal(progress.applied.has(122), true)
  progress = applyCanonicalSequence(progress, 121)
  assert.equal(progress.contiguous, 122)
})

test("duplicate and lower applied sequences are cumulative no-ops", () => {
  const initial = createDeliveryProgress("epoch-a", 7, 9)
  assert.equal(applyCanonicalSequence(initial, 9).contiguous, 9)
  assert.equal(applyCanonicalSequence(initial, 8).contiguous, 9)
})
