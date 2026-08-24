import "./companion.mjs"

const HEART = "❤️"
const DOUBLE_TAP_MS = 320
const DOUBLE_TAP_DISTANCE_PX = 26
const TAP_MOVEMENT_PX = 12
const MAX_COMPOSER_HEIGHT_PX = 120

const ICONS = Object.freeze({
  back: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>',
  phone: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M7.2 3.5l2.2-.5 1.5 4-1.7 1.2a15 15 0 006.6 6.6l1.2-1.7 4 1.5-.5 2.2a3 3 0 01-3 2.4C10.7 18.7 5.3 13.3 4.8 6.5a3 3 0 012.4-3z"/></svg>',
  video: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="12" height="12" rx="3"/><path d="M15 10l5-3v10l-5-3z"/></svg>',
  info: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 10v6M12 7h.01"/></svg>',
  camera: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7.5h3l1.4-2h7.2l1.4 2h3a2 2 0 012 2v8a2 2 0 01-2 2H4a2 2 0 01-2-2v-8a2 2 0 012-2z"/><circle cx="12" cy="13" r="4"/></svg>',
  mic: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0013 0M12 18v3M9 21h6"/></svg>',
  plus: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/></svg>',
  prompt: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l1.4 4.3L18 9l-4.6 1.7L12 15l-1.4-4.3L6 9l4.6-1.7z"/><path d="M18.5 14l.8 2 2.2.8-2.2.8L19 19l-.8-2.2-2.2-.8 2.2-.8z"/></svg>',
  gallery: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="2"/><path d="M4 17l5-4 3 2 3-3 5 5"/></svg>',
  privacy: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l8 3v5c0 5.2-3.3 8.3-8 10-4.7-1.7-8-4.8-8-10V6z"/><path d="M9.5 12l1.7 1.7 3.6-4"/></svg>',
  magic: '<svg class="ig-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20L16.5 7.5M14 4l1 2.5L17.5 8 15 9l-1 2.5L13 9l-2.5-1L13 6.5zM19 13l.8 2 2.2.8-2.2.8L19 19l-.8-2.2-2.2-.8 2.2-.8z"/></svg>'
})

export function composerVisualState(value) {
  return {hasText: typeof value === "string" && value.trim().length > 0}
}

export function messageGrouping(ownership) {
  if (!Array.isArray(ownership)) return []
  return ownership.map((mine, index) => {
    const previousSame = index > 0 && ownership[index - 1] === mine
    const nextSame = index < ownership.length - 1 && ownership[index + 1] === mine
    if (!previousSame && !nextSame) return "solo"
    if (!previousSame && nextSame) return "start"
    if (previousSame && nextSame) return "middle"
    return "end"
  })
}

export function shouldTriggerQuickHeart(previousTap, currentTap) {
  if (!previousTap || !currentTap) return false
  const elapsed = currentTap.time - previousTap.time
  const dx = currentTap.x - previousTap.x
  const dy = currentTap.y - previousTap.y
  return elapsed > 0 && elapsed <= DOUBLE_TAP_MS && Math.hypot(dx, dy) <= DOUBLE_TAP_DISTANCE_PX
}

export function isTapGesture(start, end) {
  if (!start || !end) return false
  const elapsed = end.time - start.time
  const dx = end.x - start.x
  const dy = end.y - start.y
  return elapsed >= 0 && elapsed <= DOUBLE_TAP_MS && Math.hypot(dx, dy) <= TAP_MOVEMENT_PX
}

export function normalizedViewportHeight(visualHeight, fallbackHeight) {
  const candidate = Number.isFinite(visualHeight) && visualHeight > 0 ? visualHeight : fallbackHeight
  if (!Number.isFinite(candidate) || candidate <= 0) return 720
  return Math.max(1, Math.round(candidate))
}

function ensureStylesheet() {
  if (document.querySelector('link[data-instagram-chat-ui="true"]')) return
  const link = document.createElement("link")
  link.rel = "stylesheet"
  link.href = "/assets/instagram_chat.css?v=20260823_1"
  link.dataset.instagramChatUi = "true"
  document.head.append(link)
}

