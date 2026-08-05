import {Socket} from "/vendor/phoenix.mjs"
import {DOORS, backendDoorFor} from "./door_mapping.mjs"
import {clearRecords, decryptBackup, deleteRecord, encryptBackup, getRecord, importRecords, listRecords, putRecord} from "./local_data.mjs"

const identityKey = "strangertalks.identity.v1"
const app = {identity: null, socket: null, participant: null, conversation: null, conversationId: null, selectedDoor: null, rendered: new Set(), typingTimer: null}
const $ = (selector) => document.querySelector(selector)

function announce(message) { $("#status").textContent = message }
function show(name) { document.querySelectorAll("[data-screen]").forEach((node) => node.classList.toggle("active", node.dataset.screen === name)); document.querySelector(`[data-screen="${name}"] h1`)?.focus?.() }
function push(channel, event, payload = {}) { return new Promise((resolve, reject) => channel.push(event, payload).receive("ok", resolve).receive("error", reject).receive("timeout", () => reject({reason: "timeout"}))) }

async function bootstrap() {
  const saved = await getRecord(identityKey)
  if (saved) app.identity = saved.value
  if (!app.identity) await createIdentity(false)
  connectSocket()
}

async function createIdentity(replacing) {
  if (replacing) announce("Your previous anonymous identity is unavailable. Creating a new one.")
  const response = await fetch("/api/participants", {method: "POST", headers: {"content-type": "application/json"}, body: "{}"})
  if (!response.ok) throw new Error("participant bootstrap failed")
  app.identity = await response.json()
  await putRecord({id: identityKey, type: "identity", value: app.identity, updated_at: new Date().toISOString()})
}

function connectSocket() {
  app.socket = new Socket("/socket", {params: {token: app.identity.token}})
  app.socket.onError(() => { $("#presence").textContent = "Reconnecting…"; announce("Connection interrupted. Reconnecting.") })
  app.socket.onClose(() => { if (app.conversationId) $("#presence").textContent = "Reconnecting…" })
  app.socket.connect()
  app.participant = app.socket.channel(`participant:${app.identity.participant_id}`, {})
  app.participant.on("queue:status", ({status}) => { announce(`Queue status: ${status}`); if (status === "timed_out") show("doors") })
  app.participant.on("match_found", ({conversation_id}) => { app.conversationId = conversation_id; show("match"); joinConversation(conversation_id) })
  app.participant.on("relationship:created", ({relationship_id}) => { rememberRelationship(relationship_id); $("#consent-status").textContent = "Relationship created."; announce("Mutual relationship created.") })
  app.participant.join().receive("error", recoverIdentity)
}

async function recoverIdentity() {
  await deleteRecord(identityKey)
  app.socket?.disconnect()
  await createIdentity(true)
  connectSocket()
}

function joinConversation(id) {
  app.conversation = app.socket.channel(`conversation:${id}`, {})
  app.conversation.on("conversation:presence", ({status}) => { $("#presence").textContent = status === "connected" ? "Connected" : status === "reconnecting" ? "The other person is reconnecting…" : "Disconnected" })
  app.conversation.on("typing:status", ({typing}) => { $("#typing").textContent = typing ? "The other person is typing…" : "" })
  app.conversation.on("message:new", (message) => { renderMessage(message, false); push(app.conversation, "message:ack", {message_id: message.message_id}).catch(() => {}) })
  app.conversation.on("message:status", updateMessageStatus)
  app.conversation.on("conversation:ended", () => { show("ended"); announce("Conversation ended.") })
  app.conversation.join().receive("ok", () => { show("conversation"); announce("Conversation joined.") }).receive("error", () => announce("The conversation is unavailable."))
}

