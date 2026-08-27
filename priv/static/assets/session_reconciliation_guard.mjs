import {Socket} from "/vendor/phoenix.mjs"
import {installF11Runtime} from "./f11_persistence_runtime.mjs"

installF11Runtime({SocketClass: Socket})

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
