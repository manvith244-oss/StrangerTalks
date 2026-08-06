import {Socket} from "/vendor/phoenix.mjs"
import {DOORS, queuePayloadFor} from "./door_mapping.mjs"
import {
  activeConversations, chooseConversationRetention, clearRecords, decryptBackup,
  deleteAllKeptConversations, deleteKeptConversation, deleteRecord, encryptBackup,
  getRecord, importRecords, keptConversations, listRecords, localMessage, putRecord,
  localVoiceNote, replaceRecords, temporaryConversation
} from "./local_data.mjs"
import {
  MAX_VOICE_BYTES, MAX_VOICE_DURATION_MS, VOICE_WARNING_VERSION, baseMediaType,
  chronologicalTimeline, selectVoiceMediaType, stopMediaTracks, validVoiceBlob,
  warningAcknowledged
} from "./voice_notes.mjs"
import {createMatchedTransitionTracker, createReconnectCountdownController, reconnectDisplayState, reconnectStateRecord, remainingAvailabilitySeconds, unavailableReconnectState} from "./bond_reconnect.mjs"
import {decryptSyncWithKey, encryptSyncBundle, encryptSyncWithKey, loadSyncKey, mergeSyncRecords, storeSyncKey, supportsPersistentCryptoKey, syncableRecords, tombstoneFor, unlockSync} from "./encrypted_sync.mjs"

const identityKey = "strangertalks.identity.v1"
const app = {identity: null, socket: null, participant: null, participantJoined: false, conversation: null, conversationId: null, selectedDoor: null, rendered: new Set(), typingTimer: null, historyConversationId: null, timelinePinned: true, account: {available: false, connected: false, revision: 0, passphrase: null, syncKey: null, envelope: null}, matchedTransition: createMatchedTransitionTracker(), reconnectCountdown: createReconnectCountdownController(), voice: {mediaType: null, recorder: null, stream: null, chunks: [], startedAt: 0, timer: null, stopTimer: null, discard: false, blob: null, objectUrl: null, voiceNoteId: null, durationMs: 0}, voiceUrls: new Map()}
const $ = (selector) => document.querySelector(selector)
const now = () => new Date().toISOString()

function accountFetch(path, options = {}) {
  const headers = {...(options.headers || {})}
  if (options.method && !["GET", "HEAD"].includes(options.method)) headers["X-StrangerTalks-CSRF"] = app.account.csrf_token
  return fetch(path, {...options, credentials: "same-origin", headers})
}

function announce(message) { $("#status").textContent = message }
function show(name) {
  if (name !== "relationships") app.reconnectCountdown.stop()
  document.querySelectorAll("[data-screen]").forEach((node) => node.classList.toggle("active", node.dataset.screen === name))
  $("#bottom-nav").hidden = !["doors", "chats", "relationships", "settings"].includes(name)
  if (name === "chats") renderChats()
  if (name === "relationships") renderLocalViews()
}
function push(channel, event, payload = {}) { return new Promise((resolve, reject) => channel.push(event, payload).receive("ok", resolve).receive("error", reject).receive("timeout", () => reject({reason: "timeout"}))) }

async function bootstrap() {
  const saved = await getRecord(identityKey)
  const account = await fetch("/api/account/session", {credentials: "same-origin"}).then((response) => response.json()).catch(() => ({available: false, connected: false}))
  app.account = {...app.account, ...account}
  if (account.connected && await supportsPersistentCryptoKey().catch(() => false)) app.account.syncKey = await loadSyncKey().catch(() => null)
  if (account.connected) {
    const retained = syncableRecords(await listRecords())
    const useConnected = !saved || saved.value.participant_id === account.participant_id || !retained.length || confirm("Use your privately connected participant on this device? Existing kept local data will remain here until you choose Restore or Sync. Choose Cancel to stay with this guest.")
    if (useConnected) {
      app.identity = {participant_id: account.participant_id, token: account.participant_token}
      await putRecord({id: identityKey, type: "identity", value: app.identity, updated_at: now()})
    } else {
      await accountFetch("/api/account/session", {method: "DELETE"})
      app.account.connected = false
    }
  }
  if (!app.identity && saved) app.identity = saved.value
  if (!app.identity) await createIdentity(false)
  await renderAccountState()
  connectSocket()
}

async function createIdentity(replacing) {
  if (replacing) announce("Your previous anonymous identity is unavailable. Creating a new one.")
  const response = await fetch("/api/participants", {method: "POST", headers: {"content-type": "application/json"}, body: "{}"})
  if (!response.ok) throw new Error("participant bootstrap failed")
  app.identity = await response.json()
  await putRecord({id: identityKey, type: "identity", value: app.identity, updated_at: now()})
}

function connectSocket() {
  app.socket = new Socket("/socket", {params: {token: app.identity.token}})
  app.socket.onError(() => { updateLocalConnection("reconnecting"); $("#presence").textContent = "Reconnecting…"; announce("Connection interrupted. Reconnecting.") })
  app.socket.onClose(() => { if (app.conversationId) { updateLocalConnection("recovery"); $("#presence").textContent = "Reconnecting…" } })
  app.socket.connect()
  app.participant = app.socket.channel(`participant:${app.identity.participant_id}`, {})
  app.participant.on("queue:status", ({status}) => { announce(`Queue status: ${status}`); if (status === "timed_out") show("doors") })
  app.participant.on("match_found", (payload) => { handleMatchedConversation(payload).catch(() => announce("Reconnecting to the Conversation…")) })
  app.participant.on("relationship:created", ({relationship_id}) => { rememberRelationship(relationship_id); $("#consent-status").textContent = "Bond created."; announce("Mutual Bond created.") })
  app.participant.join().receive("ok", async () => { app.participantJoined = true; await resumeLocalConversation(); if (document.querySelector('[data-screen="relationships"]').classList.contains("active")) renderLocalViews() }).receive("error", recoverIdentity)
}

async function resumeLocalConversation() {
  const active = activeConversations(await listRecords())[0]
  if (active) { app.selectedDoor = active.value.display_door; updateDoorLabels(); await handleMatchedConversation({status: "matched", conversation_id: active.value.conversation_id}) }
}

async function recoverIdentity() { await deleteRecord(identityKey); app.socket?.disconnect(); await createIdentity(true); connectSocket() }