function renderMessage(message, mine) {
  if (app.rendered.has(message.message_id)) return
  app.rendered.add(message.message_id)
  const item = document.createElement("li")
  item.className = `message${mine ? " mine" : ""}`
  item.dataset.messageId = message.message_id
  const content = document.createElement("span")
  content.textContent = message.content
  item.append(content)
  if (mine) { const status = document.createElement("small"); status.textContent = message.status || "sent_to_server"; item.append(status) }
  $("#messages").append(item)
  putRecord({id: `message:${app.conversationId}:${message.message_id}`, type: "message", value: {conversation_id: app.conversationId, message_id: message.message_id, content: message.content, mine, status: message.status || "delivered"}, updated_at: new Date().toISOString()}).catch(() => {})
}

function updateMessageStatus({message_id, status}) { document.querySelector(`[data-message-id="${CSS.escape(message_id)}"] small`)?.replaceChildren(document.createTextNode(status)); const id = `message:${app.conversationId}:${message_id}`; getRecord(id).then((record) => record && putRecord({...record, value: {...record.value, status}, updated_at: new Date().toISOString()})).catch(() => {}) }
async function rememberRelationship(id) { await putRecord({id: `relationship:${id}`, type: "relationship", value: {relationship_id: id, status: "created"}, updated_at: new Date().toISOString()}); renderLocalViews() }
async function renderLocalViews() { const records = await listRecords(); renderRecordList($("#memory-list"), records.filter(({type}) => type === "memory" || type === "summary")); const relationships = records.filter(({type}) => type === "relationship"); $("#relationship-list").textContent = relationships.length ? `${relationships.length} mutual relationship${relationships.length === 1 ? "" : "s"} stored locally.` : "No mutual relationships saved on this device." }
function renderRecordList(container, records) { container.replaceChildren(); if (!records.length) { container.textContent = "Nothing saved locally yet."; return } records.forEach((record) => { const article = document.createElement("article"); const text = document.createElement("p"); text.textContent = record.value.text || record.type; const remove = document.createElement("button"); remove.textContent = "Delete"; remove.addEventListener("click", async () => { await deleteRecord(record.id); renderLocalViews(); renderDataInventory() }); article.append(text, remove); container.append(article) }) }
async function renderDataInventory() { const records = await listRecords(); const container = $("#local-data-list"); container.replaceChildren(); const totals = records.reduce((counts, {type}) => ({...counts, [type]: (counts[type] || 0) + 1}), {}); const counts = Object.entries(totals).map(([type, count]) => `${type}: ${count}`); container.textContent = counts.length ? counts.join(" · ") : "No local data stored." }

DOORS.forEach((door) => { const button = document.createElement("button"); button.className = "door"; button.type = "button"; button.setAttribute("aria-pressed", "false"); const title = document.createElement("strong"); title.textContent = door.label; const description = document.createElement("span"); description.textContent = door.description; button.append(title, description); button.addEventListener("click", () => { app.selectedDoor = door.label; document.querySelectorAll(".door").forEach((node) => node.setAttribute("aria-pressed", String(node === button))); $("#join-queue").disabled = false }); $("#doors").append(button) })

