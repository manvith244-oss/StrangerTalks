import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import {
  APPROVED_BASE_MEDIA_TYPES, MAX_VOICE_BYTES, VOICE_WARNING_VERSION,
  chronologicalTimeline, dedupeVoiceNotes, recordingShouldStop, selectVoiceMediaType,
  formatVoiceTime, nextPlaybackRate, stopMediaTracks, validVoiceBlob, voiceDraftMatchesRuntime,
  warningAcknowledged
} from "../../priv/static/assets/voice_notes.mjs"

test("supported MIME selection follows the locked priority", () => {
  const supported = new Set(["audio/webm", "audio/ogg;codecs=opus"])
  assert.equal(selectVoiceMediaType({isTypeSupported: (type) => supported.has(type)}), "audio/webm")
  assert.equal(selectVoiceMediaType({isTypeSupported: () => false}), null)
  assert.deepEqual([...APPROVED_BASE_MEDIA_TYPES], ["audio/webm", "audio/ogg", "audio/mp4"])
})

test("warning acknowledgement is versioned and absent settings are not consent", () => {
  assert.equal(warningAcknowledged(null), false)
  assert.equal(warningAcknowledged({type: "settings", value: {voice_warning_version: 0}}), false)
  assert.equal(warningAcknowledged({type: "settings", value: {voice_warning_version: VOICE_WARNING_VERSION}}), true)
})

test("the 60 second boundary stops recording without implying send", () => {
  assert.equal(recordingShouldStop(59_999), false)
  assert.equal(recordingShouldStop(60_000), true)
})

test("cancel and stop cleanup closes every microphone track", () => {
  const stopped = []
  stopMediaTracks({getTracks: () => [{stop: () => stopped.push(1)}, {stop: () => stopped.push(2)}]})
  assert.deepEqual(stopped, [1, 2])
})

test("oversized or unapproved voice blobs are rejected before upload", () => {
  assert.equal(validVoiceBlob(new Blob([new Uint8Array(MAX_VOICE_BYTES)], {type: "audio/webm"})), true)
  assert.equal(validVoiceBlob(new Blob([new Uint8Array(MAX_VOICE_BYTES + 1)], {type: "audio/webm"})), false)
  assert.equal(validVoiceBlob(new Blob(["x"], {type: "audio/wav"})), false)
})

test("received notes deduplicate by voice_note_id and timeline remains chronological", () => {
  const voice = (id, sequence) => ({id: `voice:${id}`, value: {voice_note_id: id, sequence, sent_at: `2026-01-01T00:00:0${sequence}Z`}})
  assert.deepEqual(dedupeVoiceNotes([voice("a", 2), voice("a", 2), voice("b", 1)]).map(({value}) => value.voice_note_id), ["a", "b"])
  assert.deepEqual(chronologicalTimeline([voice("a", 2), voice("b", 1)]).map(({value}) => value.voice_note_id), ["b", "a"])
})

test("browser flow keeps permission explicit, IDs stable for retry, and never autoplays", () => {
  const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(source, /warningAcknowledged\(warning\).*startVoiceRecording\(\)/s)
  assert.match(source, /voiceNoteId = crypto\.randomUUID\(\)/)
  assert.match(source, /const id = app\.voice\.voiceNoteId/)
  assert.match(source, /setTimeout\(\(\) => .*MAX_VOICE_DURATION_MS/s)
  assert.match(source, /audio\.autoplay = false/)
  assert.match(source, /URL\.revokeObjectURL/)
  assert.match(source, /Text messaging still works/)
})

test("Feature 1E draft runtime binding permits only its originating conversation epoch", () => {
  const draft = {originConversationId: "conversation-a", originEpochId: "epoch-a"}
  assert.equal(voiceDraftMatchesRuntime(draft, "conversation-a", "epoch-a"), true)
  assert.equal(voiceDraftMatchesRuntime(draft, "conversation-b", "epoch-a"), false)
  assert.equal(voiceDraftMatchesRuntime(draft, "conversation-a", "epoch-b"), false)
  assert.equal(voiceDraftMatchesRuntime({}, "conversation-a", "epoch-a"), false)
})

test("Feature 1E playback speeds cycle and time is presented accessibly", () => {
  assert.equal(nextPlaybackRate(1), 1.5)
  assert.equal(nextPlaybackRate(1.5), 2)
  assert.equal(nextPlaybackRate(2), 1)
  assert.equal(formatVoiceTime(0), "0:00")
  assert.equal(formatVoiceTime(65.8), "1:05")
})

test("Feature 1E source keeps draft local until existing upload and cleans every terminal path", () => {
  const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(source, /new Blob\(app\.voice\.chunks/)
  assert.match(source, /voiceDraftMatchesRuntime\(app\.voice, app\.conversationId, app\.currentEpochId\)/)
  assert.match(source, /fetch\(`\/api\/conversations\/\$\{app\.conversationId\}\/voice-notes\/\$\{id\}`/)
  assert.match(source, /cancelAnimationFrame\(app\.voice\.activityFrame\)/)
  assert.match(source, /stopMediaTracks\(app\.voice\.stream\)/)
  assert.match(source, /URL\.revokeObjectURL\(app\.voice\.objectUrl\)/)
  assert.match(source, /Voice draft could not be finalized\. Nothing was sent\./)
})

test("Feature 1E player exposes seek, progress, speed, failure fallback, and decorative waveform", () => {
  const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(source, /audio\.currentTime =/)
  assert.match(source, /audio\.playbackRate = nextPlaybackRate/)
  assert.match(source, /Voice note playback is unavailable\. The message is still here\./)
  assert.match(source, /waveform\.setAttribute\("aria-hidden", "true"\)/)
})