function ensureInteractionHardeningStyles() {
  if (document.querySelector('style[data-instagram-chat-hardening="true"]')) return
  const style = document.createElement("style")
  style.dataset.instagramChatHardening = "true"
  style.textContent = `
    @media (max-height: 520px) and (orientation: landscape) {
      body.st-chat-mode .conversation-head {
        padding-left: calc(10px + env(safe-area-inset-left, 0px));
        padding-right: calc(10px + env(safe-area-inset-right, 0px));
      }
      body.st-chat-mode .conversation #messages {
        padding-left: calc(12px + env(safe-area-inset-left, 0px));
        padding-right: calc(12px + env(safe-area-inset-right, 0px));
      }
      body.st-chat-mode #message-form.composer {
        padding-left: calc(8px + env(safe-area-inset-left, 0px));
        padding-right: calc(8px + env(safe-area-inset-right, 0px));
      }
    }
    @media (hover: none) and (pointer: coarse) {
      body.st-chat-mode .reaction-picker .reaction-btn {
        width: 44px;
        height: 44px;
        min-width: 44px;
        min-height: 44px;
      }
      body.st-chat-mode .message-action-btn,
      body.st-chat-mode #reply-cancel,
      body.st-chat-mode #icebreaker-dismiss,
      body.st-chat-mode .temporary-conversation-cue .text-action {
        min-height: 44px;
      }
    }
  `
  document.head.append(style)
}

function iconButton(button, icon, label, extraClass = "") {
  if (!button) return
  button.innerHTML = ICONS[icon] || ""
  button.setAttribute("aria-label", label)
  button.title = label
  button.classList.add("ig-icon-button")
  if (extraClass) button.classList.add(extraClass)
}

function trayButton(button, icon, label) {
  if (!button) return
  const currentLabel = button.querySelector(":scope > span")?.textContent
  const alreadyDecorated = button.dataset.igTrayLabel === label && Boolean(button.querySelector(":scope > .ig-icon")) && currentLabel === label
  if (!alreadyDecorated) {
    button.innerHTML = `${ICONS[icon] || ""}<span>${label}</span>`
    button.dataset.igTrayLabel = label
  }
  button.setAttribute("aria-label", label)
  button.title = label
  button.classList.add("ig-tray-button")
}

function syncVisualViewport() {
  const height = normalizedViewportHeight(window.visualViewport?.height, window.innerHeight)
  document.documentElement.style.setProperty("--ig-vh", `${height}px`)
}

function setupVisualViewport() {
  syncVisualViewport()
  window.addEventListener("resize", syncVisualViewport, {passive: true})
  window.visualViewport?.addEventListener("resize", syncVisualViewport, {passive: true})
  window.visualViewport?.addEventListener("scroll", syncVisualViewport, {passive: true})
}

function setChatMode() {
  const conversation = document.querySelector('[data-screen="conversation"]')
  const active = Boolean(conversation?.classList.contains("active"))
  document.body.classList.toggle("st-chat-mode", active)
  if (!active) document.body.classList.remove("ig-keyboard-open")
  if (active) syncVisualViewport()
}

function setupScreenState() {
  const conversation = document.querySelector('[data-screen="conversation"]')
  if (!conversation) return
  setChatMode()
  new MutationObserver(setChatMode).observe(conversation, {attributes: true, attributeFilter: ["class"]})
}

function setupHeader() {
  const head = document.querySelector(".conversation-head")
  const identity = head?.querySelector(".conversation-identity")
  const actions = head?.querySelector(".conversation-head-actions")
  if (!head || !identity || !actions) return

  if (!head.querySelector(".ig-chat-back")) {
    const back = document.createElement("button")
    back.type = "button"
    back.className = "ig-chat-back"
    back.innerHTML = ICONS.back
    back.setAttribute("aria-label", "Back to chats")
    back.title = "Back to chats"
    back.addEventListener("click", () => {
      document.querySelector('#bottom-nav [data-go="chats"]')?.click()
    })
    head.insertBefore(back, identity)
  }

  const heading = identity.querySelector("h1")
  if (heading && heading.textContent.trim().toLowerCase() === "conversation") heading.textContent = "Stranger"

  identity.querySelector(".signature-ribbon")?.setAttribute("title", "Anonymous stranger")

  iconButton(document.querySelector("#btn-voice-call"), "phone", "Start voice call")
  iconButton(document.querySelector("#btn-video-call"), "video", "Start video call")

  const overflow = actions.querySelector(".overflow")
  const summary = overflow?.querySelector("summary")
  if (summary) {
    summary.innerHTML = ICONS.info
    summary.setAttribute("aria-label", "Conversation info and safety")
    summary.title = "Conversation info and safety"
  }

  const menu = overflow?.querySelector(".overflow-menu")
  if (!menu || menu.dataset.igPrepared === "true") return
  menu.dataset.igPrepared = "true"

  const tools = [
    document.querySelector("#pinned-messages-control"),
    document.querySelector("#quiet-mode-control"),
    document.querySelector("#atmosphere-control"),
    document.querySelector("#ambient-audio-control")
  ].filter(Boolean)

  const firstDanger = menu.querySelector("#end-conversation, #report-open, #block")
  for (const tool of tools) {
    tool.classList.add("ig-menu-tool")
    if (firstDanger) menu.insertBefore(tool, firstDanger)
    else menu.append(tool)
    tool.addEventListener("click", () => {
      setTimeout(() => { if (overflow.open) overflow.open = false }, 0)
    })
  }

  if (firstDanger && !menu.querySelector(".ig-menu-divider")) {
    const divider = document.createElement("div")
    divider.className = "ig-menu-divider"
    divider.setAttribute("role", "separator")
    menu.insertBefore(divider, firstDanger)
  }
}