function joinConversation(id) {
  app.conversation = app.socket.channel(`conversation:${id}`, {})
  app.conversation.on("conversation:presence", ({status}) => { updateLocalConnection(status === "disconnected" ? "recovery" : status); $("#presence").textContent = status === "connected" ? "Connected" : status === "reconnecting" ? "The other person is reconnecting…" : "Disconnected"; if (status === "connected") scrollTimelineToNewest() })
  app.conversation.on("typing:status", ({typing}) => { $("#typing").textContent = typing ? "The other person is typing…" : "" })
  app.conversation.on("message:new", (message) => { renderMessage(message, false); push(app.conversation, "message:ack", {message_id: message.message_id}).catch(() => {}) })
  app.conversation.on("message:status", updateMessageStatus)
  app.conversation.on("voice_note:new", receiveVoiceNote)
  app.conversation.on("voice_note:status", updateVoiceNoteStatus)
  app.conversation.on("conversation:ended", async () => { cancelRecording(); await markConversationEnded(); show("ended"); announce("Conversation ended. Choose what this device should retain.") })
  app.conversation.join().receive("ok", async () => { await ensureTemporaryConversation(id); await renderCachedConversation(id); show("conversation"); scrollTimelineToNewest(); announce("Conversation joined.") }).receive("error", () => { app.matchedTransition.release(id); updateLocalConnection("recovery"); show("match"); announce("Reconnecting to the Conversation…") })
}

async function handleMatchedConversation(payload, relationshipId = null) {
  const conversationId = app.matchedTransition.claim(payload)
  if (!conversationId) return
  if (relationshipId) await putRecord(reconnectStateRecord({relationship_id: relationshipId, status: "matched", conversation_id: conversationId}, now()))
  app.reconnectCountdown.stop()
  app.conversationId = conversationId
  await ensureTemporaryConversation(conversationId)
  show("match")
  joinConversation(conversationId)
}

async function ensureTemporaryConversation(conversationId) {
  const id = `conversation:${conversationId}`
  const existing = await getRecord(id)
  if (existing) return putRecord({...existing, value: {...existing.value, connection_state: "connected"}, updated_at: now()})
  const door = DOORS.find(({label}) => label === app.selectedDoor) || DOORS[0]
  return putRecord(temporaryConversation({conversation_id: conversationId, door_type: door.value, display_door: door.label, started_at: now()}))
}

async function updateLocalConnection(connection_state) {
  if (!app.conversationId) return
  const record = await getRecord(`conversation:${app.conversationId}`)
  if (record?.value.status === "temporary") await putRecord({...record, value: {...record.value, connection_state}, updated_at: now()})
}

async function markConversationEnded() {
  const record = await getRecord(`conversation:${app.conversationId}`)
  if (record) await putRecord({...record, value: {...record.value, connection_state: "ended", ended_at: now()}, updated_at: now()})
}

async function renderCachedConversation(conversationId) {
  app.rendered.clear(); $("#messages").replaceChildren()
  const records = await listRecords()
  chronologicalTimeline(records.filter((record) => ["local_message", "local_voice_note"].includes(record.type) && record.value.conversation_id === conversationId)).forEach((record) => record.type === "local_voice_note" ? renderVoiceNoteNode(record.value, $("#messages"), false) : renderMessageNode(record.value, record.value.mine, $("#messages")))
}

function renderMessage(message, mine) {
  if (app.rendered.has(message.message_id)) return
  const shouldFollow = mine || timelineNearBottom()
  renderMessageNode(message, mine, $("#messages"))
  requestAnimationFrame(() => {
    if (shouldFollow) scrollTimelineToNewest({smooth: true})
    else $("#new-messages").hidden = false
  })
  const sent_at = message.sent_at || now()
  putRecord(localMessage({conversation_id: app.conversationId, message_id: message.message_id, content: message.content, mine, delivery_status: message.status || "delivered", sent_at})).catch(() => {})
}

function renderMessageNode(message, mine, container) {
  if (app.rendered.has(message.message_id)) return
  app.rendered.add(message.message_id)
  const item = document.createElement("li"); item.className = `message${mine ? " mine" : ""}`; item.dataset.messageId = message.message_id
  const content = document.createElement("span"); content.textContent = message.content; item.append(content)
  if (mine && container.id !== "history-messages") { const status = document.createElement("small"); status.textContent = message.delivery_status || message.status || "sent_to_server"; item.append(status) }
  container.append(item)
}

function updateMessageStatus({message_id, status}) {
  document.querySelector(`[data-message-id="${CSS.escape(message_id)}"] small`)?.replaceChildren(document.createTextNode(status))
  const id = `message:${app.conversationId}:${message_id}`
  getRecord(id).then((record) => record && putRecord({...record, value: {...record.value, delivery_status: status}, updated_at: now()})).catch(() => {})
}

function renderVoiceNoteNode(note, container, historical) {
  if (app.rendered.has(note.voice_note_id)) return
  app.rendered.add(note.voice_note_id)
  const item = document.createElement("li"); item.className = `message voice-note${note.mine ? " mine" : ""}`; item.dataset.voiceNoteId = note.voice_note_id
  const label = document.createElement("strong"); label.textContent = "Voice note"
  const audio = document.createElement("audio"); audio.controls = true; audio.preload = "metadata"; audio.autoplay = false
  releaseVoiceUrl(note.voice_note_id)
  const url = URL.createObjectURL(note.blob); app.voiceUrls.set(note.voice_note_id, url); audio.src = url
  item.append(label, audio)
  if (historical) { const copy = document.createElement("span"); copy.className = "local-voice-copy"; copy.textContent = "This voice note is stored on this device as part of your local Conversation copy."; item.append(copy) }
  else if (note.mine) { const status = document.createElement("small"); status.textContent = note.delivery_status || "sent_to_server"; item.append(status) }
  container.append(item)
}