document.addEventListener("click", (event) => { const target = event.target.closest("[data-go]"); if (target) show(target.dataset.go) })
$("#begin").addEventListener("click", () => show("doors"))
$("#join-queue").addEventListener("click", async () => { const door_type = backendDoorFor(app.selectedDoor); if (!door_type) return announce("Choose a valid Door."); try { await push(app.participant, "queue:join", {door_type, language: navigator.language?.split("-")[0] || "en", media_capability: 0, typing_cadence: 0.0}); show("queue") } catch { announce("Could not join the queue.") } })
$("#leave-queue").addEventListener("click", async () => { await push(app.participant, "queue:leave"); show("doors") })
$("#message-form").addEventListener("submit", async (event) => { event.preventDefault(); const input = $("#message-input"); const content = input.value.trim(); if (!content) return; const message_id = crypto.randomUUID(); renderMessage({message_id, content, status: "sending"}, true); input.value = ""; try { const result = await push(app.conversation, "message:send", {message_id, content}); updateMessageStatus(result) } catch { updateMessageStatus({message_id, status: "failed"}) } })
$("#message-input").addEventListener("input", () => { push(app.conversation, "typing:start").catch(() => {}); clearTimeout(app.typingTimer); app.typingTimer = setTimeout(() => push(app.conversation, "typing:stop").catch(() => {}), 1500) })
$("#end-conversation").addEventListener("click", async () => { if (confirm("End this conversation for both people?")) await push(app.conversation, "conversation:end") })
$("#report-open").addEventListener("click", () => { $("#report-form").hidden = false; $("#report-category").focus() })
$("#report-form").addEventListener("submit", async (event) => { event.preventDefault(); const category = $("#report-category").value; if (!category) return; await push(app.conversation, "conversation:report", {category, evidence: $("#report-evidence").value || null}); event.target.hidden = true; announce("Report submitted for pending review.") })
$("#block").addEventListener("click", async () => { if (confirm("Block this person from future matches? Reporting is a separate action.")) { await push(app.conversation, "conversation:block"); announce("This person is blocked from future matching.") } })
$("#consent").addEventListener("click", async () => { const result = await push(app.conversation, "relationship:consent"); $("#consent-status").textContent = result.status === "created" ? "Relationship created." : "Waiting for mutual consent."; if (result.relationship_id) rememberRelationship(result.relationship_id) })
$("#memory-form").addEventListener("submit", async (event) => { event.preventDefault(); const text = $("#memory-note").value.trim(); if (!text) return; await putRecord({id: `memory:${crypto.randomUUID()}`, type: "memory", value: {text}, updated_at: new Date().toISOString()}); event.target.reset(); renderLocalViews() })
$("#summary-form").addEventListener("submit", async (event) => { event.preventDefault(); const text = $("#summary-text").value.trim(); if (!text) return; await putRecord({id: `summary:${app.conversationId}`, type: "summary", value: {text, conversation_id: app.conversationId}, updated_at: new Date().toISOString()}); event.target.reset(); announce("Summary saved only on this device.") })
$("#reduced-motion").addEventListener("change", async (event) => { document.body.classList.toggle("reduce-motion", event.target.checked); await putRecord({id: "settings:privacy", type: "settings", value: {reduced_motion: event.target.checked}, updated_at: new Date().toISOString()}) })
$("#view-data").addEventListener("click", renderDataInventory)
$("#delete-all").addEventListener("click", async () => { if (!confirm("Delete all local StrangerTalks data from this browser? This cannot be undone without an exported backup.")) return; await clearRecords(); app.socket?.disconnect(); app.identity = null; await createIdentity(false); connectSocket(); renderLocalViews(); renderDataInventory(); announce("All prior local data was deleted. A new anonymous identity was created.") })
$("#export-data").addEventListener("click", async () => { const passphrase = prompt("Choose a backup passphrase. It cannot be recovered if lost."); if (!passphrase) return; const envelope = await encryptBackup(await listRecords(), passphrase); const link = document.createElement("a"); link.href = URL.createObjectURL(new Blob([JSON.stringify(envelope)], {type: "application/json"})); link.download = `strangertalks-backup-${new Date().toISOString().slice(0, 10)}.json`; link.click(); URL.revokeObjectURL(link.href); announce("Encrypted backup exported. Keep its passphrase safe.") })
$("#import-data").addEventListener("change", async (event) => { const file = event.target.files[0]; if (!file) return; const passphrase = prompt("Enter this backup’s passphrase."); if (!passphrase) return; try { const imported = await decryptBackup(JSON.parse(await file.text()), passphrase); await importRecords(imported); await renderLocalViews(); await renderDataInventory(); announce("Backup merged. Newer records won for matching stable IDs.") } catch { announce("Backup could not be opened. Check the file and passphrase.") } finally { event.target.value = "" } })

renderLocalViews().catch(() => {})
bootstrap().then(async () => { const settings = await getRecord("settings:privacy"); if (settings?.value.reduced_motion) { $("#reduced-motion").checked = true; document.body.classList.add("reduce-motion") } }).catch(() => announce("StrangerTalks could not start. Please reload."))
