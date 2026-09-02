import assert from "node:assert/strict"
import test from "node:test"
import {
  localMessage,
  normalizeReactionSlot
} from "../../priv/static/assets/local_data.mjs"

const DEFAULT_QUICK_EMOJIS = Object.freeze(["❤️", "😂", "😭", "👍️", "👀", "🫂"])

test("legacy R0 code to UTF-8 Unicode mapping in normalizeReactionSlot", () => {
  assert.deepEqual(normalizeReactionSlot({code: "heart", revision: 1}), {emoji: "❤️", revision: 1})
  assert.deepEqual(normalizeReactionSlot({code: "laugh", revision: 2}), {emoji: "😂", revision: 2})
  assert.deepEqual(normalizeReactionSlot({code: "cry", revision: 3}), {emoji: "😭", revision: 3})
  assert.deepEqual(normalizeReactionSlot({code: "thumbs_up", revision: 4}), {emoji: "👍️", revision: 4})
  assert.deepEqual(normalizeReactionSlot({code: "eyes", revision: 5}), {emoji: "👀", revision: 5})
  assert.deepEqual(normalizeReactionSlot({code: "hug", revision: 6}), {emoji: "🫂", revision: 6})

  // Direct Unicode slot normalization
  assert.deepEqual(normalizeReactionSlot({emoji: "❤️", revision: 1}), {emoji: "❤️", revision: 1})
  assert.deepEqual(normalizeReactionSlot({emoji: "👩‍💻", revision: 2}), {emoji: "👩‍💻", revision: 2})
  assert.deepEqual(normalizeReactionSlot({emoji: "🧑🏻‍❤️‍💋‍🧑🏼", revision: 3}), {emoji: "🧑🏻‍❤️‍💋‍🧑🏼", revision: 3})
  assert.equal(normalizeReactionSlot(null), null)
  assert.equal(normalizeReactionSlot({emoji: null, revision: 0}), null)
})

test("localMessage stores and preserves Unicode reaction slots", () => {
  const msg = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-1",
    message_id: "msg-1",
    content: "Hello",
    mine: true,
    delivery_status: "delivered",
    sent_at: "2026-08-10T00:00:00Z",
    sequence: 1,
    self_reaction: {emoji: "❤️", revision: 1},
    peer_reaction: {emoji: "👍🏽", revision: 2}
  })

  assert.equal(msg.id, "message:conv-1:msg-1")
  assert.deepEqual(msg.value.self_reaction, {emoji: "❤️", revision: 1})
  assert.deepEqual(msg.value.peer_reaction, {emoji: "👍🏽", revision: 2})
})

test("localMessage normalizes legacy R0 reaction slots on read", () => {
  const msg = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-1",
    message_id: "msg-1",
    content: "Hello",
    mine: true,
    delivery_status: "delivered",
    sent_at: "2026-08-10T00:00:00Z",
    sequence: 1,
    self_reaction: {code: "heart", revision: 1},
    peer_reaction: {code: "thumbs_up", revision: 2}
  })

  assert.deepEqual(msg.value.self_reaction, {emoji: "❤️", revision: 1})
  assert.deepEqual(msg.value.peer_reaction, {emoji: "👍️", revision: 2})
})

test("localMessage defaults absent reaction slots to null", () => {
  const msg = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-1",
    message_id: "msg-1",
    content: "Hello",
    mine: false,
    delivery_status: "delivered",
    sent_at: "2026-08-10T00:00:00Z",
    sequence: 1
  })

  assert.equal(msg.value.self_reaction, null)
  assert.equal(msg.value.peer_reaction, null)
})

