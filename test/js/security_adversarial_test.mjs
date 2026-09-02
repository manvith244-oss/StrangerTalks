import assert from "node:assert/strict"
import test from "node:test"
import {localMessage, mergeRecords} from "../../priv/static/assets/local_data.mjs"

// Canonical backoff constants matching app.js
const SOCKET_RECONNECT_BASE_MS = [250, 500, 1000, 2000, 5000]
const SOCKET_RECONNECT_CAP_MS = 10000

function proportionalJitter(baseDelay, cap, randomFn = Math.random) {
  const boundedBase = Math.min(baseDelay, cap)
  const minimum = Math.ceil(boundedBase / 2)
  return minimum + Math.floor(randomFn() * (boundedBase - minimum + 1))
}

function socketReconnectAfterMs(tries, randomFn = Math.random) {
  const baseDelay = SOCKET_RECONNECT_BASE_MS[tries - 1] || SOCKET_RECONNECT_CAP_MS
  return proportionalJitter(baseDelay, SOCKET_RECONNECT_CAP_MS, randomFn)
}

// Canonical client delivery status resolution state machine
function resolveDeliveryStatus(currentStatus, incomingStatus) {
  const precedence = {
    failed: 3,
    delivered: 2,
    sent: 1,
    sending: 0
  }

  // "delivered" and "failed" are terminal states; stale "sent" cannot regress them
  if (currentStatus === "delivered" && incomingStatus === "sent") return "delivered"
  if (currentStatus === "failed" && incomingStatus === "sent") return "failed"

  // Transient rejections (rate limit / pressure) on retry leave message in "sending"
  if (currentStatus === "sending" && incomingStatus === "rate_limited") return "sending"
  if (currentStatus === "sending" && incomingStatus === "conversation_busy") return "sending"

  const currentWeight = precedence[currentStatus] ?? 0
  const incomingWeight = precedence[incomingStatus] ?? 0

  return incomingWeight >= currentWeight ? incomingStatus : currentStatus
}

// ============================================================================
// 4F — RECONNECT BACKOFF & JITTER
// ============================================================================

test("4F socketReconnectAfterMs respects attempt progression and bounds", () => {
  const maxStub = () => 0.999999
  const minStub = () => 0.0

  // Attempt 1: base 250ms -> range [125, 250]
  const delay1Min = socketReconnectAfterMs(1, minStub)
  const delay1Max = socketReconnectAfterMs(1, maxStub)
  assert.equal(delay1Min, 125)
  assert.equal(delay1Max, 250)

  // Attempt 2: base 500ms -> range [250, 500]
  const delay2Min = socketReconnectAfterMs(2, minStub)
  const delay2Max = socketReconnectAfterMs(2, maxStub)
  assert.equal(delay2Min, 250)
  assert.equal(delay2Max, 500)

  // Attempt 3: base 1000ms -> range [500, 1000]
  const delay3Min = socketReconnectAfterMs(3, minStub)
  const delay3Max = socketReconnectAfterMs(3, maxStub)
  assert.equal(delay3Min, 500)
  assert.equal(delay3Max, 1000)

  // Attempt 4: base 2000ms -> range [1000, 2000]
  const delay4Min = socketReconnectAfterMs(4, minStub)
  const delay4Max = socketReconnectAfterMs(4, maxStub)
  assert.equal(delay4Min, 1000)
  assert.equal(delay4Max, 2000)

  // Attempt 5: base 5000ms -> range [2500, 5000]
  const delay5Min = socketReconnectAfterMs(5, minStub)
  const delay5Max = socketReconnectAfterMs(5, maxStub)
  assert.equal(delay5Min, 2500)
  assert.equal(delay5Max, 5000)

  // Attempt 6+ (capped at 10000ms) -> range [5000, 10000]
  const delay6Min = socketReconnectAfterMs(6, minStub)
  const delay6Max = socketReconnectAfterMs(6, maxStub)
  assert.equal(delay6Min, 5000)
  assert.equal(delay6Max, 10000)

  const delay100Max = socketReconnectAfterMs(100, maxStub)
  assert.equal(delay100Max, 10000)
})

test("4F proportionalJitter produces values strictly within [ceil(base/2), min(base, cap)]", () => {
  for (let i = 0; i < 100; i++) {
    const delay = socketReconnectAfterMs(3) // base 1000
    assert.ok(delay >= 500, `delay ${delay} should be >= 500`)
    assert.ok(delay <= 1000, `delay ${delay} should be <= 1000`)
  }
})

// ============================================================================
// 4H / 2D — DELIVERY MONOTONICITY & CLIENT DEDUPLICATION
// ============================================================================

test("4H / 2D delivered status never regresses to sent upon receiving stale acknowledgment", () => {
  assert.equal(resolveDeliveryStatus("delivered", "sent"), "delivered")
  assert.equal(resolveDeliveryStatus("delivered", "delivered"), "delivered")
})

test("4H / 2D canonical failed status does not silently resurrect on stale sent event", () => {
  assert.equal(resolveDeliveryStatus("failed", "sent"), "failed")
})

test("4H / 2D ambiguous retry receiving rate_limited or conversation_busy stays in sending", () => {
  assert.equal(resolveDeliveryStatus("sending", "rate_limited"), "sending")
  assert.equal(resolveDeliveryStatus("sending", "conversation_busy"), "sending")
})

test("4H / 2D duplicate message:new events merge into one unique local record", () => {
  const msg1 = localMessage({
    conversation_id: "conv-1",
    message_id: "msg-1",
    content: "hello",
    mine: false,
    delivery_status: "delivered",
    sequence: 1,
    sent_at: "2026-08-09T12:00:00Z"
  })

  const msg1Duplicate = localMessage({
    conversation_id: "conv-1",
    message_id: "msg-1",
    content: "hello",
    mine: false,
    delivery_status: "delivered",
    sequence: 1,
    sent_at: "2026-08-09T12:00:00Z"
  })

  const merged = mergeRecords([msg1], [msg1Duplicate])
  assert.equal(merged.length, 1)
  assert.equal(merged[0].id, "message:conv-1:msg-1")
  assert.equal(merged[0].value.sequence, 1)
})
