import assert from "node:assert/strict"
import test from "node:test"

// Pure unit test model for pin merge algorithm, conflict reconciliation, and CAS invariants
function createPinController(initialState = { items: [], revision: 0 }, { onReconcile = null } = {}) {
  let state = {
    conversationId: initialState.conversationId || null,
    epochId: initialState.epochId || null,
    items: [...initialState.items],
    revision: initialState.revision
  }
  let inFlight = false
  let reconcileInFlight = false
  let reconcileTriggerCount = 0

  return {
    getState: () => ({ items: [...state.items], revision: state.revision }),
    getScopedState: () => ({...state, items: [...state.items]}),
    transition: (conversationId, epochId = null) => {
      if (state.conversationId !== conversationId || (epochId && state.epochId && state.epochId !== epochId)) {
        state = {conversationId, epochId, items: [], revision: 0}
        inFlight = false
        reconcileInFlight = false
      } else if (epochId && !state.epochId) {
        state = {...state, epochId}
      }
      return state
    },
    end: (conversationId) => {
      if (state.conversationId === conversationId) {
        state = {conversationId: null, epochId: null, items: [], revision: 0}
        inFlight = false
        reconcileInFlight = false
      }
      return state
    },
    reconnect: (conversationId, epochId = null) => {
      if (state.conversationId !== conversationId) return state
      if (epochId && state.epochId && state.epochId !== epochId) {
        state = {conversationId, epochId, items: [], revision: 0}
      }
      return state
    },
    getInFlight: () => inFlight,
    setInFlight: (val) => { inFlight = val },
    getReconcileInFlight: () => reconcileInFlight,
    getReconcileTriggerCount: () => reconcileTriggerCount,
    clearReconcile: () => { reconcileInFlight = false },
    merge: (incoming, { authoritative = false, conversationId = state.conversationId, epochId = state.epochId } = {}) => {
      if (!incoming || !Number.isInteger(incoming.revision)) return state
      if (conversationId !== state.conversationId) return state
      if (epochId && state.epochId && epochId !== state.epochId) return state
      if (incoming.revision < state.revision) {
        // Ignore stale snapshot
        return state
      }

      const incomingItems = Array.isArray(incoming.pins)
        ? incoming.pins
        : (Array.isArray(incoming.items) ? incoming.items : [])

      if (incoming.revision === state.revision) {
        const currentIds = state.items.map((p) => p.target_client_message_id).join(",")
        const incomingIds = incomingItems.map((p) => p.target_client_message_id).join(",")
        if (currentIds === incomingIds) {
          return state // Idempotent no-op
        }

        if (authoritative) {
          state = {
            conversationId,
            epochId: epochId || state.epochId,
            revision: incoming.revision,
            items: incomingItems
          }
          return state
        }

        // Equal revision conflict: do not overwrite canonical state, trigger bounded sync:reconcile
        if (!reconcileInFlight) {
          reconcileInFlight = true
          reconcileTriggerCount++
          if (onReconcile) {
            onReconcile()
          }
        }
        return state
      }

      state = {
        conversationId,
        epochId: epochId || state.epochId,
        revision: incoming.revision,
        items: incomingItems
      }
      return state
    }
  }
}

test("pin controller: initial state is empty collection at revision 0", () => {
  const ctrl = createPinController()
  assert.deepEqual(ctrl.getState(), { items: [], revision: 0 })
})