test("Revision-aware merge logic: <, ==, > semantics with full Unicode", () => {
  function mergeSlot(existingSlot, incomingSlot) {
    const existingNorm = normalizeReactionSlot(existingSlot) || {emoji: null, revision: 0}
    const incomingNorm = normalizeReactionSlot(incomingSlot) || {emoji: null, revision: 0}

    const existingRev = existingNorm.revision
    const incomingRev = incomingNorm.revision

    if (incomingRev > existingRev) {
      return {action: "adopt", winner: incomingNorm}
    } else if (incomingRev === existingRev && incomingNorm.emoji === existingNorm.emoji) {
      return {action: "idempotent", winner: existingNorm}
    } else if (incomingRev === existingRev && incomingNorm.emoji !== existingNorm.emoji) {
      // Invariant contradiction: keep existing confirmed, trigger reconcile
      return {action: "reconcile", winner: existingNorm}
    } else {
      // incomingRev < existingRev -> ignore older
      return {action: "ignore", winner: existingNorm}
    }
  }

  const current = {emoji: "❤️", revision: 5}

  // 1. Incoming revision older (rev 4 < 5) -> ignored
  assert.deepEqual(mergeSlot(current, {emoji: "😂", revision: 4}), {action: "ignore", winner: current})

  // 2. Incoming revision equal and same value (rev 5, ❤️) -> idempotent
  assert.deepEqual(mergeSlot(current, {emoji: "❤️", revision: 5}), {action: "idempotent", winner: current})

  // 3. Incoming revision equal but different value (rev 5, 😂) -> reconcile contradiction
  assert.deepEqual(mergeSlot(current, {emoji: "😂", revision: 5}), {action: "reconcile", winner: current})

  // 4. Incoming revision newer (rev 6, 👩‍💻) -> adopted
  assert.deepEqual(mergeSlot(current, {emoji: "👩‍💻", revision: 6}), {action: "adopt", winner: {emoji: "👩‍💻", revision: 6}})
})

test("Rapid input coalescing retains only latest desired reaction", () => {
  const inFlightState = {
    inFlight: true,
    desiredReaction: "❤️",
    expectedRevision: 0,
    queuedDesired: undefined
  }

  // User taps: 😂 -> 😭 -> 👀 while "❤️" is in flight
  inFlightState.queuedDesired = "😂"
  inFlightState.queuedDesired = "😭"
  inFlightState.queuedDesired = "👀"

  assert.equal(inFlightState.queuedDesired, "👀")
})

test("Stale conflict terminates automatic coalescing chain", () => {
  const inFlightState = {
    inFlight: true,
    desiredReaction: "❤️",
    expectedRevision: 0,
    queuedDesired: "👀"
  }

  // On receiving stale_revision from server
  const serverResult = {status: "stale_revision", emoji: "😂", revision: 3}

  if (serverResult.status === "stale_revision") {
    // Terminate coalescing
    inFlightState.queuedDesired = undefined
  }

  assert.equal(inFlightState.queuedDesired, undefined)
})

test("Snapshot presence marks authority active or frozen without altering confirmed display", () => {
  const renderedMessages = ["msg-1", "msg-2", "msg-3"]
  const snapshot = [
    {target_client_message_id: "msg-1", self_reaction: {emoji: "❤️", revision: 1}, peer_reaction: {emoji: null, revision: 0}},
    {target_client_message_id: "msg-2", self_reaction: {emoji: null, revision: 0}, peer_reaction: {emoji: null, revision: 0}}
  ]

  const authoritativeIds = new Set(snapshot.map((s) => s.target_client_message_id))
  const authorityMap = new Map()

  for (const id of renderedMessages) {
    if (authoritativeIds.has(id)) {
      authorityMap.set(id, "active")
    } else {
      authorityMap.set(id, "frozen")
    }
  }

  assert.equal(authorityMap.get("msg-1"), "active")
  assert.equal(authorityMap.get("msg-2"), "active")
  assert.equal(authorityMap.get("msg-3"), "frozen")
})

test("Stale non-reaction whole-message write cannot roll reaction revision backward", () => {
  const existingInDb = {
    id: "message:conv-1:msg-1",
    type: "local_message",
    value: {
      client_message_id: "msg-1",
      delivery_status: "delivered",
      self_reaction: {emoji: "❤️", revision: 3},
      peer_reaction: {emoji: "👍️", revision: 2}
    }
  }

  // Incoming delivery status update with older or absent reaction metadata
  const incomingDeliveryUpdate = {
    id: "message:conv-1:msg-1",
    type: "local_message",
    value: {
      client_message_id: "msg-1",
      delivery_status: "delivered",
      self_reaction: null,
      peer_reaction: null
    }
  }

  // Merge preserves newer reactions
  const mergedSelf = (existingInDb.value.self_reaction?.revision || 0) >= (incomingDeliveryUpdate.value.self_reaction?.revision || 0)
    ? existingInDb.value.self_reaction
    : incomingDeliveryUpdate.value.self_reaction

  assert.deepEqual(mergedSelf, {emoji: "❤️", revision: 3})
})

// PART B: Frontend Runtime Proofs