function setupTemporaryCue() {
  const cue = document.querySelector(".temporary-conversation-cue")
  if (!cue) return
  const strong = cue.querySelector("strong")
  const action = cue.querySelector("button")
  if (strong) strong.textContent = "Temporary chat"
  if (action) action.textContent = "How it works"
}

function decorateTrayControls() {
  trayButton(document.querySelector("#prompt-control"), "prompt", "Prompts")
  trayButton(document.querySelector("#view-once-video-picker-btn"), "gallery", "View-once video")
  trayButton(document.querySelector("#expressive-open"), "magic", "GIFs & stickers")
  trayButton(document.querySelector("#companion-control"), "magic", "Companion")
  trayButton(document.querySelector("#voice-warning-help"), "privacy", "Media privacy")
}

function autosizeComposer(input) {
  if (!input) return
  input.style.height = "auto"
  const next = Math.min(MAX_COMPOSER_HEIGHT_PX, Math.max(44, input.scrollHeight || 44))
  input.style.height = `${next}px`
}

function observeProgrammaticComposerValue(input, onChange) {
  if (!input || input.dataset.igValueObserved === "true") return
  const descriptor = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")
  if (!descriptor?.get || !descriptor?.set) return
  Object.defineProperty(input, "value", {
    configurable: true,
    get() { return descriptor.get.call(this) },
    set(value) {
      descriptor.set.call(this, value)
      queueMicrotask(onChange)
    }
  })
  input.dataset.igValueObserved = "true"
}

function setupComposer() {
  const form = document.querySelector("#message-form")
  const compose = form?.querySelector(".compose")
  const input = document.querySelector("#message-input")
  const controls = form?.querySelector(".voice-controls")
  const send = compose?.querySelector('button[type="submit"], button.primary')
  const voice = document.querySelector("#voice-start")
  const photo = document.querySelector("#view-once-picker-btn")
  const expressive = document.querySelector("#expressive-composer")
  if (!form || !compose || !input || !controls || !send) return

  input.placeholder = "Message…"
  input.setAttribute("enterkeyhint", "send")
  input.style.fontSize = "16px"
  send.setAttribute("aria-label", "Send message")
  send.title = "Send message"

  if (photo && photo.parentElement !== compose) {
    compose.insertBefore(photo, input)
    iconButton(photo, "camera", "Send a view-once photo")
  }

  if (voice && voice.parentElement !== compose) {
    send.before(voice)
    iconButton(voice, "mic", "Record voice note")
  }

  let plus = compose.querySelector(".ig-compose-plus")
  if (!plus) {
    plus = document.createElement("button")
    plus.type = "button"
    plus.className = "ig-compose-icon ig-compose-plus"
    plus.innerHTML = ICONS.plus
    plus.setAttribute("aria-label", "More message options")
    plus.setAttribute("aria-expanded", "false")
    plus.setAttribute("aria-controls", "ig-message-tools")
    plus.title = "More message options"
    send.before(plus)
  }

  controls.id = "ig-message-tools"
  if (expressive && expressive.parentElement !== controls) controls.append(expressive)

  const updateState = () => {
    const state = composerVisualState(input.value)
    form.classList.toggle("has-text", state.hasText)
    if (state.hasText && form.classList.contains("ig-tray-open")) {
      form.classList.remove("ig-tray-open")
      plus.setAttribute("aria-expanded", "false")
    }
    autosizeComposer(input)
  }

  observeProgrammaticComposerValue(input, updateState)

  plus.addEventListener("click", () => {
    const opening = !form.classList.contains("ig-tray-open")
    form.classList.toggle("ig-tray-open", opening)
    plus.setAttribute("aria-expanded", String(opening))
    if (opening) decorateTrayControls()
  })

  input.addEventListener("input", updateState)
  input.addEventListener("focus", () => {
    updateState()
    document.body.classList.add("ig-keyboard-open")
    setTimeout(syncVisualViewport, 0)
  })
  input.addEventListener("blur", () => {
    setTimeout(() => {
      if (document.activeElement !== input) document.body.classList.remove("ig-keyboard-open")
      syncVisualViewport()
    }, 80)
  })

  form.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return
    if (form.classList.contains("ig-tray-open")) {
      form.classList.remove("ig-tray-open")
      plus.setAttribute("aria-expanded", "false")
      input.focus()
    }
  })

  new MutationObserver(decorateTrayControls).observe(controls, {childList: true, subtree: true})
  decorateTrayControls()
  updateState()
}

