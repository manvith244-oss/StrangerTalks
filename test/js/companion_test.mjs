import test from "node:test"
import assert from "node:assert/strict"

import {applyCompanionSuggestion, buildCompanionPayload} from "../../priv/static/assets/companion.mjs"

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

test("invalid suggestions cannot enter the draft", () => {
  assert.deepEqual(
    applyCompanionSuggestion({requestDraft: "", currentDraft: "", suggestion: "   "}),
    {status: "invalid", draft: ""}
  )
})