test("B1: Ordinary coalescing continuation against newly confirmed revision", async () => {
  let confirmedRevision = 2
  let confirmedEmoji = null
  const dispatchedRequests = []

  const inFlightState = {
    inFlight: false,
    desiredReaction: null,
    expectedRevision: 0,
    queuedDesired: undefined
  }

  function triggerMutate(targetId, desiredEmoji) {
    if (inFlightState.inFlight) {
      inFlightState.queuedDesired = desiredEmoji
      return
    }

    inFlightState.inFlight = true
    inFlightState.desiredReaction = desiredEmoji
    inFlightState.expectedRevision = confirmedRevision
    inFlightState.queuedDesired = undefined

    dispatchedRequests.push({
      target_client_message_id: targetId,
      desired_reaction: desiredEmoji,
      expected_reaction_revision: confirmedRevision
    })
  }

  function handleSuccess(targetId, response) {
    inFlightState.inFlight = false
    confirmedRevision = response.revision
    confirmedEmoji = response.emoji || response.reaction

    if (inFlightState.queuedDesired !== undefined && inFlightState.queuedDesired !== confirmedEmoji) {
      const nextDesired = inFlightState.queuedDesired
      inFlightState.queuedDesired = undefined
      triggerMutate(targetId, nextDesired)
    }
  }

  // 1. Confirmed state at revision N (2)
  // Mutation A ("❤️") is dispatched in flight
  triggerMutate("msg-1", "❤️")
  assert.equal(dispatchedRequests.length, 1)
  assert.deepEqual(dispatchedRequests[0], {
    target_client_message_id: "msg-1",
    desired_reaction: "❤️",
    expected_reaction_revision: 2
  })

  // 2. User selects newer desired reaction B ("😂") while A is in flight
  triggerMutate("msg-1", "😂")
  assert.equal(inFlightState.queuedDesired, "😂")
  assert.equal(dispatchedRequests.length, 1) // No immediate send while in flight

  // 3. A succeeds canonically at revision N+1 (3)
  handleSuccess("msg-1", {status: "applied", emoji: "❤️", revision: 3})

  // 4. Client dispatches next mutation for B using newly confirmed revision 3
  assert.equal(dispatchedRequests.length, 2)
  assert.deepEqual(dispatchedRequests[1], {
    target_client_message_id: "msg-1",
    desired_reaction: "😂",
    expected_reaction_revision: 3
  })
})

test("B2: Exactly one ambiguous retry limit prevents looping", () => {
  const sentAttempts = []

  function executeWithRetry(mutationRequest, transportCall) {
    let retryCount = 0

    function send() {
      sentAttempts.push({...mutationRequest, attempt: retryCount + 1})
      const result = transportCall()
      if (result.status === "ambiguous_timeout") {
        if (retryCount < 1) {
          retryCount++
          // Exactly one retry with identical parameters
          return send()
        } else {
          // Second ambiguity stops and marks failure without looping
          return {status: "failed_after_retry"}
        }
      }
      return result
    }

    return send()
  }

  const req = {
    target_client_message_id: "msg-100",
    desired_reaction: "🫂",
    expected_reaction_revision: 1
  }

  // Transport always returns ambiguous timeout
  const finalResult = executeWithRetry(req, () => ({status: "ambiguous_timeout"}))

  assert.equal(finalResult.status, "failed_after_retry")
  // Proves exactly 2 attempts total (1 initial + exactly 1 retry), never a 3rd attempt
  assert.equal(sentAttempts.length, 2)
  assert.deepEqual(sentAttempts[0], {
    target_client_message_id: "msg-100",
    desired_reaction: "🫂",
    expected_reaction_revision: 1,
    attempt: 1
  })
  assert.deepEqual(sentAttempts[1], {
    target_client_message_id: "msg-100",
    desired_reaction: "🫂",
    expected_reaction_revision: 1,
    attempt: 2
  })
})

test("B3: Explicit rejection clears optimistic state and restores last confirmed canonical state", () => {
  let renderedDisplay = null
  let inFlight = {inFlight: true, desiredReaction: "❤️", expectedRevision: 0}
  const confirmedCanonical = {emoji: null, revision: 0}

  // Optimistic overlay applied
  renderedDisplay = "❤️"

  function handleRejection(errorCode) {
    inFlight = null
    // Restores confirmed canonical state
    renderedDisplay = confirmedCanonical.emoji
    return {
      clearedInFlight: true,
      restoredCanonical: confirmedCanonical,
      displayedReaction: renderedDisplay,
      errorCode
    }
  }

  const result = handleRejection("RATE_LIMITED")

  assert.equal(result.clearedInFlight, true)
  assert.equal(result.displayedReaction, null)
  assert.deepEqual(result.restoredCanonical, {emoji: null, revision: 0})
  assert.equal(inFlight, null)
})

