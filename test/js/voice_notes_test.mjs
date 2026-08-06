import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import {
  APPROVED_BASE_MEDIA_TYPES, MAX_VOICE_BYTES, VOICE_WARNING_VERSION,
  chronologicalTimeline, dedupeVoiceNotes, recordingShouldStop, selectVoiceMediaType,
  stopMediaTracks, validVoiceBlob, warningAcknowledged
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
