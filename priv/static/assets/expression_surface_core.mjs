export function insertEmojiIntoDraft(value, selectionStart, selectionEnd, emoji) {
  const source = String(value ?? "")
  const token = String(emoji ?? "")
  const start = Math.max(0, Math.min(Number.isInteger(selectionStart) ? selectionStart : source.length, source.length))
  const endCandidate = Number.isInteger(selectionEnd) ? selectionEnd : start
  const end = Math.max(start, Math.min(endCandidate, source.length))
  const nextValue = source.slice(0, start) + token + source.slice(end)
  return {value: nextValue, caret: start + token.length}
}

export function createGifSearchGuard() {
  let generation = 0
  return {
    begin(conversationId, query) {
      generation += 1
      return Object.freeze({generation, conversationId, query})
    },
    invalidate() {
      generation += 1
      return generation
    },
    isCurrent(token, conversationId) {
      return Boolean(token) && token.generation === generation && token.conversationId === conversationId
    }
  }
}

export function gifSearchPath(query, conversationId = null) {
  const params = new URLSearchParams({q: String(query ?? "").trim()})
  if (typeof conversationId === "string" && conversationId) params.set("conversation_id", conversationId)
  return `/api/gifs/search?${params.toString()}`
}

export function validGifResult(result) {
  if (!result || typeof result !== "object") return false
  if (typeof result.id !== "string" || result.id.length < 1 || result.id.length > 200) return false
  if (typeof result.provider !== "string" || result.provider.length < 1 || result.provider.length > 40) return false
  if (typeof result.reference !== "string" || result.reference.length < 1 || result.reference.length > 4096) return false
  if (typeof result.media_url !== "string" || !result.media_url.startsWith("https://")) return false
  if (!Number.isInteger(result.width) || result.width < 1 || result.width > 4096) return false
  if (!Number.isInteger(result.height) || result.height < 1 || result.height > 4096) return false
  return typeof result.label === "string" && result.label.length > 0 && result.label.length <= 160
}

export function sanitizeGifResults(results) {
  return Array.isArray(results) ? results.filter(validGifResult) : []
}

export async function sendWithSameIdentityRetry(pushOnce, payload) {
  try {
    return await pushOnce(payload)
  } catch (error) {
    if (error?.reason !== "timeout") throw error
    return pushOnce(payload)
  }
}