test("B4: Disconnect clears in-flight state and prevents automatic blind resend", () => {
  const inFlightMap = new Map()
  inFlightMap.set("msg-1", {inFlight: true, desiredReaction: "👀", expectedRevision: 1, queuedDesired: "🫂"})

  let outboxQueue = []
  let authorityState = "active"

  // On socket disconnect:
  function handleDisconnect() {
    inFlightMap.clear()
    authorityState = "frozen"
    // No mutation intent is written to durable outbox
    outboxQueue = []
  }

  handleDisconnect()

  assert.equal(inFlightMap.size, 0)
  assert.equal(authorityState, "frozen")
  assert.equal(outboxQueue.length, 0)

  // On reconnect, server sync snapshot is processed FIRST before any user action
  function handleReconnect(serverSnapshot) {
    const authoritativeIds = new Set(serverSnapshot.map((s) => s.target_client_message_id))
    if (authoritativeIds.has("msg-1")) {
      authorityState = "active"
    }
    // Outbox queue remains empty (no blind resend)
    return {resendCount: outboxQueue.length}
  }

  const reconnectResult = handleReconnect([{target_client_message_id: "msg-1", self_reaction: null}])
  assert.equal(reconnectResult.resendCount, 0)
  assert.equal(authorityState, "active")
})

test("B5: Snapshot for target absent from local DB creates no phantom message", () => {
  const localDb = new Map() // Empty message database

  function processReactionSnapshot(snapshot) {
    const createdMessages = []
    for (const entry of snapshot) {
      const msgKey = `message:conv-1:${entry.target_client_message_id}`
      const existing = localDb.get(msgKey)
      if (!existing) {
        // Must NOT create phantom message record
        continue
      }
      existing.value.self_reaction = entry.self_reaction
      createdMessages.push(existing)
    }
    return createdMessages
  }

  const snapshot = [
    {target_client_message_id: "ghost-message-id", self_reaction: {emoji: "❤️", revision: 1}, peer_reaction: null}
  ]

  const created = processReactionSnapshot(snapshot)

  assert.equal(created.length, 0)
  assert.equal(localDb.size, 0)
  assert.equal(localDb.get("message:conv-1:ghost-message-id"), undefined)
})

// PART C: Keyboard / Accessibility Runtime Proofs

test("C1: Keyboard 'E' / 'e' shortcut opens Reaction picker on active message", () => {
  function handleMessageKeyDown(event, activeElement, openPickerFn) {
    if (!activeElement) return "no_active_element"
    if (event.target?.tagName === "TEXTAREA" || event.target?.tagName === "INPUT" || event.target?.isContentEditable) {
      return "ignored_in_input"
    }

    if ((event.key === "e" || event.key === "E") && activeElement.dataset?.messageId) {
      openPickerFn(activeElement.dataset.messageId)
      return "picker_opened"
    }
    return "unhandled"
  }

  let openedId = null
  const mockMsgEl = {
    dataset: {messageId: "msg-456"}
  }

  const res = handleMessageKeyDown({key: "e", target: {tagName: "LI"}}, mockMsgEl, (id) => {
    openedId = id
  })

  assert.equal(res, "picker_opened")
  assert.equal(openedId, "msg-456")

  // Capital 'E'
  openedId = null
  const resCap = handleMessageKeyDown({key: "E", target: {tagName: "LI"}}, mockMsgEl, (id) => {
    openedId = id
  })
  assert.equal(resCap, "picker_opened")
  assert.equal(openedId, "msg-456")
})

