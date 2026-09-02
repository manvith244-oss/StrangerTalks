import assert from "node:assert/strict"
import test from "node:test"

function derivePresenceDisplayText(localConnectionState, peerPresence) {
  if (localConnectionState === "reconnecting" || localConnectionState === "recovery") {
    return "Reconnecting…"
  }

  if (peerPresence === "connected") {
    return "Connected"
  } else if (peerPresence === "away") {
    return "Temporarily away"
  } else {
    return ""
  }
}

function resolveVisibilityPayload(docVisibilityState) {
  return docVisibilityState === "hidden" ? "hidden" : "visible"
}

test("presence text: connected renders 'Connected'", () => {
  const text = derivePresenceDisplayText("connected", "connected")
  assert.equal(text, "Connected")
})

test("presence text: away renders 'Temporarily away'", () => {
  const text = derivePresenceDisplayText("connected", "away")
  assert.equal(text, "Temporarily away")
})

test("presence text: zero sessions / null renders empty indicator", () => {
  assert.equal(derivePresenceDisplayText("connected", null), "")
  assert.equal(derivePresenceDisplayText("connected", undefined), "")
  assert.equal(derivePresenceDisplayText("connected", ""), "")
})

test("presence text: local reconnecting state overrides peer presence with 'Reconnecting…'", () => {
  assert.equal(derivePresenceDisplayText("reconnecting", "connected"), "Reconnecting…")
  assert.equal(derivePresenceDisplayText("reconnecting", "away"), "Reconnecting…")
  assert.equal(derivePresenceDisplayText("reconnecting", null), "Reconnecting…")

  assert.equal(derivePresenceDisplayText("recovery", "connected"), "Reconnecting…")
  assert.equal(derivePresenceDisplayText("recovery", "away"), "Reconnecting…")
  assert.equal(derivePresenceDisplayText("recovery", null), "Reconnecting…")
})

test("presence text: local connection recovery restores accurate peer presence text", () => {
  let localState = "reconnecting"
  let peerPresence = "away"

  assert.equal(derivePresenceDisplayText(localState, peerPresence), "Reconnecting…")

  localState = "connected"
  assert.equal(derivePresenceDisplayText(localState, peerPresence), "Temporarily away")
})

test("visibility helper: maps document.visibilityState accurately", () => {
  assert.equal(resolveVisibilityPayload("hidden"), "hidden")
  assert.equal(resolveVisibilityPayload("visible"), "visible")
  assert.equal(resolveVisibilityPayload("prerender"), "visible")
})

test("presence text: forbids fabrication of Offline, Last Seen, or exact timestamps", () => {
  const possibleOutputs = [
    derivePresenceDisplayText("connected", "connected"),
    derivePresenceDisplayText("connected", "away"),
    derivePresenceDisplayText("connected", null),
    derivePresenceDisplayText("reconnecting", null),
    derivePresenceDisplayText("recovery", null)
  ]

  for (const out of possibleOutputs) {
    assert.equal(/offline/i.test(out), false)
    assert.equal(/last seen/i.test(out), false)
    assert.equal(/am|pm|\d{1,2}:\d{2}/i.test(out), false)
  }
})
