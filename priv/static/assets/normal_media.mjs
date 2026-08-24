export const NORMAL_MEDIA_TYPES = Object.freeze({
  "image/jpeg": {kind: "photo", maxBytes: 1_048_576},
  "image/png": {kind: "photo", maxBytes: 1_048_576},
  "image/webp": {kind: "photo", maxBytes: 1_048_576},
  "video/mp4": {kind: "video", maxBytes: 5_242_880}
})

export function normalizeMediaType(type) {
  return String(type || "").split(";", 1)[0].trim().toLowerCase()
}

export function normalMediaKind(type) {
  return NORMAL_MEDIA_TYPES[normalizeMediaType(type)]?.kind || null
}

export function validNormalMediaFile(file) {
  if (!file || !Number.isFinite(file.size) || file.size <= 0) return false
  const policy = NORMAL_MEDIA_TYPES[normalizeMediaType(file.type)]
  return Boolean(policy && file.size <= policy.maxBytes)
}

export function normalMediaDraftMatchesRuntime(draft, conversationId) {
  return Boolean(
    draft?.originConversationId &&
    draft.originConversationId === conversationId
  )
}

export function dedupeNormalMedia(items) {
  const byId = new Map()
  for (const item of items || []) {
    if (!item?.client_message_id) continue
    const existing = byId.get(item.client_message_id)
    if (!existing || Number(item.sequence || 0) >= Number(existing.sequence || 0)) {
      byId.set(item.client_message_id, item)
    }
  }
  return [...byId.values()].sort((a, b) => Number(a.sequence || 0) - Number(b.sequence || 0))
}

export function normalMediaLabel(kind) {
  return kind === "video" ? "Video" : "Photo"
}
