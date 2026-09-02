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

export function genericTimelineKey(sequence) {
  const value = Number(sequence)
  return Number.isInteger(value) && value > 0 ? [value, 0, 0] : null
}

export function normalMediaTimelineKey(item) {
  const anchor = Number(item?.anchor_sequence)
  const ordinal = Number(item?.anchor_ordinal)
  if (!Number.isInteger(anchor) || anchor < 0 || !Number.isInteger(ordinal) || ordinal < 1) return null
  return [anchor, 1, ordinal]
}

export function compareTimelineKeys(a, b) {
  for (let i = 0; i < 3; i += 1) {
    const delta = Number(a?.[i] ?? Number.MAX_SAFE_INTEGER) - Number(b?.[i] ?? Number.MAX_SAFE_INTEGER)
    if (delta !== 0) return delta
  }
  return 0
}

export function dedupeNormalMedia(items) {
  const byId = new Map()
  for (const item of items || []) {
    if (!item?.client_message_id) continue
    const existing = byId.get(item.client_message_id)
    const incomingKey = normalMediaTimelineKey(item)
    const existingKey = normalMediaTimelineKey(existing)
    if (!existing || (incomingKey && (!existingKey || compareTimelineKeys(incomingKey, existingKey) >= 0))) {
      byId.set(item.client_message_id, item)
    }
  }
  return [...byId.values()].sort((a, b) => compareTimelineKeys(normalMediaTimelineKey(a), normalMediaTimelineKey(b)))
}

export function normalMediaLabel(kind) {
  return kind === "video" ? "Video" : "Photo"
}
