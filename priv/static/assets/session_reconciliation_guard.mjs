import {Socket} from "/vendor/phoenix.mjs"
import {installCanonicalIndexedDB} from "./f11_local_store.mjs"
import {installF11Runtime} from "./f11_persistence_runtime.mjs"
import {installConversationDraftRuntime} from "./conversation_draft_runtime.mjs"

// F-11 persistence must be established before app.js performs bootstrap reads.
// This installs only the browser-storage boundary; it does not decide routes,
// Matchmaking state, or Conversation lifecycle.
installCanonicalIndexedDB(globalThis)
installF11Runtime({SocketClass: Socket})
installConversationDraftRuntime({SocketClass: Socket})

export function createSessionReconciliationGuard() {
  let revision = 0

  return {
    capture: () => revision,
    current: (capturedRevision) => capturedRevision === revision,
    transition: () => ++revision
  }
}

export function applyReconciliationIfCurrent(guard, capturedRevision, apply) {
  if (!guard.current(capturedRevision)) return false
  apply()
  return true
}