async function receiveVoiceNote(note) {
  const shouldFollow = timelineNearBottom()
  const id = `voice:${app.conversationId}:${note.voice_note_id}`
  const existing = await getRecord(id)
  if (existing?.value.blob) {
    renderVoiceNoteNode(existing.value, $("#messages"), false)
    await push(app.conversation, "voice_note:ack", {voice_note_id: note.voice_note_id})
    return
  }

  try {
    const response = await fetch(`/api/conversations/${app.conversationId}/voice-notes/${note.voice_note_id}`, {headers: {authorization: `Bearer ${app.identity.token}`}})
    if (!response.ok) throw new Error("download_failed")
    const blob = await response.blob()
    if (!validVoiceBlob(blob)) throw new Error("invalid_voice_note")
    const record = localVoiceNote({conversation_id: app.conversationId, voice_note_id: note.voice_note_id, blob, mine: false, delivery_status: "delivered", sent_at: note.timestamp, sequence: note.sequence, duration_ms: note.duration_ms, byte_size: note.byte_size, media_type: note.media_type})
    try { await putRecord(record) } catch { announce("Voice note received, but it may not survive refresh because local storage is unavailable.") }
    renderVoiceNoteNode(record.value, $("#messages"), false)
    requestAnimationFrame(() => { if (shouldFollow) scrollTimelineToNewest({smooth: true}); else $("#new-messages").hidden = false })
    await push(app.conversation, "voice_note:ack", {voice_note_id: note.voice_note_id})
  } catch { announce("A voice note could not be downloaded before it expired.") }
}

function updateVoiceNoteStatus({voice_note_id, status}) {
  document.querySelector(`[data-voice-note-id="${CSS.escape(voice_note_id)}"] small`)?.replaceChildren(document.createTextNode(status))
  const id = `voice:${app.conversationId}:${voice_note_id}`
  getRecord(id).then((record) => record && putRecord({...record, value: {...record.value, delivery_status: status}, updated_at: now()})).catch(() => {})
}

async function rememberRelationship(id) {
  const conversation = await getRecord(`conversation:${app.conversationId}`)
  await putRecord({id: `relationship:${id}`, type: "relationship", value: {relationship_id: id, status: "created", conversation_id: app.conversationId, abstract_signature_seed: conversation?.value.abstract_signature_seed || null, origin_door_type: conversation?.value.door_type || null, origin_door_label: conversation?.value.display_door || null, formed_at: conversation?.value.ended_at || now(), private_nickname: null}, updated_at: now()})
  renderLocalViews()
  await offerContinuity()
  await maybeAutoSync()
}

async function applyRetention(choice, summaryText) {
  const records = await listRecords()
  const next = chooseConversationRetention(records, app.conversationId, choice, {summaryText, now: now()})
  if (choice === "summary_only") await putRecord(next.find(({id}) => id === `summary:${app.conversationId}`))
  await replaceRecords(next)
  if (["kept", "summary_only"].includes(choice)) { await offerContinuity(); await maybeAutoSync() }
  releaseAllVoiceUrls()
  app.conversationId = null
  if (choice === "kept") show("chats"); else show("doors")
}

async function renderChats() {
  const records = await listRecords()
  const active = activeConversations(records)
  const kept = keptConversations(records).sort((a, b) => b.updated_at.localeCompare(a.updated_at))
  renderChatCards($("#active-chat-list"), active, records, "Nothing happening right now. That's okay.", false)
  renderChatCards($("#kept-chat-list"), kept, records, "No Conversations kept on this device.", true)
}

function renderChatCards(container, conversations, records, emptyText, openable) {
  container.replaceChildren()
  if (!conversations.length) { container.textContent = emptyText; return }
  conversations.forEach((conversation) => {
    const article = document.createElement("article"); article.className = "chat-card"
    article.append(signatureRibbon(conversation.value.abstract_signature_seed))
    const title = document.createElement("h3"); title.textContent = conversation.value.display_door
    const date = document.createElement("time"); date.dateTime = conversation.value.started_at; date.textContent = new Date(conversation.value.started_at).toLocaleString()
    const summary = records.find(({id}) => id === conversation.value.summary_id)?.value.text
    const firstMessage = records.filter((record) => record.type === "local_message" && record.value.conversation_id === conversation.value.conversation_id).sort((a, b) => a.value.sent_at.localeCompare(b.value.sent_at))[0]?.value.content
    const preview = document.createElement("p"); preview.textContent = summary || firstMessage?.split("\n")[0] || "Conversation kept without a preview."
    const label = document.createElement("p"); label.className = "local-only"; label.textContent = "Local copy"
    article.append(title, date, preview, label)
    if (openable) { const open = document.createElement("button"); open.textContent = "Open local copy"; open.setAttribute("aria-label", `Open local copy: ${conversation.value.display_door}`); open.addEventListener("click", () => openHistory(conversation.value.conversation_id)); article.append(open) }
    container.append(article)
  })
}

function signatureRibbon(seed) {
  const ribbon = document.createElement("div"); ribbon.className = "signature-ribbon"; ribbon.setAttribute("aria-hidden", "true")
  const value = Number.parseInt((seed || "sig-77777777").slice(-8), 16); ribbon.style.setProperty("--signature-a", `hsl(${value % 360} 36% 48%)`); ribbon.style.setProperty("--signature-b", `hsl(${(value >>> 8) % 360} 48% 68%)`); return ribbon
}

function updateDoorLabels() {
  if (!app.selectedDoor) return
  $("#queue-door").textContent = app.selectedDoor
  $("#conversation-door").textContent = app.selectedDoor
}

