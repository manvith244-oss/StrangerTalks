import "./desktop_flow.mjs"
import {Socket} from "/vendor/phoenix.mjs"
import {getRecord} from "./local_data.mjs"

export {
  createGifSearchGuard,
  gifSearchPath,
  insertEmojiIntoDraft,
  sanitizeGifResults,
  sendWithSameIdentityRetry,
  validGifResult
} from "./expression_surface_core.mjs"

const IDENTITY_KEY = "strangertalks.identity.v1"
const GIF_SEARCH_PATH = "/api/gifs/search"

let currentConversationId = null
let conversationGeneration = 0
let stickerPickerAuthority = null

function terminateBrowserExpressionAuthority() {
  conversationGeneration += 1
  currentConversationId = null
  stickerPickerAuthority = null
}

if (!Socket.prototype.__team10GifAuthorityPatched) {
  Socket.prototype.__team10GifAuthorityPatched = true
  const originalChannel = Socket.prototype.channel

  Socket.prototype.channel = function(topic, params) {
    const channel = originalChannel.call(this, topic, params)
    if (typeof topic === "string" && topic.startsWith("conversation:")) {
      conversationGeneration += 1
      currentConversationId = topic.slice("conversation:".length)
      stickerPickerAuthority = null
    }
    return channel
  }
}

// Capture-phase authority guard runs before the base app's sticker click handler.
// A selection belongs to the Conversation generation in which the picker opened;
// an End/Block, sibling terminal update, or A→B transition invalidates it.
document.addEventListener("click", (event) => {
  const target = event.target
  if (!(target instanceof Element)) return

  if (target.closest("#end-confirm, #block")) {
    terminateBrowserExpressionAuthority()
    return
  }

  if (target.closest("#expressive-open")) {
    stickerPickerAuthority = currentConversationId
      ? {conversationId: currentConversationId, generation: conversationGeneration}
      : null
    return
  }

  if (target.closest("#expressive-results button")) {
    const valid = Boolean(
      stickerPickerAuthority &&
      currentConversationId &&
      stickerPickerAuthority.conversationId === currentConversationId &&
      stickerPickerAuthority.generation === conversationGeneration
    )

    if (!valid) {
      event.preventDefault()
      event.stopImmediatePropagation()
      const status = document.querySelector("#expression-send-status")
      if (status) {
        status.textContent = "That sticker selection is no longer available in this Conversation."
        status.hidden = false
      }
    }
  }
}, true)

const expressiveComposer = document.querySelector("#expressive-composer")
if (expressiveComposer) {
  new MutationObserver(() => {
    if (expressiveComposer.hidden) terminateBrowserExpressionAuthority()
  }).observe(expressiveComposer, {attributes: true, attributeFilter: ["hidden"]})
}

if (!globalThis.__team10GifFetchPatched && typeof globalThis.fetch === "function") {
  globalThis.__team10GifFetchPatched = true
  const originalFetch = globalThis.fetch.bind(globalThis)

  globalThis.fetch = async function(input, init = {}) {
    const rawUrl = typeof input === "string" || input instanceof URL ? String(input) : input?.url
    if (!rawUrl) return originalFetch(input, init)

    const url = new URL(rawUrl, globalThis.location?.origin || "http://localhost")
    if (url.pathname !== GIF_SEARCH_PATH || (globalThis.location?.origin && url.origin !== globalThis.location.origin)) {
      return originalFetch(input, init)
    }

    if (currentConversationId) url.searchParams.set("conversation_id", currentConversationId)

    const identity = await getRecord(IDENTITY_KEY).catch(() => null)
    const participantToken = identity?.value?.token
    const headers = new Headers(init.headers || (input instanceof Request ? input.headers : undefined))
    if (typeof participantToken === "string" && participantToken) {
      headers.set("authorization", `Bearer ${participantToken}`)
    }

    return originalFetch(url.toString(), {...init, headers})
  }
}
