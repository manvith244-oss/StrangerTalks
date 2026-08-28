if (typeof window !== "undefined" && window === globalThis) {
  await import("./session_reconciliation_browser_bootstrap.mjs")
}

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