function reducedMotionEnabled() {
  return document.body.classList.contains("reduce-motion") || window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

function timelineNearBottom() {
  const viewport = $("#message-viewport")
  return viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight <= 80
}

function scrollTimelineToNewest({smooth = false} = {}) {
  requestAnimationFrame(() => {
    const viewport = $("#message-viewport")
    viewport.scrollTo({top: viewport.scrollHeight, behavior: smooth && !reducedMotionEnabled() ? "smooth" : "auto"})
    app.timelinePinned = true
    $("#new-messages").hidden = true
  })
}

function scrollHistoryToNewest() {
  requestAnimationFrame(() => $("#history-messages").lastElementChild?.scrollIntoView({block: "end", behavior: "auto"}))
}

async function openHistory(conversationId) {
  app.historyConversationId = conversationId; app.rendered.clear(); releaseAllVoiceUrls(); $("#history-messages").replaceChildren()
  const records = await listRecords(); const conversation = records.find(({id}) => id === `conversation:${conversationId}`)
  $("#history-title").textContent = conversation.value.display_door
  const ribbon = signatureRibbon(conversation.value.abstract_signature_seed); $("#history-signature").replaceWith(ribbon); ribbon.id = "history-signature"
  chronologicalTimeline(records.filter((record) => ["local_message", "local_voice_note"].includes(record.type) && record.value.conversation_id === conversationId)).forEach((record) => record.type === "local_voice_note" ? renderVoiceNoteNode(record.value, $("#history-messages"), true) : renderMessageNode(record.value, record.value.mine, $("#history-messages")))
  $("#history-summary").value = records.find(({id}) => id === `summary:${conversationId}`)?.value.text || ""
  show("history")
  scrollHistoryToNewest()
}

function releaseVoiceUrl(voiceNoteId) {
  const url = app.voiceUrls.get(voiceNoteId)
  if (url) URL.revokeObjectURL(url)
  app.voiceUrls.delete(voiceNoteId)
}

function releaseAllVoiceUrls() {
  for (const voiceNoteId of [...app.voiceUrls.keys()]) releaseVoiceUrl(voiceNoteId)
}

function clearVoicePreview() {
  if (app.voice.objectUrl) URL.revokeObjectURL(app.voice.objectUrl)
  app.voice.objectUrl = null; app.voice.blob = null; app.voice.voiceNoteId = null; app.voice.durationMs = 0
  $("#voice-preview-audio").removeAttribute("src"); $("#voice-preview-audio").load(); $("#voice-preview").hidden = true
}

function closeVoiceStream() {
  clearInterval(app.voice.timer); clearTimeout(app.voice.stopTimer); stopMediaTracks(app.voice.stream)
  app.voice.stream = null; app.voice.recorder = null; $("#voice-recording").hidden = true
}

async function requestVoiceRecording() {
  const warning = await getRecord("settings:voice-warning:v1")
  if (!warningAcknowledged(warning)) { $("#voice-warning").hidden = false; return }
  await startVoiceRecording()
}

async function startVoiceRecording() {
  $("#voice-warning").hidden = true; clearVoicePreview(); $("#voice-preview-status").textContent = ""
  if (!app.voice.mediaType || !navigator.mediaDevices?.getUserMedia) { announce("Voice recording is unavailable in this browser. Text messaging still works."); return }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({audio: true})
    const recorder = new MediaRecorder(stream, {mimeType: app.voice.mediaType, audioBitsPerSecond: 64_000})
    Object.assign(app.voice, {stream, recorder, chunks: [], startedAt: Date.now(), discard: false})
    recorder.addEventListener("dataavailable", ({data}) => { if (data.size) app.voice.chunks.push(data) })
    recorder.addEventListener("stop", finishVoiceRecording, {once: true})
    recorder.start(); $("#voice-recording").hidden = false; updateVoiceTimer()
    app.voice.timer = setInterval(updateVoiceTimer, 250)
    app.voice.stopTimer = setTimeout(() => { if (recorder.state === "recording") recorder.stop() }, MAX_VOICE_DURATION_MS)
  } catch { closeVoiceStream(); announce("Microphone access was not granted. Text messaging is still available.") }
}

function updateVoiceTimer() {
  const seconds = Math.min(60, Math.floor((Date.now() - app.voice.startedAt) / 1000))
  $("#voice-timer").textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
}

function finishVoiceRecording() {
  const durationMs = Math.min(MAX_VOICE_DURATION_MS, Math.max(1, Date.now() - app.voice.startedAt))
  const discard = app.voice.discard; const blob = new Blob(app.voice.chunks, {type: baseMediaType(app.voice.mediaType)})
  closeVoiceStream()
  if (discard) { clearVoicePreview(); return }
  app.voice.blob = blob; app.voice.durationMs = durationMs; app.voice.voiceNoteId = crypto.randomUUID()
  app.voice.objectUrl = URL.createObjectURL(blob); $("#voice-preview-audio").src = app.voice.objectUrl; $("#voice-preview").hidden = false
  const valid = validVoiceBlob(blob); $("#voice-send").disabled = !valid
  $("#voice-preview-status").textContent = valid ? "Review before sending. Nothing is sent automatically." : `This recording is too large. Voice notes must be ${MAX_VOICE_BYTES.toLocaleString()} bytes or less.`
}

function cancelRecording() {
  app.voice.discard = true
  if (app.voice.recorder?.state === "recording") app.voice.recorder.stop(); else { closeVoiceStream(); clearVoicePreview() }
}

async function sendVoicePreview() {
  if (!validVoiceBlob(app.voice.blob)) return
  const id = app.voice.voiceNoteId; const sentAt = now(); $("#voice-send").disabled = true; $("#voice-preview-status").textContent = "Uploading…"
  const record = localVoiceNote({conversation_id: app.conversationId, voice_note_id: id, blob: app.voice.blob, mine: true, delivery_status: "sending", sent_at: sentAt, sequence: null, duration_ms: app.voice.durationMs, byte_size: app.voice.blob.size, media_type: baseMediaType(app.voice.mediaType)})
  await putRecord(record)
  try {
    const response = await fetch(`/api/conversations/${app.conversationId}/voice-notes/${id}`, {method: "POST", headers: {authorization: `Bearer ${app.identity.token}`, "content-type": baseMediaType(app.voice.mediaType), "x-voice-duration-ms": String(app.voice.durationMs)}, body: app.voice.blob})
    const result = await response.json()
    if (!response.ok) throw new Error(result.error || "upload_failed")
    const saved = {...record, value: {...record.value, delivery_status: result.status}, updated_at: now()}; await putRecord(saved)
    renderVoiceNoteNode(saved.value, $("#messages"), false); clearVoicePreview(); scrollTimelineToNewest({smooth: true})
  } catch { $("#voice-preview-status").textContent = "Voice note failed to send. Try again or re-record."; $("#voice-send").disabled = false; updateVoiceNoteStatus({voice_note_id: id, status: "failed"}) }
}

async function renderLocalViews() {
  const records = await listRecords(); renderRecordList($("#memory-list"), records.filter(({type}) => type === "memory" || type === "summary"))
  const relationships = records.filter(({type}) => type === "relationship"); const container = $("#relationship-list"); container.replaceChildren()
  if (!relationships.length) container.textContent = "No Bonds saved on this device."
  relationships.forEach((record) => {
    const article = document.createElement("article"); article.className = "bond-card"
    if (record.value.abstract_signature_seed) article.append(signatureRibbon(record.value.abstract_signature_seed))
    const title = document.createElement("h3"); title.textContent = record.value.private_nickname || "Private Bond"
    const details = document.createElement("p"); details.textContent = `${record.value.origin_door_label || "Conversation"} · ${new Date(record.value.formed_at || record.updated_at).toLocaleDateString()}`
    const reconnect = document.createElement("div"); reconnect.className = "bond-reconnect"; reconnect.dataset.relationshipId = record.value.relationship_id
    article.append(title, details, reconnect); container.append(article)
    renderReconnectState(reconnect, {relationship_id: record.value.relationship_id, status: "idle"})
    if (app.participantJoined) restoreReconnectStatus(record.value.relationship_id, reconnect)
  })
  startReconnectCountdown()
}

