import assert from "node:assert/strict"
import test from "node:test"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

test("late microphone permission cannot start a voice recorder after terminal/cancel authority", () => {
  assert.match(source, /voice:\s*\{[^}]*captureRequestId:\s*0/s)
  assert.match(source, /const captureRequestId = \+\+app\.voice\.captureRequestId/)
  assert.match(source, /const captureConversationId = app\.conversationId/)
  assert.match(source, /const captureEpochId = app\.currentEpochId/)
  assert.match(
    source,
    /app\.voice\.captureRequestId !== captureRequestId[\s\S]*app\.conversationId !== captureConversationId[\s\S]*app\.currentEpochId !== captureEpochId[\s\S]*stopMediaTracks\(stream\)/
  )
  assert.match(source, /function cancelRecording\(\)\s*\{\s*app\.voice\.captureRequestId\+\+/)
})
