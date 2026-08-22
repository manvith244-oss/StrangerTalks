export const MAX_PHOTO_BYTES = 1_048_576
export const MAX_PHOTO_DIMENSION = 2048
export const APPROVED_PHOTO_TYPES = new Set(["image/jpeg", "image/png", "image/webp"])

export function isApprovedPhotoType(type) {
  const norm = String(type || "").split(";", 1)[0].trim().toLowerCase()
  return APPROVED_PHOTO_TYPES.has(norm)
}

export function validPhotoBlob(blob) {
  return Boolean(
    blob &&
    blob.size > 0 &&
    blob.size <= MAX_PHOTO_BYTES &&
    isApprovedPhotoType(blob.type)
  )
}

export function viewOnceDraftMatchesRuntime(draft, conversationId, epochId) {
  return Boolean(
    draft?.originConversationId &&
    draft.originEpochId &&
    draft.originConversationId === conversationId &&
    draft.originEpochId === epochId
  )
}

export function dedupeViewOnceMessages(records) {
  return [...new Map(records.map((r) => [r.value?.client_message_id || r.value?.message_id, r])).values()]
}
