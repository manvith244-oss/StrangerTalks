import assert from "node:assert/strict"
import test from "node:test"
import {
  activeConversations,
  temporaryConversation,
  localMessage
} from "../../priv/static/assets/local_data.mjs"

test("fresh browser with empty records returns no active conversations", () => {
  const records = []
  assert.equal(activeConversations(records).length, 0)
})

test("valid active temporary conversation is recognized for restoration", () => {
  const activeConv = temporaryConversation({
    conversation_id: "conv-123",
    door_type: "SOMETHING_REAL",
    display_door: "Deep Talk",
    started_at: "2026-08-07T00:00:00Z"
  })
  activeConv.value.connection_state = "connected"
  const records = [activeConv]
  assert.equal(activeConversations(records).length, 1)
  assert.equal(activeConversations(records)[0].value.conversation_id, "conv-123")
})

test("ended or inactive conversation connection state does not qualify as active", () => {
  const endedConv = temporaryConversation({
    conversation_id: "conv-456",
    door_type: "JUST_TALK",
    display_door: "Vent",
    started_at: "2026-08-07T00:00:00Z"
  })
  endedConv.value.connection_state = "ended"
  const records = [endedConv]
  assert.equal(activeConversations(records).length, 0)
})

test("kept or summary conversations are excluded from active temporary restoration", () => {
  const keptConv = {
    id: "conversation:conv-789",
    type: "local_conversation",
    value: {
      conversation_id: "conv-789",
      status: "kept",
      connection_state: "ended"
    },
    updated_at: "2026-08-07T00:00:00Z"
  }
  assert.equal(activeConversations([keptConv]).length, 0)
})

test("standalone messages without active conversation do not trigger restoration", () => {
  const msg = localMessage({
    conversation_id: "conv-999",
    message_id: "msg-1",
    content: "hello",
    mine: true,
    delivery_status: "delivered",
    sent_at: "2026-08-07T00:00:00Z"
  })
  assert.equal(activeConversations([msg]).length, 0)
})
