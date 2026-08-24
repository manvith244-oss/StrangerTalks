import assert from "node:assert/strict"
import test from "node:test"
import {chooseConversationRetention, localMessage, preserveTerminalRetentionDecisions, temporaryConversation} from "../../priv/static/assets/local_data.mjs"

const started = "2026-08-24T00:00:00.000Z"
const decided = "2026-08-24T00:01:00.000Z"

function seed() {
  return [
    temporaryConversation({conversation_id: "c1", door_type: "EXPLORE", display_door: "Explore", started_at: started}),
    localMessage({conversation_id: "c1", client_message_id: "m1", type: "text", content: "meaningful", mine: true, delivery_status: "delivered", sent_at: started, sequence: 1})
  ]
}

test("retention choice is one-time once a terminal outcome exists", () => {
  const kept = chooseConversationRetention(seed(), "c1", "kept", {now: decided})
  assert.throws(() => chooseConversationRetention(kept, "c1", "faded", {now: decided}), /retention_already_decided/)
})

test("a stale Keep snapshot cannot resurrect transcript after Fade wins", () => {
  const before = seed()
  const faded = chooseConversationRetention(before, "c1", "faded", {now: decided})
  const staleKeep = chooseConversationRetention(before, "c1", "kept", {now: "2026-08-24T00:02:00.000Z"})
  const converged = preserveTerminalRetentionDecisions(faded, staleKeep)
  const conversation = converged.find(({id}) => id === "conversation:c1")

  assert.equal(conversation.value.status, "faded")
  assert.equal(converged.some(({type}) => type === "local_message"), false)
  assert.equal(converged.some(({id}) => id === "summary:c1"), false)
})

test("a stale Fade snapshot cannot destroy transcript after Keep wins", () => {
  const before = seed()
  const kept = chooseConversationRetention(before, "c1", "kept", {now: decided})
  const staleFade = chooseConversationRetention(before, "c1", "faded", {now: "2026-08-24T00:02:00.000Z"})
  const converged = preserveTerminalRetentionDecisions(kept, staleFade)

  assert.equal(converged.find(({id}) => id === "conversation:c1").value.status, "kept")
  assert.equal(converged.filter(({type}) => type === "local_message").length, 1)
})

test("Summary-only remains transcript-free when a stale tab proposes Keep", () => {
  const before = seed()
  const summaryOnly = chooseConversationRetention(before, "c1", "summary_only", {summaryText: "What mattered", now: decided})
  const staleKeep = chooseConversationRetention(before, "c1", "kept", {now: "2026-08-24T00:02:00.000Z"})
  const converged = preserveTerminalRetentionDecisions(summaryOnly, staleKeep)

  assert.equal(converged.find(({id}) => id === "conversation:c1").value.status, "summary_only")
  assert.equal(converged.find(({id}) => id === "summary:c1").value.text, "What mattered")
  assert.equal(converged.some(({type}) => type === "local_message"), false)
})