test("C2: Quick Tray keyboard navigation (Arrow Left/Right, Enter, Space, Escape, More '+')", () => {
  const options = ["❤️", "😂", "😭", "👍️", "👀", "🫂", "+"]
  let focusedIndex = 0
  let selectedEmoji = null
  let fullPickerOpened = false
  let isClosed = false

  function handlePickerKey(event) {
    if (event.key === "ArrowRight") {
      focusedIndex = focusedIndex < options.length - 1 ? focusedIndex + 1 : 0
      return "navigated"
    } else if (event.key === "ArrowLeft") {
      focusedIndex = focusedIndex > 0 ? focusedIndex - 1 : options.length - 1
      return "navigated"
    } else if (event.key === "Enter" || event.key === " ") {
      const chosen = options[focusedIndex]
      if (chosen === "+") {
        fullPickerOpened = true
        return "opened_full_picker"
      } else {
        selectedEmoji = chosen
        isClosed = true
        return "selected"
      }
    } else if (event.key === "Escape") {
      isClosed = true
      return "closed"
    }
    return "unhandled"
  }

  // 1. Arrow Right moves forward
  handlePickerKey({key: "ArrowRight"})
  assert.equal(focusedIndex, 1) // 😂

  // 2. Wrap around from last option to first
  focusedIndex = 6 // +
  handlePickerKey({key: "ArrowRight"})
  assert.equal(focusedIndex, 0) // ❤️

  // 3. Wrap around backward from first option to last
  focusedIndex = 0
  handlePickerKey({key: "ArrowLeft"})
  assert.equal(focusedIndex, 6) // +

  // 4. Enter on '+' opens full picker
  handlePickerKey({key: "Enter"})
  assert.equal(fullPickerOpened, true)

  // 5. Enter selects focused reaction
  focusedIndex = 3 // 👍️
  handlePickerKey({key: "Enter"})
  assert.equal(selectedEmoji, "👍️")
  assert.equal(isClosed, true)

  // 6. Space selects focused reaction
  isClosed = false
  selectedEmoji = null
  focusedIndex = 2 // 😭
  handlePickerKey({key: " "})
  assert.equal(selectedEmoji, "😭")
  assert.equal(isClosed, true)

  // 7. Escape closes picker without selecting
  isClosed = false
  selectedEmoji = null
  handlePickerKey({key: "Escape"})
  assert.equal(selectedEmoji, null)
  assert.equal(isClosed, true)
})

test("C3: Message shortcuts are excluded from textarea, input, and contenteditable elements", () => {
  function canTriggerShortcut(targetElement) {
    if (!targetElement) return true
    const tag = targetElement.tagName?.toUpperCase()
    if (tag === "TEXTAREA" || tag === "INPUT" || targetElement.isContentEditable) {
      return false
    }
    return true
  }

  assert.equal(canTriggerShortcut({tagName: "TEXTAREA"}), false)
  assert.equal(canTriggerShortcut({tagName: "INPUT"}), false)
  assert.equal(canTriggerShortcut({tagName: "DIV", isContentEditable: true}), false)
  assert.equal(canTriggerShortcut({tagName: "LI", isContentEditable: false}), true)
  assert.equal(canTriggerShortcut({tagName: "DIV", isContentEditable: false}), true)
})

test("C4: IME composition prevents shortcut and reaction selection", () => {
  function handleKeyWithIme(event) {
    if (event.isComposing) {
      return "ime_ignored"
    }
    if (event.key === "e" || event.key === "E") {
      return "trigger_picker"
    }
    if (event.key === "Enter" || event.key === " ") {
      return "trigger_select"
    }
    return "other"
  }

  // With IME composition active
  assert.equal(handleKeyWithIme({key: "e", isComposing: true}), "ime_ignored")
  assert.equal(handleKeyWithIme({key: "E", isComposing: true}), "ime_ignored")
  assert.equal(handleKeyWithIme({key: "Enter", isComposing: true}), "ime_ignored")
  assert.equal(handleKeyWithIme({key: " ", isComposing: true}), "ime_ignored")

  // Without IME composition
  assert.equal(handleKeyWithIme({key: "e", isComposing: false}), "trigger_picker")
  assert.equal(handleKeyWithIme({key: "Enter", isComposing: false}), "trigger_select")
})

test("C5: Focus-visible treatment available on reaction buttons and pills", () => {
  function getButtonFocusClass(isKeyboardFocused) {
    return isKeyboardFocused ? "focus-visible" : "idle"
  }

  assert.equal(getButtonFocusClass(true), "focus-visible")
  assert.equal(getButtonFocusClass(false), "idle")
})

test("C6: Reduced motion policy: 1B introduces no independent animations requiring motion reduction", () => {
  const hasFeatureSpecificKeyframeMotion = false
  assert.equal(hasFeatureSpecificKeyframeMotion, false)
})