function refreshMessageDecorations() {
  const messages = Array.from(document.querySelectorAll("#messages > .message"))
  if (!messages.length) return

  const ownership = messages.map((message) => message.classList.contains("mine"))
  const groups = messageGrouping(ownership)

  messages.forEach((message, index) => {
    message.classList.remove("ig-group-solo", "ig-group-start", "ig-group-middle", "ig-group-end", "ig-latest-own")
    message.classList.add(`ig-group-${groups[index]}`)
  })

  const latestOwn = [...messages].reverse().find((message) => message.classList.contains("mine") && !message.classList.contains("message-unsent"))
  latestOwn?.classList.add("ig-latest-own")
}

function eventIsInteractive(event) {
  return Boolean(event.target.closest("button, a, audio, video, input, textarea, select, summary, .reaction-picker, .message-actions-bar"))
}

function applyQuickHeart(message) {
  if (!message || message.classList.contains("message-unsent")) return false
  const currentSelf = message.querySelector(".message-reactions .reaction-pill.self")
  if (currentSelf?.textContent?.trim() === HEART) return true

  const reactButton = message.querySelector(".react-action-btn")
  if (!reactButton) return false

  reactButton.click()
  requestAnimationFrame(() => {
    const picker = message.querySelector(".reaction-picker") || document.querySelector(".reaction-picker")
    const heart = picker?.querySelector(`.reaction-btn[data-emoji="${HEART}"]`)
    heart?.click()
  })

  message.classList.remove("ig-heart-pop")
  requestAnimationFrame(() => message.classList.add("ig-heart-pop"))
  setTimeout(() => message.classList.remove("ig-heart-pop"), 320)
  return true
}

function setupMessageInteractions() {
  const list = document.querySelector("#messages")
  if (!list) return

  const touchTaps = new WeakMap()
  const pointerStarts = new Map()

  list.addEventListener("dblclick", (event) => {
    if (eventIsInteractive(event)) return
    const message = event.target.closest(".message")
    if (!message) return
    event.preventDefault()
    window.getSelection?.()?.removeAllRanges?.()
    applyQuickHeart(message)
  })

  list.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "mouse" || eventIsInteractive(event)) return
    const message = event.target.closest(".message")
    if (!message) return
    pointerStarts.set(event.pointerId, {
      message,
      time: performance.now(),
      x: event.clientX,
      y: event.clientY
    })
  }, {passive: true})

  list.addEventListener("pointerup", (event) => {
    if (event.pointerType === "mouse" || eventIsInteractive(event)) return
    const message = event.target.closest(".message")
    const start = pointerStarts.get(event.pointerId)
    pointerStarts.delete(event.pointerId)
    if (!message || !start || start.message !== message) return

    const current = {time: performance.now(), x: event.clientX, y: event.clientY}
    if (!isTapGesture(start, current)) {
      touchTaps.delete(message)
      return
    }

    const previous = touchTaps.get(message)
    if (shouldTriggerQuickHeart(previous, current)) {
      touchTaps.delete(message)
      applyQuickHeart(message)
    } else {
      touchTaps.set(message, current)
    }
  }, {passive: true})

  list.addEventListener("pointercancel", (event) => {
    const start = pointerStarts.get(event.pointerId)
    pointerStarts.delete(event.pointerId)
    if (start?.message) touchTaps.delete(start.message)
  }, {passive: true})

  const observer = new MutationObserver(refreshMessageDecorations)
  observer.observe(list, {childList: true, subtree: true})
  refreshMessageDecorations()
}

function setupInfoPanels() {
  const pinned = document.querySelector("#pinned-messages-panel")
  pinned?.classList.add("ig-chat-panel")

  const chooser = document.querySelector("#atmosphere-chooser")
  chooser?.classList.add("ig-chat-panel")

  const prompt = document.querySelector("#prompt-helper")
  prompt?.classList.add("ig-chat-panel")
}

export function bootInstagramChat() {
  if (typeof document === "undefined") return
  if (document.documentElement.dataset.instagramChatBooted === "true") return
  document.documentElement.dataset.instagramChatBooted = "true"

  ensureStylesheet()
  ensureInteractionHardeningStyles()
  setupVisualViewport()
  setupScreenState()
  setupHeader()
  setupTemporaryCue()
  setupComposer()
  setupMessageInteractions()
  setupInfoPanels()
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bootInstagramChat, {once: true})
  else bootInstagramChat()
}