async function restoreReconnectStatus(relationshipId, container) {
  try {
    const result = await push(app.participant, "bond:reconnect_status", {relationship_id: relationshipId})
    const state = reconnectDisplayState(result, relationshipId)
    await putRecord(reconnectStateRecord(state, now()))
    if (state.status === "matched") await handleMatchedConversation(state, relationshipId)
    else renderReconnectState(container, state)
  } catch {
    const unavailable = unavailableReconnectState(relationshipId)
    await putRecord(reconnectStateRecord(unavailable, now()))
    renderReconnectState(container, unavailable)
  }
}

function renderReconnectState(container, state) {
  container.replaceChildren()
  if (state.status === "matched") { const message = document.createElement("p"); message.textContent = "Reconnecting to your Conversation…"; container.append(message); app.reconnectCountdown.stop(); return }
  if (state.status === "unavailable") { const message = document.createElement("p"); message.textContent = "Private reconnection is unavailable right now."; const retry = document.createElement("button"); retry.textContent = "Try again"; retry.addEventListener("click", () => restoreReconnectStatus(state.relationship_id, container)); container.append(message, retry); return }
  if (state.status !== "waiting_for_mutual_availability" || remainingAvailabilitySeconds(state.expires_at) === 0) {
    const button = document.createElement("button"); button.textContent = "Reconnect privately"; button.addEventListener("click", () => renderReconnectDoors(container, state.relationship_id)); container.append(button); return
  }
  const heading = document.createElement("strong"); heading.textContent = "Available to reconnect for 15 minutes."
  const privacy = document.createElement("p"); privacy.textContent = "They will never know unless they choose the same."
  const selected = document.createElement("p"); selected.textContent = `Selected Door: ${DOORS.find(({value}) => value === state.door_type)?.label || state.door_type}`
  const countdown = document.createElement("time"); countdown.dataset.expiresAt = state.expires_at; countdown.textContent = availabilityCopy(state.expires_at)
  const change = document.createElement("button"); change.textContent = "Change Door"; change.addEventListener("click", () => renderReconnectDoors(container, state.relationship_id))
  const cancel = document.createElement("button"); cancel.textContent = "Cancel"; cancel.addEventListener("click", async () => { try { await push(app.participant, "bond:reconnect_cancel", {relationship_id: state.relationship_id}); const idle = {relationship_id: state.relationship_id, status: "idle"}; await putRecord(reconnectStateRecord(idle, now())); renderReconnectState(container, idle); refreshReconnectCountdown() } catch { announce("Could not cancel private availability. Try again.") } })
  container.append(heading, privacy, selected, countdown, change, cancel)
  startReconnectCountdown()
}

function renderReconnectDoors(container, relationshipId) {
  container.replaceChildren()
  const prompt = document.createElement("p"); prompt.textContent = "What kind of Conversation do you need right now?"; container.append(prompt)
  DOORS.forEach((door) => { const button = document.createElement("button"); button.textContent = door.label; button.addEventListener("click", async () => { try { const result = await push(app.participant, "bond:reconnect_start", {relationship_id: relationshipId, door_type: door.value}); const state = reconnectDisplayState(result, relationshipId); await putRecord(reconnectStateRecord(state, now())); if (state.status === "matched") await handleMatchedConversation(state, relationshipId); else renderReconnectState(container, state) } catch { const unavailable = unavailableReconnectState(relationshipId); await putRecord(reconnectStateRecord(unavailable, now())); renderReconnectState(container, unavailable); announce("Private reconnection is unavailable right now.") } }); container.append(button) })
}

function availabilityCopy(expiresAt) {
  const seconds = remainingAvailabilitySeconds(expiresAt); return seconds ? `${Math.ceil(seconds / 60)} minutes remaining` : "Availability expired"
}

function startReconnectCountdown() {
  if (!document.querySelector("[data-expires-at]")) return app.reconnectCountdown.stop()
  if (!app.reconnectCountdown.active()) app.reconnectCountdown.start(updateReconnectCountdowns)
}
function refreshReconnectCountdown() { if (document.querySelector("[data-expires-at]")) startReconnectCountdown(); else app.reconnectCountdown.stop() }
function updateReconnectCountdowns() { document.querySelectorAll("[data-expires-at]").forEach((node) => { node.textContent = availabilityCopy(node.dataset.expiresAt); if (remainingAvailabilitySeconds(node.dataset.expiresAt) === 0) { const container = node.closest(".bond-reconnect"); renderReconnectState(container, {relationship_id: container.dataset.relationshipId, status: "idle"}) } }); refreshReconnectCountdown() }

function renderRecordList(container, records) { container.replaceChildren(); if (!records.length) { container.textContent = "Nothing saved locally yet."; return } records.forEach((record) => { const article = document.createElement("article"); const text = document.createElement("p"); text.textContent = record.value.text || record.type; const remove = document.createElement("button"); remove.textContent = "Delete"; remove.addEventListener("click", async () => { await putRecord(tombstoneFor(record, now())); renderLocalViews(); renderDataInventory(); await maybeAutoSync() }); article.append(text, remove); container.append(article) }) }
async function renderDataInventory() { const records = await listRecords(); const totals = records.reduce((counts, {type}) => ({...counts, [type]: (counts[type] || 0) + 1}), {}); $("#local-data-list").textContent = Object.keys(totals).length ? Object.entries(totals).map(([type, count]) => `${type}: ${count}`).join(" · ") : "No local data stored." }

async function renderAccountState() {
  $("#account-guest").hidden = !app.account.available || app.account.connected
  $("#account-connected").hidden = !app.account.connected
  $("#account-disabled").hidden = app.account.available
  const auto = await getRecord("settings:auto-sync")
  $("#auto-sync").checked = auto?.value.enabled === true
  if (!app.account.connected || !app.account.available) $("#continuity-suggestion").hidden = true
}

