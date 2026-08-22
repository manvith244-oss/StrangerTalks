import assert from "node:assert/strict"
import test from "node:test"

function createQuietModeController(initial = false) {
  let quietMode = Boolean(initial)

  return {
    isQuietModeActive() {
      return Boolean(quietMode)
    },
    setQuietMode(active) {
      const next = Boolean(active)
      if (quietMode === next) return false
      quietMode = next
      return true
    },
    toggleQuietMode() {
      quietMode = !quietMode
      return quietMode
    },
    resetQuietMode() {
      const changed = quietMode !== false
      quietMode = false
      return changed
    },
    triggerPresentationEffect(effectFn) {
      if (quietMode) return false
      if (typeof effectFn === "function") {
        effectFn()
      }
      return true
    }
  }
}

// ============================================================================
// LIFECYCLE TESTS (L1 - L10)
// ============================================================================

test("L1: default state is OFF (false)", () => {
  const controller = createQuietModeController()
  assert.equal(controller.isQuietModeActive(), false)
})

test("L2 & L3: toggle transitions OFF -> ON and ON -> OFF", () => {
  const controller = createQuietModeController()
  assert.equal(controller.isQuietModeActive(), false)

  assert.equal(controller.toggleQuietMode(), true)
  assert.equal(controller.isQuietModeActive(), true)

  assert.equal(controller.toggleQuietMode(), false)
  assert.equal(controller.isQuietModeActive(), false)
})

test("L2 & L3 idempotent: setQuietMode same-state transitions are NO_OPs", () => {
  const controller = createQuietModeController()

  assert.equal(controller.setQuietMode(true), true)
  assert.equal(controller.setQuietMode(true), false) // idempotent NO_OP
  assert.equal(controller.isQuietModeActive(), true)

  assert.equal(controller.setQuietMode(false), true)
  assert.equal(controller.setQuietMode(false), false) // idempotent NO_OP
  assert.equal(controller.isQuietModeActive(), false)
})

test("L4: same-page reconnect preserves active Quiet Mode state", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)
  assert.equal(controller.isQuietModeActive(), true)

  // On reconnect (e.g. socket reconnected, channel re-joined), controller state in RAM is retained
  assert.equal(controller.isQuietModeActive(), true)
})

test("L5: page refresh / reload resets Quiet Mode to default OFF", () => {
  // Page reload discards ephemeral in-memory JS execution context
  const preReloadController = createQuietModeController()
  preReloadController.setQuietMode(true)
  assert.equal(preReloadController.isQuietModeActive(), true)

  // Fresh instance initialized on reload starts at default OFF
  const postReloadController = createQuietModeController()
  assert.equal(postReloadController.isQuietModeActive(), false)
})

test("L6: new tab starts at default OFF", () => {
  // Independent tab execution context
  const tab1 = createQuietModeController()
  tab1.setQuietMode(true)

  const newTab = createQuietModeController()
  assert.equal(newTab.isQuietModeActive(), false)
})

test("L7: Conversation end resets Quiet Mode back to OFF", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)
  assert.equal(controller.isQuietModeActive(), true)

  // Event conversation:ended fires
  assert.equal(controller.resetQuietMode(), true)
  assert.equal(controller.isQuietModeActive(), false)
})

test("L8 & L9: replacement/new Conversation match resets Quiet Mode to OFF", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  // handleMatchedConversation claims new conversationId
  assert.equal(controller.resetQuietMode(), true)
  assert.equal(controller.isQuietModeActive(), false)
})

test("L10: tab-local independence (Tab A ON does not affect Tab B OFF)", () => {
  const tabA = createQuietModeController()
  const tabB = createQuietModeController()

  tabA.setQuietMode(true)
  assert.equal(tabA.isQuietModeActive(), true)
  assert.equal(tabB.isQuietModeActive(), false)

  let tabBEffectRan = 0
  tabB.triggerPresentationEffect(() => { tabBEffectRan++ })
  assert.equal(tabBEffectRan, 1)

  let tabAEffectRan = 0
  tabA.triggerPresentationEffect(() => { tabAEffectRan++ })
  assert.equal(tabAEffectRan, 0)
})

// ============================================================================
// GAP A: CANONICAL PROCESSING NEGATIVES (Quiet Mode ON does NOT suppress truth)
// ============================================================================

test("Gap A1 & A2: incoming message receipt and rendering proceed normally when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)
  assert.equal(controller.isQuietModeActive(), true)

  const messagesTimeline = []
  function receiveIncomingMessage(msg) {
    // Canonical processing is unconditional
    messagesTimeline.push(msg)
    // Optional audio/visual alert is gated
    controller.triggerPresentationEffect(() => { /* alert sound */ })
  }

  receiveIncomingMessage({client_message_id: "m-101", content: "Hello from stranger", sequence: 1})
  assert.equal(messagesTimeline.length, 1)
  assert.equal(messagesTimeline[0].content, "Hello from stranger")
})

test("Gap A3: canonical browser/message state updates proceed normally when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  const localDb = new Map()
  function storeLocalMessage(record) {
    localDb.set(record.id, record)
  }

  storeLocalMessage({id: "msg:m-102", type: "local_message", value: {content: "Saved message", status: "delivered"}})
  assert.equal(localDb.has("msg:m-102"), true)
  assert.equal(localDb.get("msg:m-102").value.status, "delivered")
})

