import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import {voiceCaptureStillAuthorized} from "../../priv/static/assets/voice_notes.mjs"

test("voice capture authority rejects cancel, terminal, stale request, conversation and epoch changes", () => {
  const base = {requestId: 2, currentRequestId: 2, conversationId: "c", currentConversationId: "c", epochId: "e", currentEpochId: "e", conversationAvailable: true}
  assert.equal(voiceCaptureStillAuthorized(base), true)
  assert.equal(voiceCaptureStillAuthorized({...base, currentRequestId: 3}), false)
  assert.equal(voiceCaptureStillAuthorized({...base, conversationAvailable: false}), false)
  assert.equal(voiceCaptureStillAuthorized({...base, currentConversationId: "other"}), false)
  assert.equal(voiceCaptureStillAuthorized({...base, currentEpochId: "new"}), false)
})

test("late permission stream is stopped before MediaRecorder construction", () => {
  const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  const guard = source.indexOf("voiceCaptureStillAuthorized({")
  const stop = source.indexOf("stopMediaTracks(stream)", guard)
  const recorder = source.indexOf("new MediaRecorder(stream", guard)
  assert.ok(guard >= 0 && stop > guard && recorder > stop)
  assert.match(source, /function cancelRecording\(\)\s*\{[\s\S]*app\.voice\.captureRequestId\+\+/)
})

test("Conversation End and Block invalidate Voice Note capture authority", () => {
  const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(source, /conversation:ended[\s\S]*cancelRecording\(\)/)
  assert.match(source, /#block[\s\S]*cancelRecording\(\)[\s\S]*conversation:block/)
})