async function startGoogle(mode) {
  const headers = {accept: "application/json"}
  if (mode === "link") headers.authorization = `Bearer ${app.identity.token}`
  const response = await fetch(`/auth/google/start?mode=${mode}`, {headers, credentials: "same-origin"})
  const body = await response.json()
  if (!response.ok || !body.authorization_url) throw new Error(body.error?.reason || "oauth_start_failed")
  location.assign(body.authorization_url)
}

async function fetchRemoteSync() {
  const response = await fetch("/api/account/sync", {credentials: "same-origin", headers: {accept: "application/json"}})
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(body.error?.reason || "sync_failed")
  app.account.revision = body.revision
  app.account.envelope = body.envelope || null
  if (body.last_synced_at) { $("#sync-last").textContent = `Last synced ${new Date(body.last_synced_at).toLocaleString()}.`; $("#sync-status").textContent = "Encrypted Google sync is available." }
  return body
}

function requestRecoveryPassphrase({confirmChoice = false} = {}) {
  const passphrase = prompt("Enter a recovery passphrase. If you lose it and all unlocked devices, neither StrangerTalks nor Google can recover this encrypted data.")
  if (!passphrase) throw new Error("passphrase_required")
  if (confirmChoice && passphrase !== prompt("Enter the recovery passphrase again to confirm.")) throw new Error("passphrase_mismatch")
  app.account.passphrase = passphrase
  return passphrase
}

async function uploadSync(records, baseRevision, passphrase) {
  let envelope
  if (app.account.syncKey && app.account.envelope) {
    envelope = await encryptSyncWithKey(syncableRecords(records), app.account.syncKey, app.account.envelope, baseRevision)
  } else {
    const bundle = await encryptSyncBundle(syncableRecords(records), passphrase, baseRevision)
    envelope = bundle.envelope
    app.account.syncKey = bundle.syncKey
    if (await supportsPersistentCryptoKey().catch(() => false)) await storeSyncKey(bundle.syncKey).catch(() => {})
  }
  const response = await accountFetch("/api/account/sync", {method: "PUT", headers: {"content-type": "application/json"}, body: JSON.stringify({base_revision: baseRevision, envelope})})
  const body = await response.json().catch(() => ({}))
  if (response.status === 409) throw new Error("sync_conflict")
  if (!response.ok) throw new Error(body.error?.reason || "sync_failed")
  app.account.revision = body.revision
  app.account.envelope = {...envelope, revision: body.revision}
  $("#sync-status").textContent = "Encrypted retained data is protected in Google app data."
  $("#sync-last").textContent = `Last synced ${new Date(body.last_synced_at).toLocaleString()}.`
  return body
}

async function mergeRemoteRecords(remoteRecords) {
  const local = await listRecords()
  const selected = syncableRecords(local)
  const selectedIds = new Set(selected.map(({id}) => id))
  const merged = mergeSyncRecords(selected, remoteRecords)
  const counts = merged.reduce((result, record) => ({...result, [record.type]: (result[record.type] || 0) + 1}), {})
  if (!confirm(`Restore these encrypted categories on this device? ${Object.entries(counts).map(([type, count]) => `${type}: ${count}`).join(", ") || "No retained records"}`)) return false
  await replaceRecords([...local.filter((record) => !selectedIds.has(record.id)), ...merged])
  await renderLocalViews(); await renderDataInventory()
  return true
}

async function restoreFromGoogle(automatic = false) {
  const remote = await fetchRemoteSync()
  if (remote.status === "empty") { if (!automatic) announce("No encrypted Google sync data exists yet."); return false }
  let records
  if (app.account.syncKey) {
    try { records = await decryptSyncWithKey(remote.envelope, app.account.syncKey) } catch { app.account.syncKey = null }
  }
  if (!records) {
    const unlocked = await unlockSync(remote.envelope, app.account.passphrase || requestRecoveryPassphrase())
    records = unlocked.records; app.account.syncKey = unlocked.syncKey
    if (await supportsPersistentCryptoKey().catch(() => false)) await storeSyncKey(unlocked.syncKey).catch(() => {})
  }
  if (await mergeRemoteRecords(records)) { announce("Encrypted Google data was restored and merged. Newer valid records won; deletions remained deleted."); return true }
  return false
}

async function syncNow() {
  const remote = await fetchRemoteSync()
  if (remote.status === "empty") {
    const passphrase = requestRecoveryPassphrase({confirmChoice: true})
    await uploadSync(await listRecords(), 0, passphrase)
    announce("Encrypted Google sync created. Keep your recovery passphrase safe.")
    return
  }
  let remoteRecords
  if (app.account.syncKey) {
    try { remoteRecords = await decryptSyncWithKey(remote.envelope, app.account.syncKey) } catch { app.account.syncKey = null }
  }
  if (!remoteRecords) {
    const unlocked = await unlockSync(remote.envelope, app.account.passphrase || requestRecoveryPassphrase())
    remoteRecords = unlocked.records; app.account.syncKey = unlocked.syncKey
    if (await supportsPersistentCryptoKey().catch(() => false)) await storeSyncKey(unlocked.syncKey).catch(() => {})
  }
  const passphrase = app.account.passphrase
  const local = await listRecords()
  const merged = mergeSyncRecords(syncableRecords(local), remoteRecords)
  if (!confirm(`Merge ${merged.length} retained records and replace revision ${remote.revision}?`)) return
  try { await uploadSync([...local.filter((record) => !new Set(syncableRecords(local).map(({id}) => id)).has(record.id)), ...merged], remote.revision, passphrase); announce("Encrypted Google sync is current.") }
  catch (error) { if (error.message === "sync_conflict") { announce("A newer copy exists. Restore and review it before retrying."); const restored = await restoreFromGoogle(); if (restored && confirm("The newer copy was merged. Retry encrypted sync now?")) { await uploadSync(await listRecords(), app.account.revision, app.account.passphrase); announce("Encrypted Google sync is current.") } } else throw error }
}

async function maybeAutoSync() {
  const enabled = (await getRecord("settings:auto-sync"))?.value.enabled === true
  if (!enabled || !app.account.connected) return
  if (!app.account.passphrase && !app.account.syncKey) { $("#sync-status").textContent = "New saved data is waiting. Use Sync now to unlock encrypted sync for this browser session."; return }
  await syncNow().catch(() => { $("#sync-status").textContent = "Local changes are waiting for a manual sync." })
}

async function offerContinuity() {
  if (!app.account.available || app.account.connected) return
  const dismissed = await getRecord("settings:continuity-suggestion")
  if (!dismissed?.value.dismissed) $("#continuity-suggestion").hidden = false
}

