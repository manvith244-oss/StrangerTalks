export const DEFAULT_RAPID_TAP_WINDOW_MS = 900

export function createRapidTapGate(windowMs = DEFAULT_RAPID_TAP_WINDOW_MS) {
  const acceptedAt = new Map()

  return {
    accept(key, at = performance.now()) {
      if (!key) return true
      const previous = acceptedAt.get(key)
      if (Number.isFinite(previous) && at - previous < windowMs) return false
      acceptedAt.set(key, at)
      return true
    },
    clear(key) {
      acceptedAt.delete(key)
    },
    clearAll() {
      acceptedAt.clear()
    }
  }
}

export function isMobileInteractionSurface(win = globalThis.window) {
  if (!win) return false
  const narrowViewport = Number.isFinite(win.innerWidth) && win.innerWidth <= 760
  const coarsePointer = typeof win.matchMedia === "function" && win.matchMedia("(pointer: coarse)").matches
  return narrowViewport || coarsePointer
}

export function rapidTapActionKey(target) {
  if (!target || typeof target.closest !== "function") return null
  if (target.closest("#leave-queue")) return "queue:leave"
  if (target.closest("#doors button")) return "queue:start"
  return null
}

export function installMobileRapidTapGuard({
  doc = globalThis.document,
  win = globalThis.window,
  now = () => performance.now(),
  windowMs = DEFAULT_RAPID_TAP_WINDOW_MS
} = {}) {
  if (!doc || typeof doc.addEventListener !== "function") return null

  const gate = createRapidTapGate(windowMs)
  const onClick = (event) => {
    if (!isMobileInteractionSurface(win)) return
    const key = rapidTapActionKey(event.target)
    if (!key || gate.accept(key, now())) return

    event.preventDefault()
    event.stopImmediatePropagation()
  }

  doc.addEventListener("click", onClick, true)

  return {
    gate,
    destroy() {
      doc.removeEventListener("click", onClick, true)
      gate.clearAll()
    }
  }
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  installMobileRapidTapGuard()
}
