import assert from "node:assert/strict"
import test from "node:test"
import {
  activeConversations,
  chooseConversationRetention,
  decryptBackup,
  deleteAllKeptConversations,
  deleteKeptConversation,
  encryptBackup,
  keptConversations,
  localMessage,
  localVoiceNote,
  mergeRecords,
  signatureSeedFor,
  temporaryConversation,
  validEnvelope
} from "../../priv/static/assets/local_data.mjs"

const startedAt = "2026-08-06T00:00:00Z"
const endedAt = "2026-08-06T00:10:00Z"
const conversation = temporaryConversation({conversation_id: "conversation-a", door_type: "EXPLORE", display_door: "Advice", started_at: startedAt})
const message = localMessage({conversation_id: "conversation-a", message_id: "message-a", content: "hello", mine: true, delivery_status: "delivered", sent_at: startedAt})

test("encrypted backup round trips through a versioned PBKDF2/AES-GCM envelope", async () => {
  const records = [{id: "note:1", type: "memory", value: {text: "private"}, updated_at: "2026-08-05T00:00:00Z"}]
  const envelope = await encryptBackup(records, "correct horse battery staple")
  assert.equal(validEnvelope(envelope), true)
  assert.deepEqual(await decryptBackup(envelope, "correct horse battery staple"), records)
  await assert.rejects(() => decryptBackup(envelope, "wrong passphrase"))
})

test("import merge uses stable IDs and keeps the newest updated_at", () => {
  const old = {id: "note:1", type: "memory", value: "old", updated_at: "2026-08-05T00:00:00Z"}
  const newer = {...old, value: "new", updated_at: "2026-08-05T01:00:00Z"}
  const other = {id: "note:2", type: "memory", value: "other", updated_at: "2026-08-05T00:00:00Z"}
  assert.deepEqual(mergeRecords([old], [newer, other]), [newer, other])
})

test("invalid backup versions and structures are rejected", () => {
  assert.equal(validEnvelope({version: 3}), false)
  assert.equal(validEnvelope({version: 1, kdf: "PBKDF2-SHA256", cipher: "AES-GCM"}), false)
})

test("voice blobs follow Keep Summary Fade and deletion without affecting Memories or Bonds", () => {
  const voice = localVoiceNote({conversation_id: "conversation-a", voice_note_id: "voice-a", blob: new Blob(["voice"], {type: "audio/webm"}), mine: true, delivery_status: "delivered", sent_at: startedAt, sequence: 1, duration_ms: 1000, byte_size: 5, media_type: "audio/webm"})
  const memory = {id: "memory:1", type: "memory", value: {text: "mine"}, updated_at: startedAt}
  const bond = {id: "relationship:1", type: "relationship", value: {status: "created"}, updated_at: startedAt}
  assert.equal(chooseConversationRetention([conversation, voice], "conversation-a", "kept", {now: endedAt}).some(({type}) => type === "local_voice_note"), true)
  for (const choice of ["summary_only", "faded"]) {
    const options = choice === "summary_only" ? {now: endedAt, summaryText: "summary"} : {now: endedAt}
    const result = chooseConversationRetention([conversation, voice, memory, bond], "conversation-a", choice, options)
    assert.equal(result.some(({type}) => type === "local_voice_note"), false)
    assert.equal(result.some(({type}) => type === "memory"), true)
    assert.equal(result.some(({type}) => type === "relationship"), true)
  }
  assert.equal(deleteKeptConversation(chooseConversationRetention([conversation, voice], "conversation-a", "kept", {now: endedAt}), "conversation-a").some(({type}) => type === "local_voice_note"), false)
  assert.equal(deleteAllKeptConversations(chooseConversationRetention([conversation, voice], "conversation-a", "kept", {now: endedAt})).some(({type}) => type === "local_voice_note"), false)
})

test("only kept voice data enters encrypted backup and round trips as a Blob", async () => {
  const voice = localVoiceNote({conversation_id: "conversation-a", voice_note_id: "voice-a", blob: new Blob(["voice"], {type: "audio/webm"}), mine: true, delivery_status: "delivered", sent_at: startedAt, sequence: 1, duration_ms: 1000, byte_size: 5, media_type: "audio/webm"})
  const temporaryEnvelope = await encryptBackup([conversation, voice], "passphrase")
  assert.equal((await decryptBackup(temporaryEnvelope, "passphrase")).some(({type}) => type === "local_voice_note"), false)
  const kept = chooseConversationRetention([conversation, voice], "conversation-a", "kept", {now: endedAt})
  const restored = await decryptBackup(await encryptBackup(kept, "passphrase"), "passphrase")
  const restoredVoice = restored.find(({type}) => type === "local_voice_note")
  assert.equal(restoredVoice.value.blob instanceof Blob, true)
  assert.equal(await restoredVoice.value.blob.text(), "voice")
})

