export const DEFAULT_RAPID_TAP_WINDOW_MS = 900
export const RECENT_TOUCH_WINDOW_MS = 750

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

export function isTouchActivation(event, recentTouch = false) {
  const pointerType = typeof event?.pointerType === "string" ? event.pointerType : ""
  if (pointerType === "touch") return true
  if (pointerType === "mouse" || pointerType === "pen") return false
  if (event?.sourceCapabilities?.firesTouchEvents === true) return true
  if (Number(event?.detail) === 0) return false
  return recentTouch
}

export function rapidTapActionKey(target) {
  if (!target || typeof target.closest !== "function") return null
  if (target.closest("#leave-queue")) return "queue:leave"
  if (target.closest("#doors button.door")) return "queue:start"
  return null
}

export function presentationLifecycleAction(eventType, visibilityState) {
  if (eventType === "pagehide" || visibilityState === "hidden") return "clear-transient"
  if (eventType === "pageshow" || (eventType === "visibilitychange" && visibilityState === "visible")) return "refresh"
  return "none"
}

function refreshViewportPresentation(win) {
  if (!win || typeof win.dispatchEvent !== "function") return false
  const EventCtor = win.Event || globalThis.Event
  if (typeof EventCtor !== "function") return false
  win.dispatchEvent(new EventCtor("resize"))
  return true
}

function syncKeyboardPresentationFromFocus(doc) {
  const body = doc?.body
  if (!body?.classList || typeof doc.querySelector !== "function") return false
  const input = doc.querySelector("#message-input")
  const focused = Boolean(input && doc.activeElement === input)
  body.classList.toggle("ig-keyboard-open", focused)
  return focused
}

export function installMobilePresentationBoundary({
  doc = globalThis.document,
  win = globalThis.window
} = {}) {
  if (!doc || !win || typeof doc.addEventListener !== "function" || typeof win.addEventListener !== "function") return null

  const apply = (eventType) => {
    const action = presentationLifecycleAction(eventType, doc.visibilityState)
    if (action === "clear-transient") {
      doc.body?.classList?.remove("ig-keyboard-open")
    } else if (action === "refresh") {
      syncKeyboardPresentationFromFocus(doc)
      refreshViewportPresentation(win)
    }
    return action
  }

  const onVisibilityChange = () => apply("visibilitychange")
  const onPageHide = () => apply("pagehide")
  const onPageShow = () => apply("pageshow")

  doc.addEventListener("visibilitychange", onVisibilityChange)
  win.addEventListener("pagehide", onPageHide)
  win.addEventListener("pageshow", onPageShow)

  return {
    apply,
    destroy() {
      doc.removeEventListener("visibilitychange", onVisibilityChange)
      win.removeEventListener("pagehide", onPageHide)
      win.removeEventListener("pageshow", onPageShow)
    }
  }
}

export function installMobileRapidTapGuard({
  doc = globalThis.document,
  win = globalThis.window,
  now = () => performance.now(),
  windowMs = DEFAULT_RAPID_TAP_WINDOW_MS
} = {}) {
  if (!doc || typeof doc.addEventListener !== "function") return null

  const gate = createRapidTapGate(windowMs)
  const recentTouchAt = new Map()

  const onPointerUp = (event) => {
    if (!isMobileInteractionSurface(win) || event?.pointerType !== "touch") return
    const key = rapidTapActionKey(event.target)
    if (key) recentTouchAt.set(key, now())
  }

  const onClick = (event) => {
    if (!isMobileInteractionSurface(win)) return
    const key = rapidTapActionKey(event.target)
    if (!key) return

    const at = now()
    const lastTouch = recentTouchAt.get(key)
    const recentTouch = Number.isFinite(lastTouch) && at >= lastTouch && at - lastTouch <= RECENT_TOUCH_WINDOW_MS
    if (!isTouchActivation(event, recentTouch)) return
    if (gate.accept(key, at)) return

    event.preventDefault()
    event.stopImmediatePropagation()
  }

  doc.addEventListener("pointerup", onPointerUp, true)
  doc.addEventListener("click", onClick, true)

  return {
    gate,
    destroy() {
      doc.removeEventListener("pointerup", onPointerUp, true)
      doc.removeEventListener("click", onClick, true)
      recentTouchAt.clear()
      gate.clearAll()
    }
  }
}

export function installMobileFlow(options = {}) {
  const rapidTapGuard = installMobileRapidTapGuard(options)
  const presentationBoundary = installMobilePresentationBoundary(options)

  return {
    rapidTapGuard,
    presentationBoundary,
    destroy() {
      rapidTapGuard?.destroy()
      presentationBoundary?.destroy()
    }
  }
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  installMobileFlow({doc: document, win: window})
  if (document.documentElement?.dataset) document.documentElement.dataset.f09MobileFlowBooted = "true"
}
