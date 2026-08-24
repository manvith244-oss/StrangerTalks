import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

const liveSource = readFileSync(new URL("../../priv/static/assets/live_call.mjs", import.meta.url), "utf8")
const appSource = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const htmlSource = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")

test("T4-SCREEN-001: V1 contains no display-capture API or Share Screen control", () => {
  assert.doesNotMatch(liveSource, /getDisplayMedia/)
  assert.doesNotMatch(appSource, /getDisplayMedia/)
  assert.doesNotMatch(htmlSource, /Share Screen|btn-call-screen-share/i)
})

test("T4-SCREEN-002: stale or forged screen-share media projection cannot create client capture authority", () => {
  const coordinator = new LiveCallCoordinator({participantId: "p1", conversationId: "c1"})
  coordinator.callAttemptId = "a1"
  coordinator.status = CALL_STATUS.ACTIVE

  coordinator.handleMediaUpdated({
    call_attempt_id: "a1",
    media_generation: 2,
    active_media: {screen_share: {requester_id: "p1", media_request_id: "forged"}}
  })

  const state = coordinator.getState()
  assert.equal(state.screenSharing ?? false, false, "OUT-OF-V1 projection must not turn screen sharing on")
  assert.equal(coordinator.localScreenStream ?? null, null, "no display stream may exist")
})
