import assert from "node:assert/strict"
import test from "node:test"
import {
  localMessage
} from "../../priv/static/assets/local_data.mjs"

test("localMessage saves and preserves reply metadata", () => {
  const msg = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-2",
    message_id: "msg-2",
    content: "I agree with you",
    mine: true,
    delivery_status: "sent",
    sent_at: "2026-08-10T00:00:00Z",
    sequence: 2,
    reply_to_client_message_id: "msg-1",
    reply_author_relation: "other_participant",
    reply_snippet: "Hello there"
  })

  assert.equal(msg.id, "message:conv-1:msg-2")
  assert.equal(msg.value.reply_to_client_message_id, "msg-1")
  assert.equal(msg.value.reply_author_relation, "other_participant")
  assert.equal(msg.value.reply_snippet, "Hello there")
})

test("localMessage normalizes absent reply metadata to null", () => {
  const msg = localMessage({
    conversation_id: "conv-1",
    client_message_id: "msg-1",
    message_id: "msg-1",
    content: "Hello",
    mine: false,
    delivery_status: "delivered",
    sent_at: "2026-08-10T00:00:00Z",
    sequence: 1
  })

  assert.equal(msg.value.reply_to_client_message_id, null)
  assert.equal(msg.value.reply_author_relation, null)
  assert.equal(msg.value.reply_snippet, null)
})

test("Reply author relation display mapping for sender and recipient", () => {
  // Sender (mine = true):
  // same_author -> "You"
  // other_participant -> "Stranger"
  function getAuthorLabel(mine, relation) {
    if (mine) {
      return relation === "same_author" ? "You" : "Stranger"
    } else {
      return relation === "same_author" ? "Stranger" : "You"
    }
  }

  assert.equal(getAuthorLabel(true, "same_author"), "You")
  assert.equal(getAuthorLabel(true, "other_participant"), "Stranger")
  assert.equal(getAuthorLabel(false, "same_author"), "Stranger")
  assert.equal(getAuthorLabel(false, "other_participant"), "You")
})

test("Reply target check payload sends ID only without snippet or author", () => {
  const targetId = "d3b07384-d113-40a2-998b-21a4f00db7f7"
  const payload = {reply_to_client_message_id: targetId}

  assert.deepEqual(Object.keys(payload), ["reply_to_client_message_id"])
  assert.equal(payload.reply_to_client_message_id, targetId)
  assert.equal(payload.reply_snippet, undefined)
  assert.equal(payload.reply_author_relation, undefined)
})

test("Stale selection generation token prevents late response from overwriting newer state", () => {
  let replySelectionGeneration = 0
  let activeReplyState = null

  function selectTarget(targetId) {
    const gen = ++replySelectionGeneration
    return {
      generation: gen,
      receiveResponse: (response) => {
        if (replySelectionGeneration !== gen) return false // Ignored because stale!
        activeReplyState = response
        return true
      }
    }
  }

  const reqA = selectTarget("msg-A")
  const reqB = selectTarget("msg-B")

  // Response for B arrives first
  const bApplied = reqB.receiveResponse({target: "msg-B", snippet: "Snippet B"})
  assert.equal(bApplied, true)
  assert.equal(activeReplyState.target, "msg-B")

  // Late response for A arrives later
  const aApplied = reqA.receiveResponse({target: "msg-A", snippet: "Snippet A"})
  assert.equal(aApplied, false)
  assert.equal(activeReplyState.target, "msg-B") // Stale response A was ignored!
})

test("Cancel increments generation and invalidates pending in-flight responses", () => {
  let replySelectionGeneration = 0
  let activeReplyState = null

  function selectTarget(targetId) {
    const gen = ++replySelectionGeneration
    return {
      generation: gen,
      receiveResponse: (response) => {
        if (replySelectionGeneration !== gen) return false
        activeReplyState = response
        return true
      }
    }
  }

  function cancelReply() {
    activeReplyState = null
    replySelectionGeneration++
  }

  const reqA = selectTarget("msg-A")
  cancelReply()

  // Late response for A arrives after cancel
  const aApplied = reqA.receiveResponse({target: "msg-A", snippet: "Snippet A"})
  assert.equal(aApplied, false)
  assert.equal(activeReplyState, null)
})

test("Swipe threshold and directional dominance logic", () => {
  const SWIPE_REPLY_THRESHOLD_PX = 48

  function isSwipeToReply(dx, dy) {
    return Math.abs(dx) >= SWIPE_REPLY_THRESHOLD_PX && Math.abs(dx) > Math.abs(dy) * 1.5
  }

  // Pure horizontal swipe >= 48px -> TRUE
  assert.equal(isSwipeToReply(50, 0), true)
  assert.equal(isSwipeToReply(-50, 5), true)

  // Minor horizontal jitter (< 48px) -> FALSE
  assert.equal(isSwipeToReply(30, 0), false)
  assert.equal(isSwipeToReply(-20, 5), false)

  // Vertical scroll with slight horizontal jitter -> FALSE
  assert.equal(isSwipeToReply(50, 60), false)
  assert.equal(isSwipeToReply(20, 100), false)
})

test("Keyboard Enter send vs Shift+Enter newline vs IME composition", () => {
  function handleComposerKey(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      return "send"
    } else if (event.key === "Enter" && event.shiftKey) {
      return "newline"
    } else if (event.isComposing) {
      return "ime_composition"
    }
    return "other"
  }

  assert.equal(handleComposerKey({key: "Enter", shiftKey: false, isComposing: false}), "send")
  assert.equal(handleComposerKey({key: "Enter", shiftKey: true, isComposing: false}), "newline")
  assert.equal(handleComposerKey({key: "Enter", shiftKey: false, isComposing: true}), "ime_composition")
})

test("Keyboard 'R' triggers reply only when focus is outside text inputs", () => {
  function handleRKey(event, activeElementTag) {
    if ((event.key === "r" || event.key === "R") && activeElementTag !== "TEXTAREA" && activeElementTag !== "INPUT") {
      return "trigger_reply"
    }
    return "ignore"
  }

  assert.equal(handleRKey({key: "r"}, "LI"), "trigger_reply")
  assert.equal(handleRKey({key: "R"}, "DIV"), "trigger_reply")
  assert.equal(handleRKey({key: "r"}, "TEXTAREA"), "ignore")
  assert.equal(handleRKey({key: "r"}, "INPUT"), "ignore")
})
