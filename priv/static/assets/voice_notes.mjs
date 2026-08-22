export const VOICE_WARNING_VERSION = 1
export const MAX_VOICE_BYTES = 1_048_576
export const MAX_VOICE_DURATION_MS = 60_000
export const VOICE_MEDIA_TYPES = ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus", "audio/mp4"]
export const APPROVED_BASE_MEDIA_TYPES = new Set(["audio/webm", "audio/ogg", "audio/mp4"])

export function selectVoiceMediaType(MediaRecorderClass) {
  if (!MediaRecorderClass?.isTypeSupported) return null
  return VOICE_MEDIA_TYPES.find((type) => MediaRecorderClass.isTypeSupported(type)) || null
}

export function baseMediaType(type) {
  return String(type || "").split(";", 1)[0].toLowerCase()
}

export function validVoiceBlob(blob) {
  return blob && blob.size > 0 && blob.size <= MAX_VOICE_BYTES && APPROVED_BASE_MEDIA_TYPES.has(baseMediaType(blob.type))
}

export function stopMediaTracks(stream) {
  for (const track of stream?.getTracks?.() || []) track.stop()
}

export function warningAcknowledged(record) {
  return record?.type === "settings" && record.value?.voice_warning_version === VOICE_WARNING_VERSION
}

export function recordingShouldStop(elapsedMs) {
  return elapsedMs >= MAX_VOICE_DURATION_MS
}

export function voiceDraftMatchesRuntime(draft, conversationId, epochId) {
  return Boolean(draft?.originConversationId && draft.originEpochId &&
    draft.originConversationId === conversationId && draft.originEpochId === epochId)
}

export function nextPlaybackRate(currentRate) {
  if (currentRate < 1.5) return 1.5
  if (currentRate < 2) return 2
  return 1
}

export function formatVoiceTime(seconds) {
  const safe = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0
  return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2, "0")}`
}

export function dedupeVoiceNotes(records) {
  return [...new Map(records.map((record) => [record.value.voice_note_id, record])).values()]
}

export function chronologicalTimeline(records) {
  return [...records].sort((a, b) => {
    const aSequence = Number.isFinite(a.value.sequence) ? a.value.sequence : Number.MAX_SAFE_INTEGER
    const bSequence = Number.isFinite(b.value.sequence) ? b.value.sequence : Number.MAX_SAFE_INTEGER
    return aSequence - bSequence || String(a.value.sent_at).localeCompare(String(b.value.sent_at))
  })
}