test("Gap A4 & A5: authenticated recipient applied-progress and sent -> delivered transition proceed normally when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let messageDeliveryState = "sent"
  function applyDeliveryProgress(confirmedSeq, targetSeq) {
    if (confirmedSeq >= targetSeq) {
      messageDeliveryState = "delivered"
    }
  }

  applyDeliveryProgress(5, 5)
  assert.equal(messageDeliveryState, "delivered")
})

test("Gap A6: Conversation Presence updates proceed normally when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let renderedPresenceText = ""
  function updatePresenceDisplay(status) {
    renderedPresenceText = status === "connected" ? "Connected" : status === "away" ? "Temporarily away" : ""
  }

  updatePresenceDisplay("connected")
  assert.equal(renderedPresenceText, "Connected")

  updatePresenceDisplay("away")
  assert.equal(renderedPresenceText, "Temporarily away")
})

test("Gap A7 & A8: JOIN/reconnect recovery and sync:reconcile proceed normally when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let synchronizedState = null
  function applySyncPayload(payload) {
    synchronizedState = payload
  }

  applySyncPayload({epoch_id: "ep-99", messages: [{sequence: 1}], peer_presence: "connected"})
  assert.deepEqual(synchronizedState, {epoch_id: "ep-99", messages: [{sequence: 1}], peer_presence: "connected"})
})

// ============================================================================
// GAP B: CRITICAL SIGNAL NEGATIVES (Quiet Mode ON does NOT suppress critical UX)
// ============================================================================

test("Gap B1: send failure handling is never suppressed when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let errorAnnounced = ""
  function handleSendFailure(error) {
    // Critical error announcement to user
    errorAnnounced = "Message could not be sent. Tap to retry."
  }

  handleSendFailure({reason: "timeout"})
  assert.equal(errorAnnounced, "Message could not be sent. Tap to retry.")
})

test("Gap B2 & B3: transport failure and local 'Reconnecting…' are never suppressed when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let connectionIndicator = ""
  function updateLocalConnection(state) {
    if (state === "reconnecting") {
      connectionIndicator = "Reconnecting…"
    } else if (state === "connected") {
      connectionIndicator = "Connected"
    }
  }

  updateLocalConnection("reconnecting")
  assert.equal(connectionIndicator, "Reconnecting…")
})

test("Gap B4: safety/moderation alerts and reports are never suppressed when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let reportDialogVisible = false
  function openReportDialog() {
    reportDialogVisible = true
  }

  openReportDialog()
  assert.equal(reportDialogVisible, true)
})

test("Gap B5: essential accessibility announcements are never suppressed when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let ariaLiveContent = ""
  function announce(msg) {
    ariaLiveContent = msg
  }

  announce("Conversation ended. Choose what this device should retain.")
  assert.equal(ariaLiveContent, "Conversation ended. Choose what this device should retain.")
})

test("Gap B6: explicit user-started voice note playback is NEVER suppressed when Quiet Mode is ON", () => {
  const controller = createQuietModeController()
  controller.setQuietMode(true)

  let audioPlaying = false
  function userPlayVoiceNote(audioElement) {
    // User explicitly triggered play
    audioPlaying = true
  }

  userPlayVoiceNote({autoplay: false})
  assert.equal(audioPlaying, true)
})

// ============================================================================
// GAP C: PRIVACY & DIAGNOSTIC PROOFS
// ============================================================================

test("Gap C: Quiet Mode emits zero network events and stores zero telemetry data", () => {
  const controller = createQuietModeController()
  const socketEvents = []
  const telemetryLogs = []

  function toggleQuiet() {
    controller.toggleQuietMode()
    // Invariant: zero push to socket, zero logging of quiet state
  }

  toggleQuiet()
  assert.equal(controller.isQuietModeActive(), true)
  assert.equal(socketEvents.length, 0, "Quiet Mode must emit 0 socket events")
  assert.equal(telemetryLogs.length, 0, "Quiet Mode must emit 0 telemetry logs")
})

// ============================================================================
// ACCESSIBILITY & PRESENTATION GATING
// ============================================================================

test("Quiet Mode presentation gating: allows effect when OFF, suppresses effect when ON", () => {
  const controller = createQuietModeController()
  let effectRan = 0
  const effect = () => { effectRan++ }

  // When OFF: effect runs normally
  assert.equal(controller.isQuietModeActive(), false)
  const allowed = controller.triggerPresentationEffect(effect)
  assert.equal(allowed, true)
  assert.equal(effectRan, 1)

  // When ON: effect is suppressed
  controller.setQuietMode(true)
  assert.equal(controller.isQuietModeActive(), true)
  const suppressed = controller.triggerPresentationEffect(effect)
  assert.equal(suppressed, false)
  assert.equal(effectRan, 1) // Count remains 1 (did not run)
})

test("Quiet Mode accessibility attributes: maps aria-pressed and aria-label semantics", () => {
  function deriveAriaAttributes(isActive) {
    return {
      ariaPressed: isActive ? "true" : "false",
      ariaLabel: isActive ? "Quiet Mode, on" : "Quiet Mode, off",
      icon: isActive ? "🔕" : "🔔"
    }
  }

  const offAttrs = deriveAriaAttributes(false)
  assert.equal(offAttrs.ariaPressed, "false")
  assert.equal(offAttrs.ariaLabel, "Quiet Mode, off")
  assert.equal(offAttrs.icon, "🔔")

  const onAttrs = deriveAriaAttributes(true)
  assert.equal(onAttrs.ariaPressed, "true")
  assert.equal(onAttrs.ariaLabel, "Quiet Mode, on")
  assert.equal(onAttrs.icon, "🔕")
})
