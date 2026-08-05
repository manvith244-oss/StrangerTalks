import {Socket} from "/vendor/phoenix.mjs"
import {DOORS, backendDoorFor} from "./door_mapping.mjs"

const identityKey = "strangertalks.identity.v1"
const app = {identity: null, socket: null, participant: null, conversation: null, conversationId: null, selectedDoor: null, rendered: new Set(), typingTimer: null}
const $ = (selector) => document.querySelector(selector)

function announce(message) { $("#status").textContent = message }
function show(name) { document.querySelectorAll("[data-screen]").forEach((node) => node.classList.toggle("active", node.dataset.screen === name)); document.querySelector(`[data-screen="${name}"] h1`)?.focus?.() }
function push(channel, event, payload = {}) { return new Promise((resolve, reject) => channel.push(event, payload).receive("ok", resolve).receive("error", reject).receive("timeout", () => reject({reason: "timeout"}))) }

async function bootstrap() {
  const saved = localStorage.getItem(identityKey)
  if (saved) app.identity = JSON.parse(saved)
  if (!app.identity) await createIdentity(false)
  connectSocket()
}

async function createIdentity(replacing) {
  if (replacing) announce("Your previous anonymous identity is unavailable. Creating a new one.")
  const response = await fetch("/api/participants", {method: "POST", headers: {"content-type": "application/json"}, body: "{}"})
  if (!response.ok) throw new Error("participant bootstrap failed")
  app.identity = await response.json()
  localStorage.setItem(identityKey, JSON.stringify(app.identity))
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
  localStorage.removeItem(identityKey)
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
}

function updateMessageStatus({message_id, status}) { document.querySelector(`[data-message-id="${CSS.escape(message_id)}"] small`)?.replaceChildren(document.createTextNode(status)) }
function rememberRelationship(id) { const ids = JSON.parse(localStorage.getItem("strangertalks.relationships.v1") || "[]"); if (!ids.includes(id)) ids.push(id); localStorage.setItem("strangertalks.relationships.v1", JSON.stringify(ids)); renderLocalViews() }
function renderLocalViews() { const ids = JSON.parse(localStorage.getItem("strangertalks.relationships.v1") || "[]"); $("#relationship-list").textContent = ids.length ? `${ids.length} mutual relationship${ids.length === 1 ? "" : "s"} stored locally.` : "No mutual relationships saved on this device."; $("#memory-list").textContent = "No local memories saved yet." }

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
$("#reduced-motion").addEventListener("change", (event) => document.body.classList.toggle("reduce-motion", event.target.checked))

renderLocalViews()
bootstrap().catch(() => announce("StrangerTalks could not start. Please reload."))