test("previous text-only backup envelope versions remain importable", async () => {
  const record = {id: "memory:old", type: "memory", value: {text: "old"}, updated_at: startedAt}
  const envelope = await encryptBackup([record], "passphrase")
  assert.deepEqual(await decryptBackup({...envelope, version: 1}, "passphrase"), [record])
})

test("private Bond reconnection display state is excluded from kept-history backup", async () => {
  const state = {id: "bond-reconnect:bond-a", type: "bond_reconnect_state", value: {relationship_id: "bond-a", status: "waiting_for_mutual_availability", door_type: "EXPLORE", expires_at: endedAt}, updated_at: startedAt}
  assert.equal((await decryptBackup(await encryptBackup([state], "passphrase"), "passphrase")).length, 0)
})

test("active messages cache under a temporary conversation without promoting it", () => {
  assert.equal(conversation.value.status, "temporary")
  assert.equal(message.type, "local_message")
  assert.equal(message.value.delivery_status, "delivered")
  assert.equal(keptConversations([conversation, message]).length, 0)
  assert.deepEqual(activeConversations([conversation, message]), [conversation])
})

test("Keep preserves the transcript and marks only the conversation kept", () => {
  const result = chooseConversationRetention([conversation, message], "conversation-a", "kept", {now: endedAt})
  assert.equal(keptConversations(result)[0].value.status, "kept")
  assert.equal(result.filter(({type}) => type === "local_message").length, 1)
})

test("Summary requires and stores a summary before removing the transcript", () => {
  assert.throws(() => chooseConversationRetention([conversation, message], "conversation-a", "summary_only", {summaryText: ""}), /summary_required/)
  const result = chooseConversationRetention([conversation, message], "conversation-a", "summary_only", {summaryText: "A useful thought", now: endedAt})
  assert.equal(result.find(({type}) => type === "local_conversation").value.status, "summary_only")
  assert.equal(result.find(({type}) => type === "summary").value.text, "A useful thought")
  assert.equal(result.some(({type}) => type === "local_message"), false)
  assert.equal(keptConversations(result).length, 0)
})

test("Fade removes transcript and summary while leaving separate Memories", () => {
  const memory = {id: "memory:separate", type: "memory", value: {text: "mine"}, updated_at: startedAt}
  const summary = {id: "summary:conversation-a", type: "summary", value: {conversation_id: "conversation-a", text: "old"}, updated_at: startedAt}
  const result = chooseConversationRetention([conversation, message, summary, memory], "conversation-a", "faded", {now: endedAt})
  assert.equal(result.some(({type}) => type === "local_message"), false)
  assert.equal(result.some(({type}) => type === "summary"), false)
  assert.equal(result.some(({type}) => type === "memory"), true)
  assert.equal(result.find(({type}) => type === "local_conversation").value.status, "faded")
})

test("Chats lists only kept conversations", () => {
  const kept = chooseConversationRetention([conversation, message], "conversation-a", "kept", {now: endedAt})
  const other = temporaryConversation({conversation_id: "conversation-b", door_type: "JUST_TALK", display_door: "Vent", started_at: startedAt})
  assert.deepEqual(keptConversations([...kept, other]).map(({value}) => value.conversation_id), ["conversation-a"])
})

test("delete one and delete all remove kept transcripts but not separate Memories or unconfirmed summaries", () => {
  const memory = {id: "memory:separate", type: "memory", value: {text: "mine"}, updated_at: startedAt}
  const summary = {id: "summary:conversation-a", type: "summary", value: {conversation_id: "conversation-a", text: "summary"}, updated_at: startedAt}
  const kept = chooseConversationRetention([conversation, message], "conversation-a", "kept", {now: endedAt})
  for (const result of [deleteKeptConversation([...kept, summary, memory], "conversation-a"), deleteAllKeptConversations([...kept, summary, memory])]) {
    assert.equal(result.some(({type}) => type === "local_message"), false)
    assert.equal(result.some(({type}) => type === "local_conversation"), false)
    assert.equal(result.some(({type}) => type === "summary"), true)
    assert.equal(result.some(({type}) => type === "memory"), true)
  }
})

test("signature seed is stable per conversation and distinct across conversations", () => {
  assert.equal(signatureSeedFor("conversation-a"), signatureSeedFor("conversation-a"))
  assert.notEqual(signatureSeedFor("conversation-a"), signatureSeedFor("conversation-b"))
  assert.match(signatureSeedFor("conversation-a"), /^sig-[a-f0-9]{8}$/)
})
