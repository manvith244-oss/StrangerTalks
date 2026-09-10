import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

import {
  HANGOUTS_PHASES,
  REPORT_CATEGORIES,
  createHangoutState,
  hangoutReducer,
  formatReportIntent,
  formatBlockIntent,
  formatMessageIntent,
  formatReactionIntent,
  formatSkipIntent,
  isTreatmentArm
} from "../../priv/static/assets/hangouts.mjs"

test("Hangouts state machine initializes in ENTRY phase with safe defaults", () => {
  const state = createHangoutState()
  assert.equal(state.phase, HANGOUTS_PHASES.ENTRY)
  assert.equal(state.mode, "hangout")
  assert.equal(state.queue_status, "idle")
  assert.equal(state.queue_attempt_id, null)
  assert.equal(state.room_id, null)
  assert.equal(state.room_snapshot, null)
  assert.equal(state.current_content, null)
  assert.deepEqual(state.messages, [])
  assert.deepEqual(state.reactions, {})
  assert.deepEqual(state.skip_status, {votes: 0, required: 0})
  assert.equal(state.connectivity, "connected")
})

test("queue transitions update phase from ENTRY to WAITING and back on cancellation", () => {
  const initial = createHangoutState()

  const queued = hangoutReducer(initial, {
    type: "QUEUE_ENTER",
    queue_attempt_id: "attempt-xyz",
    language_tag: "en-US"
  })
  assert.equal(queued.phase, HANGOUTS_PHASES.WAITING)
  assert.equal(queued.queue_status, "queued")
  assert.equal(queued.queue_attempt_id, "attempt-xyz")
  assert.equal(queued.language_tag, "en-US")

  const cancelled = hangoutReducer(queued, {type: "QUEUE_CANCEL"})
  assert.equal(cancelled.phase, HANGOUTS_PHASES.ENTRY)
  assert.equal(cancelled.queue_status, "idle")
  assert.equal(cancelled.queue_attempt_id, null)
})

test("server snapshot reconciles ROOM phase, temporary identities, and redacts internal IDs", () => {
  const waiting = createHangoutState({
    phase: HANGOUTS_PHASES.WAITING,
    queue_status: "queued"
  })

  const serverSnapshot = {
    room_id: "44444444-4444-4444-4444-444444444444",
    status: "ACTIVE",
    experiment_arm: "GROUP_WITH_CONTENT",
    language_tag: "en",
    message_sequence: 2,
    content_sequence: 1,
    members: [
      {identity: {slot: 0, emoji: "🦉", label: "Quiet Owl"}, self: true, status: "ACTIVE"},
      {identity: {slot: 1, emoji: "🦊", label: "Swift Fox"}, self: false, status: "ACTIVE"},
      {identity: {slot: 2, emoji: "🐻", label: "Gentle Bear"}, self: false, status: "ACTIVE"}
    ],
    current_content: {
      item_id: "first-topic",
      sequence: 1,
      title: "Unexpected Joys",
      text: "What small thing made you smile today?",
      source_attribution: "First-Party StrangerTalks"
    },
    messages: [
      {sequence: 1, client_message_id: "msg-1", sender: {slot: 1, emoji: "🦊", label: "Swift Fox"}, body: "Hey everyone!"},
      {sequence: 2, client_message_id: "msg-2", sender: {slot: 0, emoji: "🦉", label: "Quiet Owl"}, body: "Hello!"}
    ],
    reactions: {"🔥": 2, "❤️": 1},
    skip_status: {votes: 1, required: 2}
  }

  const room = hangoutReducer(waiting, {type: "ROOM_SNAPSHOT", snapshot: serverSnapshot})

  assert.equal(room.phase, HANGOUTS_PHASES.ROOM)
  assert.equal(room.room_id, "44444444-4444-4444-4444-444444444444")
  assert.equal(room.room_snapshot.status, "ACTIVE")
  assert.equal(room.messages.length, 2)
  assert.equal(room.messages[0].sender.label, "Swift Fox")
  assert.equal(room.current_content.title, "Unexpected Joys")
  assert.equal(room.reactions["🔥"], 2)
  assert.equal(room.skip_status.votes, 1)

  // Prove no internal participant/membership IDs in state
  const serialized = JSON.stringify(room)
  assert.doesNotMatch(serialized, /participant_id/)
  assert.doesNotMatch(serialized, /membership_id/)
})

test("treatment arm distinguishes GROUP_WITH_CONTENT from GROUP_NO_CONTENT", () => {
  assert.equal(isTreatmentArm("GROUP_WITH_CONTENT"), true)
  assert.equal(isTreatmentArm("GROUP_NO_CONTENT"), false)
  assert.equal(isTreatmentArm(null), false)

  const controlSnapshot = {
    room_id: "55555555-5555-5555-5555-555555555555",
    status: "ACTIVE",
    experiment_arm: "GROUP_NO_CONTENT",
    language_tag: "en",
    message_sequence: 0,
    content_sequence: 0,
    members: [
      {identity: {slot: 0, emoji: "🦉", label: "Quiet Owl"}, self: true, status: "ACTIVE"},
      {identity: {slot: 1, emoji: "🦊", label: "Swift Fox"}, self: false, status: "ACTIVE"}
    ],
    current_content: null,
    messages: [],
    reactions: {},
    skip_status: {votes: 0, required: 0}
  }

  const state = hangoutReducer(createHangoutState(), {type: "ROOM_SNAPSHOT", snapshot: controlSnapshot})
  assert.equal(state.current_content, null)
  assert.deepEqual(state.reactions, {})
})

