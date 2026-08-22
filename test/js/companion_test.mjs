import test from "node:test"
import assert from "node:assert/strict"

import {
  applyCompanionSuggestion,
  buildCompanionPayload,
  singleActiveConversation,
  undoCompanionSuggestion
} from "../../priv/static/assets/companion.mjs"

test("buildCompanionPayload keeps the participant request bounded and explicit", () => {
  assert.deepEqual(
    buildCompanionPayload({
      mode: "respond",
      request: "  Help me reply without sounding rude.  ",
      draft: "My draft",
      tone: "warm"
    }),
    {
      mode: "respond",
      request: "Help me reply without sounding rude.",
      draft: "My draft",
      tone: "warm"
    }
  )

  assert.throws(() => buildCompanionPayload({mode: "hidden_psychology", tone: "warm"}), /invalid_mode/)
  assert.throws(() => buildCompanionPayload({mode: "respond", tone: "manipulative"}), /invalid_tone/)
  assert.throws(
    () => buildCompanionPayload({mode: "respond", tone: "natural", request: "x".repeat(801)}),
    /request_too_large/
  )
})

test("using a suggestion is draft-only and never overwrites newer participant typing", () => {
  assert.deepEqual(
    applyCompanionSuggestion({requestDraft: "", currentDraft: "", suggestion: "What got you into that?"}),
    {status: "applied", draft: "What got you into that?"}
  )

  assert.deepEqual(
    applyCompanionSuggestion({
      requestDraft: "I was thinking",
      currentDraft: "I was thinking something newer",
      suggestion: "I was thinking about that too."
    }),
    {status: "blocked_stale_draft", draft: "I was thinking something newer"}
  )
})

test("Companion-applied draft can be explicitly undone without overwriting later edits", () => {
  assert.deepEqual(
    undoCompanionSuggestion({
      originalDraft: "My original thought",
      appliedDraft: "A warmer version",
      currentDraft: "A warmer version"
    }),
    {status: "restored", draft: "My original thought"}
  )

  assert.deepEqual(
    undoCompanionSuggestion({
      originalDraft: "My original thought",
      appliedDraft: "A warmer version",
      currentDraft: "A warmer version with my edit"
    }),
    {status: "blocked_changed_draft", draft: "A warmer version with my edit"}
  )
})

test("ambiguous local Conversation authority fails closed instead of guessing newest", () => {
  const one = {
    id: "conversation:one",
    type: "local_conversation",
    value: {conversation_id: "one", status: "temporary", connection_state: "connected"},
    updated_at: "2026-08-23T00:00:00Z"
  }
  const two = {
    id: "conversation:two",
    type: "local_conversation",
    value: {conversation_id: "two", status: "temporary", connection_state: "recovery"},
    updated_at: "2026-08-23T00:01:00Z"
  }

  assert.equal(singleActiveConversation([one])?.value?.conversation_id, "one")
  assert.equal(singleActiveConversation([one, two]), null)
  assert.equal(singleActiveConversation([]), null)
})

test("invalid suggestions cannot enter the draft", () => {
  assert.deepEqual(
    applyCompanionSuggestion({requestDraft: "", currentDraft: "", suggestion: "   "}),
    {status: "invalid", draft: ""}
  )
})
