const PREVIEW_PARAM = "preview"
const PREVIEW_VALUE = "conversation"

function previewRequested() {
  try {
    return new URLSearchParams(window.location.search).get(PREVIEW_PARAM) === PREVIEW_VALUE
  } catch (_) {
    return false
  }
}

function previewMessage(text, {mine = false, status = null, reaction = null, grouping = "solo"} = {}) {
  const item = document.createElement("li")
  item.className = `message${mine ? " mine" : ""} ig-group-${grouping}${mine && status ? " ig-latest-own" : ""}`
  item.dataset.releasePreview = "true"
  item.tabIndex = 0

  const body = document.createElement("p")
  body.className = "message-text"
  body.textContent = text
  item.append(body)

  if (reaction) {
    const reactions = document.createElement("div")
    reactions.className = "message-reactions"
    const chip = document.createElement("span")
    chip.textContent = reaction
    reactions.append(chip)
    item.append(reactions)
  }

  if (status) {
    const small = document.createElement("small")
    small.className = "message-status"
    small.textContent = status
    item.append(small)
  }

  return item
}

function lockPreviewToConversation() {
  const conversation = document.querySelector('[data-screen="conversation"]')
  if (!conversation) return

  let applying = false
  const apply = () => {
    if (applying) return
    applying = true
    document.querySelectorAll("[data-screen]").forEach((screen) => {
      screen.classList.toggle("active", screen === conversation)
    })
    document.querySelector("#bottom-nav")?.setAttribute("hidden", "")
    const expressive = document.querySelector("#expressive-composer")
    if (expressive) expressive.hidden = false
    applying = false
  }

  apply()
  new MutationObserver(apply).observe(document.querySelector("main") || document.body, {
    subtree: true,
    attributes: true,
    attributeFilter: ["class"]
  })
}

function installPreviewCopy() {
  const door = document.querySelector("#conversation-door")
  const title = document.querySelector(".conversation-identity h1")
  const presence = document.querySelector("#presence")
  const cue = document.querySelector(".temporary-conversation-cue")

  if (door) door.textContent = "Just Talk"
  if (title) title.textContent = "Stranger"
  if (presence) presence.textContent = "Visual preview · no messages are sent"
  if (cue) {
    const strong = cue.querySelector("strong")
    if (strong) strong.textContent = "Temporary chat preview"
  }
}

function installPreviewMessages() {
  const messages = document.querySelector("#messages")
  if (!messages) return
  messages.replaceChildren(
    previewMessage("Hey 👋", {grouping: "start"}),
    previewMessage("This is the new StrangerTalks Conversation surface.", {grouping: "end"}),
    previewMessage("Looks much cleaner now. I like the focus on the chat itself.", {mine: true, grouping: "start"}),
    previewMessage("And all the extra tools stay out of the way until you need them.", {mine: true, grouping: "end", reaction: "❤️", status: "Delivered"})
  )

  const viewport = document.querySelector("#message-viewport")
  if (viewport) viewport.scrollTop = viewport.scrollHeight
}

function openToolsTray() {
  const form = document.querySelector("#message-form")
  const plus = form?.querySelector(".ig-compose-plus")
  if (!form || !plus) return

  if (!form.classList.contains("ig-tray-open")) plus.click()
  plus.setAttribute("aria-expanded", "true")
}

function preventRealPreviewActions() {
  const blockedSelectors = new Set([
    "#message-form .primary",
    "#voice-start",
    "#view-once-picker-btn",
    "#view-once-video-picker-btn",
    "#normal-media-picker-btn",
    "#btn-voice-call",
    "#btn-video-call",
    "#end-conversation",
    "#report-open",
    "#block"
  ])

  document.addEventListener("click", (event) => {
    const target = event.target.closest("button")
    if (!target) return
    const blocked = [...blockedSelectors].some((selector) => target.matches(selector))
    if (!blocked) return
    event.preventDefault()
    event.stopImmediatePropagation()
    const status = document.querySelector("#status")
    if (status) status.textContent = "Visual preview only. Open the normal site to use this action in a real Conversation."
  }, true)

  document.querySelector("#message-form")?.addEventListener("submit", (event) => {
    event.preventDefault()
    event.stopImmediatePropagation()
  }, true)
}

function addPreviewBadge() {
  if (document.querySelector("#release-preview-badge")) return
  const badge = document.createElement("div")
  badge.id = "release-preview-badge"
  badge.textContent = "LIVE UI PREVIEW"
  badge.setAttribute("role", "status")
  badge.style.cssText = "position:fixed;z-index:2000;top:max(8px,env(safe-area-inset-top));left:50%;transform:translateX(-50%);padding:5px 10px;border:1px solid rgba(255,255,255,.18);border-radius:999px;background:rgba(20,20,24,.88);color:#fff;font:700 10px/1.2 system-ui;letter-spacing:.08em;backdrop-filter:blur(14px);pointer-events:none"
  document.body.append(badge)
}

function bootConversationPreview() {
  if (!previewRequested() || document.documentElement.dataset.releasePreviewBooted === "true") return
  document.documentElement.dataset.releasePreviewBooted = "true"

  setTimeout(() => {
    lockPreviewToConversation()
    installPreviewCopy()
    installPreviewMessages()
    openToolsTray()
    preventRealPreviewActions()
    addPreviewBadge()
  }, 0)
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bootConversationPreview, {once: true})
  else bootConversationPreview()
}