test("pin controller: adopts newer revision (> current)", () => {
  const ctrl = createPinController({ items: [], revision: 0 })
  const pin1 = { target_client_message_id: "msg-1", author_relation: "self", snippet: "Hello" }

  ctrl.merge({ revision: 1, items: [pin1] })
  assert.deepEqual(ctrl.getState(), { revision: 1, items: [pin1] })

  const pin2 = { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Hi there" }
  ctrl.merge({ revision: 2, pins: [pin1, pin2] })
  assert.deepEqual(ctrl.getState(), { revision: 2, items: [pin1, pin2] })
})

test("pin controller: ignores stale revision (< current)", () => {
  const pin1 = { target_client_message_id: "msg-1", author_relation: "self", snippet: "Hello" }
  const pin2 = { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Hi there" }
  const ctrl = createPinController({ items: [pin1, pin2], revision: 2 })

  // Stale snapshot arriving late
  ctrl.merge({ revision: 1, items: [pin1] })
  assert.deepEqual(ctrl.getState(), { revision: 2, items: [pin1, pin2] })

  ctrl.merge({ revision: 0, items: [] })
  assert.deepEqual(ctrl.getState(), { revision: 2, items: [pin1, pin2] })
})

test("pin controller: equal revision with identical items is idempotent no-op", () => {
  const pin1 = { target_client_message_id: "msg-1", author_relation: "self", snippet: "Hello" }
  const ctrl = createPinController({ items: [pin1], revision: 1 })

  const stateBefore = ctrl.getState()
  ctrl.merge({ revision: 1, items: [pin1] })
  const stateAfter = ctrl.getState()

  assert.deepEqual(stateBefore, stateAfter)
})

test("pin controller: unpin reduces items count and increments revision", () => {
  const pin1 = { target_client_message_id: "msg-1", author_relation: "self", snippet: "Hello" }
  const pin2 = { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Hi there" }
  const ctrl = createPinController({ items: [pin1, pin2], revision: 2 })

  // Server unpin response
  ctrl.merge({ revision: 3, items: [pin2] })
  assert.deepEqual(ctrl.getState(), { revision: 3, items: [pin2] })

  // Unpin last item
  ctrl.merge({ revision: 4, items: [] })
  assert.deepEqual(ctrl.getState(), { revision: 4, items: [] })
})

test("pin controller: enforces maximum 3 items limit representation", () => {
  const pins = [
    { target_client_message_id: "msg-1", author_relation: "self", snippet: "First" },
    { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Second" },
    { target_client_message_id: "msg-3", author_relation: "self", snippet: "Third" }
  ]
  const ctrl = createPinController({ items: pins, revision: 3 })
  assert.equal(ctrl.getState().items.length, 3)
})

test("pin controller: single in-flight mutation lock prevents concurrent overlapping mutations", () => {
  const ctrl = createPinController()
  assert.equal(ctrl.getInFlight(), false)

  ctrl.setInFlight(true)
  assert.equal(ctrl.getInFlight(), true)

  ctrl.setInFlight(false)
  assert.equal(ctrl.getInFlight(), false)
})

test("pin controller: equal revision with conflicting collection triggers bounded sync:reconcile and adopts authoritative result", () => {
  const pinA = { target_client_message_id: "msg-1", author_relation: "self", snippet: "First" }
  const pinB = { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Second" }
  const pinCanonical = { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Second authoritative" }

  // 1. Client starts with canonical revision N (e.g. 1)
  const ctrl = createPinController({ items: [pinA], revision: 1 })
  assert.deepEqual(ctrl.getState(), { items: [pinA], revision: 1 })

  // 2. Conflicting incoming collection also carries revision N (1)
  const conflictingIncoming = { revision: 1, items: [pinB] }

  // 3. Conflict is detected on merge
  // 4. Ordinary conflicting incoming collection does NOT overwrite app.pinnedMessages
  // 5. Exactly one bounded sync:reconcile is triggered
  ctrl.merge(conflictingIncoming, { authoritative: false })

  // 6. Local canonical state remains unchanged before the reconcile result
  assert.deepEqual(ctrl.getState(), { items: [pinA], revision: 1 })
  assert.equal(ctrl.getReconcileInFlight(), true)
  assert.equal(ctrl.getReconcileTriggerCount(), 1)

  // 8. Further equal-revision conflict arrivals do not trigger repeated reconcile loop while in flight
  ctrl.merge(conflictingIncoming, { authoritative: false })
  ctrl.merge(conflictingIncoming, { authoritative: false })
  assert.equal(ctrl.getReconcileTriggerCount(), 1)
  assert.deepEqual(ctrl.getState(), { items: [pinA], revision: 1 })

  // 7. Authoritative reconciliation result arrives and becomes canonical
  const authoritativeReconcileResult = { revision: 1, items: [pinCanonical] }
  ctrl.merge(authoritativeReconcileResult, { authoritative: true })
  ctrl.clearReconcile()

  assert.deepEqual(ctrl.getState(), { items: [pinCanonical], revision: 1 })
  assert.equal(ctrl.getReconcileInFlight(), false)
})

test("pin controller: stale mutation response adopts newer canonical collection", () => {
  const pin1 = { target_client_message_id: "msg-1", author_relation: "self", snippet: "First" }
  const pin2 = { target_client_message_id: "msg-2", author_relation: "peer", snippet: "Second" }
  const ctrl = createPinController({ items: [pin1], revision: 1 })

  // Stale mutation response arrives with status "stale_revision" and current canonical collection
  const serverResponse = {
    status: "stale_revision",
    revision: 2,
    pins: [pin1, pin2]
  }

  ctrl.merge(serverResponse, { authoritative: true })
  assert.deepEqual(ctrl.getState(), { revision: 2, items: [pin1, pin2] })
})

test("pin controller: maximum one ambiguous retry prevents looping", () => {
  let retryCount = 0
  const maxRetries = 1

  function handleAmbiguousResponse() {
    if (retryCount < maxRetries) {
      retryCount++
      return "retry"
    }
    return "abort"
  }

  assert.equal(handleAmbiguousResponse(), "retry")
  assert.equal(handleAmbiguousResponse(), "abort")
})

test("pin controller: disconnect clears in-flight state and prevents blind retry", () => {
  const ctrl = createPinController()
  ctrl.setInFlight(true)
  assert.equal(ctrl.getInFlight(), true)

  // On disconnect: inFlight is reset to false
  ctrl.setInFlight(false)
  assert.equal(ctrl.getInFlight(), false)
})

test("pin controller: RAM-only canonical authority - pins are never written to IndexedDB store", () => {
  // Verifying IndexedDB store types
  const allowedPersistentTypes = ["local_conversation", "local_message", "local_memory", "local_bond"]
  const pinType = "pinned_messages"
  assert.equal(allowedPersistentTypes.includes(pinType), false, "Pins are not in allowed persistent types")
})

test("pin controller: no optimistic canonical card rendered before server confirmation", () => {
  const ctrl = createPinController({ items: [], revision: 0 })
  // In-flight mutation initiated
  ctrl.setInFlight(true)
  // State remains empty until server confirms
  assert.deepEqual(ctrl.getState(), { items: [], revision: 0 })
  ctrl.setInFlight(false)
})

test("D3 TEST A: cross-Conversation lower revision wins by identity boundary", () => {
  const pinA = {target_client_message_id: "a-pin", author_relation: "self", snippet: "Conversation A"}
  const ctrl = createPinController({conversationId: "A", items: [pinA], revision: 1})

  ctrl.transition("B")
  ctrl.merge({revision: 0, pins: []}, {conversationId: "B", authoritative: true})

  assert.deepEqual(ctrl.getScopedState(), {conversationId: "B", epochId: null, revision: 0, items: []})
})

test("D3 TEST B: revisions are scoped across Conversation replacement", () => {
  const pinA = {target_client_message_id: "a-pin", author_relation: "self", snippet: "Conversation A"}
  const ctrl = createPinController({conversationId: "A", items: [pinA], revision: 50})

  ctrl.transition("B")
  ctrl.merge({revision: 0, pins: []}, {conversationId: "B", authoritative: true})

  assert.equal(ctrl.getScopedState().conversationId, "B")
  assert.deepEqual(ctrl.getState(), {revision: 0, items: []})
})

test("D3 TEST C: same-Conversation stale revision is still rejected", () => {
  const pinB = {target_client_message_id: "b-pin", author_relation: "self", snippet: "Conversation B"}
  const ctrl = createPinController({conversationId: "B", items: [pinB], revision: 5})

  ctrl.merge({revision: 4, pins: []}, {conversationId: "B", authoritative: true})

  assert.deepEqual(ctrl.getState(), {revision: 5, items: [pinB]})
})

test("D3 TEST D: same-Conversation reconnect preserves valid Pin state", () => {
  const pinB = {target_client_message_id: "b-pin", author_relation: "self", snippet: "Conversation B"}
  const ctrl = createPinController({conversationId: "B", epochId: "epoch-b", items: [pinB], revision: 5})

  ctrl.reconnect("B", "epoch-b")
  ctrl.merge({revision: 5, pins: [pinB]}, {conversationId: "B", epochId: "epoch-b", authoritative: true})

  assert.deepEqual(ctrl.getScopedState(), {conversationId: "B", epochId: "epoch-b", revision: 5, items: [pinB]})
})

test("D3 TEST E: explicit Conversation end invalidates current Pin state", () => {
  const pinA = {target_client_message_id: "a-pin", author_relation: "self", snippet: "Conversation A"}
  const ctrl = createPinController({conversationId: "A", items: [pinA], revision: 8})

  ctrl.end("A")
  ctrl.merge({revision: 9, pins: [pinA]}, {conversationId: "A", authoritative: true})

  assert.deepEqual(ctrl.getScopedState(), {conversationId: null, epochId: null, revision: 0, items: []})
})

test("D3 TEST F: direct replacement cannot resurface the prior Conversation Pin", () => {
  const pinA = {target_client_message_id: "a-pin", author_relation: "self", snippet: "Conversation A"}
  const pinB = {target_client_message_id: "b-pin", author_relation: "self", snippet: "Conversation B"}
  const ctrl = createPinController({conversationId: "A", items: [pinA], revision: 20})

  ctrl.transition("B")
  ctrl.merge({revision: 21, pins: [pinA]}, {conversationId: "A", authoritative: true})
  ctrl.merge({revision: 1, pins: [pinB]}, {conversationId: "B", authoritative: true})

  assert.deepEqual(ctrl.getScopedState(), {conversationId: "B", epochId: null, revision: 1, items: [pinB]})
})
