import assert from "node:assert/strict"
import test from "node:test"
import {
  applyReconciliationIfCurrent,
  createSessionReconciliationGuard
} from "../../priv/static/assets/session_reconciliation_guard.mjs"

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return {promise, resolve}
}

async function reconcileAfterResponse(guard, responseBarrier, apply) {
  const requestRevision = guard.capture()
  const snapshot = await responseBarrier.promise
  return applyReconciliationIfCurrent(guard, requestRevision, () => apply(snapshot))
}

test("race 1: old QUEUED response is discarded after Attempt 2 becomes current", async () => {
  const guard = createSessionReconciliationGuard()
  const response = deferred()
  const state = {queueAttemptId: "attempt-1", screen: "queue", conversationId: null}
  const reconciliation = reconcileAfterResponse(guard, response, (snapshot) => {
    state.queueAttemptId = snapshot.queue_attempt_id
    state.screen = "queue"
  })

  state.queueAttemptId = null
  state.screen = "doors"
  guard.transition()
  state.queueAttemptId = "attempt-2"
  state.screen = "queue"
  guard.transition()
  response.resolve({canonical_state: "QUEUED", queue_attempt_id: "attempt-1"})

  assert.equal(await reconciliation, false)
  assert.deepEqual(state, {queueAttemptId: "attempt-2", screen: "queue", conversationId: null})
})

test("race 2: old QUEUED response is discarded after authoritative Cancel reaches Doors", async () => {
  const guard = createSessionReconciliationGuard()
  const response = deferred()
  const state = {queueAttemptId: "attempt-1", screen: "queue", conversationId: null}
  const reconciliation = reconcileAfterResponse(guard, response, (snapshot) => {
    state.queueAttemptId = snapshot.queue_attempt_id
    state.screen = "queue"
  })

  state.queueAttemptId = null
  state.screen = "doors"
  guard.transition()
  response.resolve({canonical_state: "QUEUED", queue_attempt_id: "attempt-1"})

  assert.equal(await reconciliation, false)
  assert.deepEqual(state, {queueAttemptId: null, screen: "doors", conversationId: null})
})

test("race 3: second revision check blocks AVAILABLE after its asynchronous boundary", async () => {
  const guard = createSessionReconciliationGuard()
  const postAwaitBarrier = deferred()
  const firstCheckPassed = deferred()
  const state = {queueAttemptId: null, screen: "queue", conversationId: null}
  const requestRevision = guard.capture()

  const reconciliation = (async () => {
    if (!guard.current(requestRevision)) return false
    const appliedRevision = guard.capture()
    firstCheckPassed.resolve()
    await postAwaitBarrier.promise
    if (!guard.current(appliedRevision)) return false
    state.queueAttemptId = null
    state.screen = "doors"
    return true
  })()

  await firstCheckPassed.promise
  state.queueAttemptId = "attempt-2"
  state.screen = "queue"
  guard.transition()
  postAwaitBarrier.resolve()

  assert.equal(await reconciliation, false)
  assert.deepEqual(state, {queueAttemptId: "attempt-2", screen: "queue", conversationId: null})
})

test("race 4: old reconciliation is discarded after Conversation becomes authoritative", async () => {
  const guard = createSessionReconciliationGuard()
  const response = deferred()
  const state = {queueAttemptId: "attempt-1", screen: "queue", conversationId: null}
  const reconciliation = reconcileAfterResponse(guard, response, (snapshot) => {
    state.queueAttemptId = snapshot.queue_attempt_id
    state.screen = "queue"
    state.conversationId = null
  })

  state.queueAttemptId = null
  state.screen = "conversation"
  state.conversationId = "conversation-current"
  guard.transition()
  response.resolve({canonical_state: "QUEUED", queue_attempt_id: "attempt-1"})

  assert.equal(await reconciliation, false)
  assert.deepEqual(state, {
    queueAttemptId: null,
    screen: "conversation",
    conversationId: "conversation-current"
  })
})

test("normal control: uncontested reconciliation applies", async () => {
  const guard = createSessionReconciliationGuard()
  const response = deferred()
  const state = {queueAttemptId: null, screen: "doors", conversationId: null}
  const reconciliation = reconcileAfterResponse(guard, response, (snapshot) => {
    state.queueAttemptId = snapshot.queue_attempt_id
    state.screen = "queue"
  })

  response.resolve({canonical_state: "QUEUED", queue_attempt_id: "attempt-current"})

  assert.equal(await reconciliation, true)
  assert.deepEqual(state, {
    queueAttemptId: "attempt-current",
    screen: "queue",
    conversationId: null
  })
})
