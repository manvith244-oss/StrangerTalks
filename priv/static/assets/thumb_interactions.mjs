const SYSTEM_EDGE_RESERVE_PX = 24
const LONG_PRESS_SUPPRESS_MS = 450
const INTENT_DRIFT_PX = 12
const COARSE_TARGET_PX = 48

const INTERACTIVE_SELECTOR = "button, a, audio, video, input, textarea, select, summary, .reaction-picker, .message-actions-bar"

export function isSystemEdgeStart(x, viewportWidth, reservePx = SYSTEM_EDGE_RESERVE_PX) {
  if (!Number.isFinite(x) || !Number.isFinite(viewportWidth) || viewportWidth <= 0) return false
  const reserve = Math.max(0, Math.min(Number(reservePx) || 0, viewportWidth / 2))
  return x <= reserve || x >= viewportWidth - reserve
}

export function shouldSuppressMessageRelease(start, end, {viewportWidth, longPressMs = LONG_PRESS_SUPPRESS_MS} = {}) {
  if (!start || !end) return false
  const elapsed = end.time - start.time
  const dx = end.x - start.x
  const dy = end.y - start.y
  const horizontalIntent = Math.abs(dx) > INTENT_DRIFT_PX && Math.abs(dx) > Math.abs(dy)

  // Preserve native iOS/Android edge navigation. StrangerTalks must never turn
  // a system-edge swipe into Reply or a reaction shortcut.
  if (horizontalIntent && isSystemEdgeStart(start.x, viewportWidth)) return true

  // Once a hold has crossed the established message-action threshold, release
  // belongs to that hold. It must not also become swipe-to-reply or double-tap.
  return elapsed >= longPressMs
}

export function coarseTargetMinimumPx() {
  return COARSE_TARGET_PX
}

function messageGestureIsInteractive(event) {
  return Boolean(event.target?.closest?.(INTERACTIVE_SELECTOR))
}

function installMessageGestureArbitration() {
  const list = document.querySelector("#messages")
  if (!list || list.dataset.thumbGestureArbitration === "true") return
  list.dataset.thumbGestureArbitration = "true"

  const starts = new Map()

  list.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "mouse" || messageGestureIsInteractive(event)) return
    const message = event.target.closest?.(".message")
    if (!message) return
    starts.set(event.pointerId, {
      message,
      time: performance.now(),
      x: event.clientX,
      y: event.clientY
    })
  }, {capture: true, passive: true})

  list.addEventListener("pointerup", (event) => {
    const start = starts.get(event.pointerId)
    starts.delete(event.pointerId)
    if (!start || start.message !== event.target.closest?.(".message")) return

    const end = {time: performance.now(), x: event.clientX, y: event.clientY}
    if (shouldSuppressMessageRelease(start, end, {viewportWidth: window.innerWidth})) {
      event.stopPropagation()
    }
  }, {capture: true, passive: true})

  list.addEventListener("pointercancel", (event) => {
    starts.delete(event.pointerId)
  }, {capture: true, passive: true})
}

function closeComposerTray(form, plus) {
  if (!form?.classList.contains("ig-tray-open")) return false
  form.classList.remove("ig-tray-open")
  plus?.setAttribute("aria-expanded", "false")
  return true
}

function installOutsideTapDismissal() {
  const form = document.querySelector("#message-form")
  const plus = form?.querySelector(".ig-compose-plus")
  if (!form || form.dataset.thumbOutsideDismissal === "true") return
  form.dataset.thumbOutsideDismissal = "true"

  document.addEventListener("pointerdown", (event) => {
    if (!form.classList.contains("ig-tray-open") || form.contains(event.target)) return
    closeComposerTray(form, plus)
  }, {passive: true})
}

function installCoarsePointerTargets() {
  if (document.querySelector('style[data-thumb-interaction-targets="true"]')) return
  const style = document.createElement("style")
  style.dataset.thumbInteractionTargets = "true"
  style.textContent = `
    body.st-chat-mode .overflow-menu #pinned-messages-control,
    body.st-chat-mode .overflow-menu #quiet-mode-control {
      display: block;
    }

    @media (hover: none) and (pointer: coarse) {
      body.st-chat-mode .ig-chat-back,
      body.st-chat-mode .conversation-head-actions > button,
      body.st-chat-mode .conversation-head-actions > details > summary,
      body.st-chat-mode .ig-compose-icon,
      body.st-chat-mode .compose #voice-start,
      body.st-chat-mode .compose #view-once-picker-btn {
        width: ${COARSE_TARGET_PX}px;
        height: ${COARSE_TARGET_PX}px;
        min-width: ${COARSE_TARGET_PX}px;
        min-height: ${COARSE_TARGET_PX}px;
      }

      body.st-chat-mode .compose > .primary,
      body.st-chat-mode .voice-controls > button,
      body.st-chat-mode .voice-controls #expressive-open,
      body.st-chat-mode .voice-controls #companion-control,
      body.st-chat-mode .overflow-menu button,
      body.st-chat-mode .message-action-btn,
      body.st-chat-mode .reaction-picker .reaction-btn,
      body.st-chat-mode #reply-cancel,
      body.st-chat-mode #icebreaker-dismiss,
      body.st-chat-mode .temporary-conversation-cue .text-action,
      body.st-chat-mode .new-messages,
      body.st-chat-mode .voice-sheet button,
      body.st-chat-mode .atmosphere-chooser button,
      body.st-chat-mode #report-form button,
      body.st-chat-mode .prompt-helper button {
        min-height: ${COARSE_TARGET_PX}px;
      }

      body.st-chat-mode .reaction-picker .reaction-btn,
      body.st-chat-mode #reply-cancel {
        min-width: ${COARSE_TARGET_PX}px;
      }
    }
  `
  document.head.append(style)
}

export function bootThumbInteractions() {
  if (typeof document === "undefined") return
  installCoarsePointerTargets()

  const install = () => {
    installMessageGestureArbitration()
    installOutsideTapDismissal()
  }

  install()
  queueMicrotask(install)
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bootThumbInteractions, {once: true})
  else bootThumbInteractions()
}
