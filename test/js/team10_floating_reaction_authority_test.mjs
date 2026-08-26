import assert from "node:assert/strict"
import test from "node:test"
import {CALL_STATUS, LiveCallCoordinator} from "../../priv/static/assets/live_call.mjs"

test("delayed floating reaction from an old call attempt has zero effect on the current Conversation", () => {
  const presented = []
  const coordinator = new LiveCallCoordinator({
    conversationId: "conversation-b",
    participantId: "participant-self",
    onReaction: (payload) => presented.push(payload)
  })

  coordinator.callAttemptId = "call-b"
  coordinator.status = CALL_STATUS.ACTIVE

  coordinator.handleReaction({
    call_attempt_id: "call-a",
    reaction_event_id: "reaction-a-late",
    reaction: "heart",
    sender_id: "participant-peer"
  })

  assert.equal(presented.length, 0, "old call-attempt reaction must not render in the current Conversation")

  coordinator.handleReaction({
    call_attempt_id: "call-b",
    reaction_event_id: "reaction-b-current",
    reaction: "wave",
    sender_id: "participant-peer"
  })

  assert.deepEqual(presented, [{
    reaction: "wave",
    emoji: "👋",
    label: "Wave (Hello)",
    sender_id: "participant-peer"
  }])

  coordinator.handleReaction({
    call_attempt_id: "call-b",
    reaction_event_id: "reaction-b-current",
    reaction: "wave",
    sender_id: "participant-peer"
  })
  assert.equal(presented.length, 1, "duplicate reaction event must be presented once")

  coordinator.status = CALL_STATUS.TERMINAL
  coordinator.handleReaction({
    call_attempt_id: "call-b",
    reaction_event_id: "reaction-after-terminal",
    reaction: "fire",
    sender_id: "participant-peer"
  })
  assert.equal(presented.length, 1, "terminal call must reject delayed floating reactions")
})

test("invalid reaction identity never reaches presentation", () => {
  const presented = []
  const coordinator = new LiveCallCoordinator({onReaction: (payload) => presented.push(payload)})
  coordinator.callAttemptId = "call-current"
  coordinator.status = CALL_STATUS.ACTIVE

  for (const reaction of [null, "", "<script>alert(1)</script>", "unknown", 42, {reaction: "heart"}]) {
    coordinator.handleReaction({
      call_attempt_id: "call-current",
      reaction_event_id: `invalid-${String(reaction)}`,
      reaction,
      sender_id: "participant-peer"
    })
  }

  assert.equal(presented.length, 0)
})
