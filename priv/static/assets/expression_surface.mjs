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

if (!Socket.prototype.__team10GifAuthorityPatched) {
  Socket.prototype.__team10GifAuthorityPatched = true
  const originalChannel = Socket.prototype.channel

  Socket.prototype.channel = function(topic, params) {
    const channel = originalChannel.call(this, topic, params)
    if (typeof topic === "string" && topic.startsWith("conversation:")) {
      currentConversationId = topic.slice("conversation:".length)
    }
    return channel
  }
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