test("messages maintain canonical sequence order from server events", () => {
  const initial = createHangoutState({
    phase: HANGOUTS_PHASES.ROOM,
    room_id: "room-seq-1",
    messages: [
      {sequence: 1, client_message_id: "m-1", sender: {slot: 0, emoji: "🦉", label: "Quiet Owl"}, body: "First"}
    ]
  })

  const next = hangoutReducer(initial, {
    type: "MESSAGE_ACCEPTED",
    message: {sequence: 2, client_message_id: "m-2", sender: {slot: 1, emoji: "🦊", label: "Swift Fox"}, body: "Second"}
  })

  assert.equal(next.messages.length, 2)
  assert.equal(next.messages[1].sequence, 2)
  assert.equal(next.messages[1].body, "Second")
})

test("content advancement updates content and resets ephemeral reaction/skip states", () => {
  const room = createHangoutState({
    phase: HANGOUTS_PHASES.ROOM,
    current_content: {sequence: 1, title: "Topic 1"},
    reactions: {"🔥": 3},
    skip_status: {votes: 2, required: 2}
  })

  const advanced = hangoutReducer(room, {
    type: "CONTENT_ADVANCED",
    content: {sequence: 2, title: "Topic 2", text: "New prompt"}
  })

  assert.equal(advanced.current_content.sequence, 2)
  assert.equal(advanced.current_content.title, "Topic 2")
  assert.deepEqual(advanced.reactions, {})
  assert.deepEqual(advanced.skip_status, {votes: 0, required: 0})
})

test("disconnect transitions to RECONNECTING without destroying room state", () => {
  const active = createHangoutState({
    phase: HANGOUTS_PHASES.ROOM,
    room_id: "reconnect-room-1",
    messages: [{sequence: 1, body: "persists"}]
  })

  const disconnected = hangoutReducer(active, {type: "SOCKET_DISCONNECTED"})
  assert.equal(disconnected.phase, HANGOUTS_PHASES.RECONNECTING)
  assert.equal(disconnected.connectivity, "disconnected")
  assert.equal(disconnected.room_id, "reconnect-room-1")
  assert.equal(disconnected.messages.length, 1)

  const reconnected = hangoutReducer(disconnected, {type: "SOCKET_RECONNECTED"})
  assert.equal(reconnected.phase, HANGOUTS_PHASES.ROOM)
  assert.equal(reconnected.connectivity, "connected")
})

test("terminal room transitions to ENDED phase and locks mutation", () => {
  const active = createHangoutState({
    phase: HANGOUTS_PHASES.ROOM,
    room_id: "term-room-1"
  })

  const ended = hangoutReducer(active, {type: "ROOM_ENDED"})
  assert.equal(ended.phase, HANGOUTS_PHASES.ENDED)

  // Messages cannot be accepted after ended
  const postEnded = hangoutReducer(ended, {
    type: "MESSAGE_ACCEPTED",
    message: {sequence: 99, body: "should not add"}
  })
  assert.equal(postEnded.messages.length, 0)
})

test("intent formatters send only authorized fields and strictly target temporary slot", () => {
  // Message intent
  const msgIntent = formatMessageIntent("Hello group!")
  assert.ok(msgIntent.client_message_id)
  assert.equal(msgIntent.body, "Hello group!")
  assert.equal(Object.keys(msgIntent).sort().join(","), "body,client_message_id")

  // Reaction intent
  const reactIntent = formatReactionIntent(2, "🔥")
  assert.deepEqual(reactIntent, {expected_content_sequence: 2, reaction: "🔥"})

  // Skip intent
  const skipIntent = formatSkipIntent(2)
  assert.deepEqual(skipIntent, {expected_content_sequence: 2})

  // Block intent targets temporary slot only
  const blockIntent = formatBlockIntent(1)
  assert.deepEqual(blockIntent, {target_identity_slot: 1})

  // Report intent targets temporary slot with finite category and length limit
  const reportIntent = formatReportIntent(1, "harassment", "abusive text")
  assert.ok(reportIntent.client_report_id)
  assert.equal(reportIntent.target_identity_slot, 1)
  assert.equal(reportIntent.category, "harassment")
  assert.equal(reportIntent.evidence, "abusive text")
  assert.ok(REPORT_CATEGORIES.includes("harassment"))

  assert.throws(() => formatReportIntent(1, "unapproved_category", "evidence"), /invalid_category/)
})

test("HTML template includes distinct Hang Out navigation and screens", async () => {
  const html = await readFile("priv/static/index.html", "utf8")

  // Clearly distinct Hang Out entry, not a 1:1 door
  assert.match(html, /data-screen="hangout-entry"/)
  assert.match(html, /data-screen="hangout-waiting"/)
  assert.match(html, /data-screen="hangout-room"/)
  assert.match(html, /data-screen="hangout-ended"/)

  // Talk vs Hang Out distinction in navigation / landing
  assert.match(html, /data-go="hangout-entry"/)
  assert.match(html, /Hang Out/)

  // Room elements
  assert.match(html, /id="hangout-roster"/)
  assert.match(html, /id="hangout-messages"/)
  assert.match(html, /id="hangout-message-form"/)
  assert.match(html, /id="hangout-message-input"/)
  assert.match(html, /id="hangout-send-btn"/)
  assert.match(html, /id="hangout-leave-room-btn"/)
  assert.match(html, /id="hangout-reconnecting-banner"/)
})