async function replaceWithSyncTombstones(before, after) {
  const remaining = new Set(after.map(({id}) => id))
  const tombstones = syncableRecords(before).filter(({id}) => !remaining.has(id)).map((record) => tombstoneFor(record, now()))
  await replaceRecords([...after, ...tombstones])
  await maybeAutoSync()
}

DOORS.forEach((door) => { const button = document.createElement("button"); button.className = "door"; button.type = "button"; button.dataset.door = door.value; button.setAttribute("aria-pressed", "false"); const mark = document.createElement("i"); mark.className = "door-mark"; mark.setAttribute("aria-hidden", "true"); const title = document.createElement("strong"); title.textContent = door.label; const description = document.createElement("span"); description.textContent = door.description; button.append(mark, title, description); button.addEventListener("click", () => { app.selectedDoor = door.label; updateDoorLabels(); document.querySelectorAll(".door").forEach((node) => node.setAttribute("aria-pressed", String(node === button))); $("#join-queue").disabled = false }); $("#doors").append(button) })
document.addEventListener("click", (event) => { const target = event.target.closest("[data-go]"); if (target) show(target.dataset.go) })
$("#join-queue").addEventListener("click", async () => { const payload = queuePayloadFor(app.selectedDoor); if (!payload) return announce("Choose a valid Door."); try { await push(app.participant, "queue:join", payload); show("queue") } catch { announce("Could not join the queue.") } })
$("#leave-queue").addEventListener("click", async () => { await push(app.participant, "queue:leave"); show("doors") })
$("#message-form").addEventListener("submit", async (event) => { event.preventDefault(); const input = $("#message-input"); const content = input.value.trim(); if (!content) return; const message_id = crypto.randomUUID(); renderMessage({message_id, content, status: "sending", sent_at: now()}, true); input.value = ""; try { updateMessageStatus(await push(app.conversation, "message:send", {message_id, content})) } catch { updateMessageStatus({message_id, status: "failed"}) } })
$("#message-input").addEventListener("input", () => { push(app.conversation, "typing:start").catch(() => {}); clearTimeout(app.typingTimer); app.typingTimer = setTimeout(() => push(app.conversation, "typing:stop").catch(() => {}), 1500) })
$("#voice-start").addEventListener("click", requestVoiceRecording)
$("#voice-warning-help").addEventListener("click", () => { $("#voice-warning").hidden = false })
$("#voice-warning-cancel").addEventListener("click", () => { $("#voice-warning").hidden = true })
$("#voice-warning-continue").addEventListener("click", async () => { await putRecord({id: "settings:voice-warning:v1", type: "settings", value: {voice_warning_version: VOICE_WARNING_VERSION}, updated_at: now()}); await startVoiceRecording() })
$("#voice-stop").addEventListener("click", () => { if (app.voice.recorder?.state === "recording") app.voice.recorder.stop() })
$("#voice-record-cancel").addEventListener("click", cancelRecording)
$("#voice-preview-cancel").addEventListener("click", clearVoicePreview)
$("#voice-rerecord").addEventListener("click", startVoiceRecording)
$("#voice-send").addEventListener("click", sendVoicePreview)
$("#message-viewport").addEventListener("scroll", () => { app.timelinePinned = timelineNearBottom(); if (app.timelinePinned) $("#new-messages").hidden = true })
$("#new-messages").addEventListener("click", () => scrollTimelineToNewest({smooth: true}))
window.visualViewport?.addEventListener("resize", () => { if (app.timelinePinned) scrollTimelineToNewest() })
$("#end-conversation").addEventListener("click", async () => { if (confirm("End this conversation for both people?")) await push(app.conversation, "conversation:end") })
$("#keep-conversation").addEventListener("click", () => applyRetention("kept").catch(() => announce("Could not keep this local copy.")))
$("#summary-choice-form").addEventListener("submit", (event) => { event.preventDefault(); applyRetention("summary_only", $("#summary-choice-text").value).catch(() => announce("Enter and save a summary before removing the transcript.")) })
$("#fade-conversation").addEventListener("click", () => applyRetention("faded").catch(() => announce("Could not clear this local copy.")))
$("#report-open").addEventListener("click", () => { $("#report-form").hidden = false; $("#report-category").focus() })
$("#report-form").addEventListener("submit", async (event) => { event.preventDefault(); const category = $("#report-category").value; if (!category) return; await push(app.conversation, "conversation:report", {category, evidence: $("#report-evidence").value || null}); event.target.hidden = true; announce("Report submitted for pending review.") })
$("#block").addEventListener("click", async () => { if (confirm("Block this person from future matches? Reporting is separate.")) { await push(app.conversation, "conversation:block"); announce("This person is blocked from future matching.") } })
$("#consent").addEventListener("click", async () => { const result = await push(app.conversation, "relationship:consent"); $("#consent-status").textContent = result.status === "created" ? "Bond created." : "Waiting for mutual consent."; if (result.relationship_id) rememberRelationship(result.relationship_id) })
$("#history-summary-form").addEventListener("submit", async (event) => { event.preventDefault(); const text = $("#history-summary").value.trim(); const summaryId = `summary:${app.historyConversationId}`; if (text) await putRecord({id: summaryId, type: "summary", value: {conversation_id: app.historyConversationId, text}, updated_at: now()}); else { const prior = await getRecord(summaryId); if (prior) await putRecord(tombstoneFor(prior, now())) } const conversation = await getRecord(`conversation:${app.historyConversationId}`); await putRecord({...conversation, value: {...conversation.value, summary_id: text ? summaryId : null}, updated_at: now()}); await maybeAutoSync(); announce("Local summary updated.") })
$("#history-memory").addEventListener("click", async () => { const text = prompt("Memory to save separately on this device:"); if (text?.trim()) { await putRecord({id: `memory:${crypto.randomUUID()}`, type: "memory", value: {text: text.trim(), conversation_id: app.historyConversationId}, updated_at: now()}); await offerContinuity(); await maybeAutoSync(); announce("Memory saved separately.") } })
$("#history-delete").addEventListener("click", async () => { if (!confirm("Delete this kept local conversation and transcript?")) return; const records = await listRecords(); const hasSummary = records.some(({id}) => id === `summary:${app.historyConversationId}`); const deleteSummary = hasSummary && confirm("Also delete its associated summary? Separate Memories will remain."); await replaceWithSyncTombstones(records, deleteKeptConversation(records, app.historyConversationId, {deleteSummary})); releaseAllVoiceUrls(); show("chats") })
$("#delete-kept-all").addEventListener("click", async () => { if (!confirm("Delete all kept local conversations and transcripts?")) return; const records = await listRecords(); const hasSummaries = keptConversations(records).some(({value}) => records.some(({id}) => id === `summary:${value.conversation_id}`)); const deleteSummaries = hasSummaries && confirm("Also delete their associated summaries? Separate Memories will remain."); await replaceWithSyncTombstones(records, deleteAllKeptConversations(records, {deleteSummaries})); releaseAllVoiceUrls(); renderChats() })
$("#memory-form").addEventListener("submit", async (event) => { event.preventDefault(); const text = $("#memory-note").value.trim(); if (!text) return; await putRecord({id: `memory:${crypto.randomUUID()}`, type: "memory", value: {text}, updated_at: now()}); event.target.reset(); renderLocalViews(); await offerContinuity(); await maybeAutoSync() })
$("#reduced-motion").addEventListener("change", async (event) => { document.body.classList.toggle("reduce-motion", event.target.checked); await putRecord({id: "settings:privacy", type: "settings", value: {reduced_motion: event.target.checked}, updated_at: now()}) })
$("#view-data").addEventListener("click", renderDataInventory)
$("#delete-all").addEventListener("click", async () => { if (!confirm("Delete all local StrangerTalks data from this browser? This cannot be undone without an exported backup.")) return; await clearRecords(); releaseAllVoiceUrls(); clearVoicePreview(); app.socket?.disconnect(); app.identity = null; await createIdentity(false); connectSocket(); renderLocalViews(); renderDataInventory(); announce("All prior local data was deleted. A new anonymous identity was created.") })
$("#export-data").addEventListener("click", async () => { const passphrase = prompt("Choose a backup passphrase. It cannot be recovered if lost."); if (!passphrase) return; const envelope = await encryptBackup(await listRecords(), passphrase); const link = document.createElement("a"); link.href = URL.createObjectURL(new Blob([JSON.stringify(envelope)], {type: "application/json"})); link.download = `strangertalks-backup-${now().slice(0, 10)}.json`; link.click(); URL.revokeObjectURL(link.href); announce("Encrypted backup exported. Keep its passphrase safe.") })
$("#import-data").addEventListener("change", async (event) => { const file = event.target.files[0]; if (!file) return; const passphrase = prompt("Enter this backup’s passphrase."); if (!passphrase) return; try { await importRecords(await decryptBackup(JSON.parse(await file.text()), passphrase)); await renderLocalViews(); await renderDataInventory(); announce("Backup merged. Newer records won for matching stable IDs.") } catch { announce("Backup could not be opened. Check the file and passphrase.") } finally { event.target.value = "" } })
$("#account-link").addEventListener("click", () => startGoogle("link").catch(() => announce("Private Google connection could not start.")))
$("#account-login").addEventListener("click", () => startGoogle("login").catch(() => announce("Private Google sign-in could not start.")))
$("#suggest-connect").addEventListener("click", () => startGoogle("link").catch(() => announce("Private Google connection could not start.")))
$("#suggest-dismiss").addEventListener("click", async () => { await putRecord({id: "settings:continuity-suggestion", type: "settings", value: {dismissed: true}, updated_at: now()}); $("#continuity-suggestion").hidden = true })
$("#sync-now").addEventListener("click", () => syncNow().catch((error) => announce(error.message === "passphrase_mismatch" ? "Recovery passphrases did not match." : error.message === "google_reauthorization_required" ? "Google needs to be connected again. Local data was not changed." : "Encrypted sync could not complete.")))
$("#sync-restore").addEventListener("click", () => restoreFromGoogle().catch((error) => announce(error.message === "google_reauthorization_required" ? "Google needs to be connected again. Local data was not changed." : "Encrypted data could not be restored. Check the recovery passphrase.")))
$("#auto-sync").addEventListener("change", async (event) => { await putRecord({id: "settings:auto-sync", type: "settings", value: {enabled: event.target.checked}, updated_at: now()}); announce(event.target.checked ? "Automatic protection is enabled after encrypted sync is unlocked in this browser session." : "Automatic protection is off.") })
$("#sync-delete").addEventListener("click", async () => { if (!confirm("Permanently delete only the encrypted StrangerTalks sync file from Google app data? Local browser data and your private connection will remain.")) return; const response = await accountFetch("/api/account/sync", {method: "DELETE"}); if (response.ok) { app.account.revision = 0; $("#sync-status").textContent = "Encrypted Google sync data was deleted. Local data remains."; announce("Google sync data deleted; this device was not changed.") } })
$("#account-logout").addEventListener("click", async () => { if (!confirm("Sign out only this device? Local browser data remains.")) return; await accountFetch("/api/account/session", {method: "DELETE"}); location.reload() })
$("#account-logout-all").addEventListener("click", async () => { if (!confirm("Sign out every connected device? Local and Google sync data remain.")) return; await accountFetch("/api/account/sessions", {method: "DELETE"}); location.reload() })
$("#account-disconnect").addEventListener("click", async () => { if (!confirm("Disconnect Google and sign out all devices? Bonds and local data remain. Google sync data is not deleted.")) return; await accountFetch("/api/account/google-link", {method: "DELETE"}); location.reload() })

renderLocalViews().catch(() => {})
app.voice.mediaType = selectVoiceMediaType(globalThis.MediaRecorder)
if (!app.voice.mediaType || !navigator.mediaDevices?.getUserMedia) { $("#voice-start").disabled = true; $("#voice-unavailable").hidden = false; $("#voice-unavailable").textContent = "Voice recording is unavailable in this browser. Text messaging still works." }
bootstrap().then(async () => { const settings = await getRecord("settings:privacy"); if (settings?.value.reduced_motion) { $("#reduced-motion").checked = true; document.body.classList.add("reduce-motion") } const accountResult = new URLSearchParams(location.search).get("account"); if (accountResult === "connected" && app.account.connected) await restoreFromGoogle(true).catch(() => announce("Connected privately. Unlock encrypted sync from You when you are ready.")); if (accountResult) history.replaceState({}, "", "/") }).catch(() => announce("StrangerTalks could not start. Please reload."))
