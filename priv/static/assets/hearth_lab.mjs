import {Socket} from "/vendor/phoenix.mjs"

const $ = (id) => document.getElementById(id)
const screens = ["control-screen", "hearth-screen", "bridge-screen", "room-screen", "feedback-screen", "done-screen"]
const identityKey = "strangertalks-hearth-h01a-v1"

const state = {
  socket: null,
  channel: null,
  identity: null,
  variant: null,
  bridgeId: null,
  roomId: null,
  ownAnchor: "",
  partnerAnchor: ""
}

function show(id) {
  for (const screen of screens) $(screen).hidden = screen !== id
}

function setStatus(id, text) {
  $(id).textContent = text || ""
}

function renderRecent(items = []) {
  const safe = Array.isArray(items) ? items.slice(0, 3) : []
  $("recent-list").replaceChildren(...safe.map((text) => {
    const li = document.createElement("li")
    li.textContent = String(text)
    return li
  }))
  $("recent-wrap").hidden = safe.length === 0
}

function readIdentityRecord() {
  try {
    const parsed = JSON.parse(localStorage.getItem(identityKey) || "null")
    if (typeof parsed?.participant_id === "string" && typeof parsed?.token === "string") return parsed
  } catch {}
  return null
}

function writeIdentityRecord(record) {
  try { localStorage.setItem(identityKey, JSON.stringify(record)) } catch {}
}

function markAttempted() {
  if (!state.identity) return
  writeIdentityRecord({...state.identity, attempted: true})
}

async function identityForPilot() {
  const existing = readIdentityRecord()
  if (existing) return existing

  const response = await fetch("/api/hearth/participants", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: "{}"
  })

  if (!response.ok) throw new Error("participant_issuance_failed")
  const identity = await response.json()
  writeIdentityRecord({...identity, attempted: false})
  return identity
}

function push(event, payload) {
  return new Promise((resolve, reject) => {
    state.channel.push(event, payload, 5000)
      .receive("ok", resolve)
      .receive("error", reject)
      .receive("timeout", () => reject({reason: "timeout"}))
  })
}

function appendMessage(kind, content) {
  const li = document.createElement("li")
  li.className = kind === "me" ? "me" : "them"
  li.textContent = content
  $("messages").append(li)
  li.scrollIntoView({block: "nearest"})
}

function enterBridge(payload) {
  state.bridgeId = payload.bridge_id
  state.ownAnchor = payload.own_anchor || ""
  state.partnerAnchor = payload.partner_anchor || ""
  $("own-anchor").textContent = state.ownAnchor
  $("partner-anchor").textContent = state.partnerAnchor
  setStatus("bridge-status", "")
  show("bridge-screen")
}

function enterRoom(payload) {
  state.roomId = payload.room_id
  state.ownAnchor = payload.own_anchor || state.ownAnchor
  state.partnerAnchor = payload.partner_anchor || state.partnerAnchor
  const anchored = state.variant === "treatment"
  $("room-anchor").hidden = !anchored
  $("room-own-anchor").textContent = anchored ? state.ownAnchor : ""
  $("room-partner-anchor").textContent = anchored ? state.partnerAnchor : ""
  $("messages").replaceChildren()
  show("room-screen")
  $("message-input").focus()
}

function finishAttempt(message = "Thanks for taking part. This pilot allows one encounter attempt per person.") {
  markAttempted()
  state.bridgeId = null
  state.roomId = null
  state.ownAnchor = ""
  state.partnerAnchor = ""
  $("done-message").textContent = message
  show("done-screen")
  try { state.channel?.leave() } catch {}
  try { state.socket?.disconnect() } catch {}
}

function showFeedback() {
  state.roomId = null
  show("feedback-screen")
}

async function bootstrap() {
  const identity = await identityForPilot()
  state.identity = identity

  if (identity.attempted === true) {
    finishAttempt()
    return
  }

  const socket = new Socket("/hearth_socket", {
    authToken: () => identity.token,
    timeout: 5000,
    reconnectAfterMs: () => 500,
    rejoinAfterMs: () => 500
  })

  state.socket = socket
  socket.connect()

  const channel = socket.channel(`hearth:${identity.participant_id}`, {variant: "auto"})
  state.channel = channel

  channel.on("bridge:offered", enterBridge)
  channel.on("bridge:dissolved", () => finishAttempt("That moment ended. Thanks for taking part."))
  channel.on("experiment:reset", () => finishAttempt("That attempt ended. Thanks for taking part."))
  channel.on("room:ready", enterRoom)
  channel.on("room:message", ({room_id: roomId, content}) => {
    if (roomId === state.roomId && typeof content === "string") appendMessage("them", content)
  })
  channel.on("room:partner_disconnected", ({room_id: roomId}) => {
    if (roomId === state.roomId) showFeedback()
  })

  channel.join(5000)
    .receive("ok", (payload) => {
      state.variant = payload.variant

      if (payload.variant === "control") {
        setStatus("control-status", "")
        show("control-screen")
      } else {
        renderRecent(payload.recent)
        setStatus("hearth-status", "")
        show("hearth-screen")
      }
    })
    .receive("error", () => {
      document.body.textContent = "This lab is not available right now."
    })
    .receive("timeout", () => {
      document.body.textContent = "This lab could not open."
    })
}

$("control-connect").addEventListener("click", async () => {
  setStatus("control-status", "Connecting…")
  try {
    const reply = await push("control:connect", {})
    markAttempted()
    if (reply.status === "waiting") setStatus("control-status", "Waiting for someone else…")
  } catch (error) {
    if (error?.reason === "already_participated") return finishAttempt()
    setStatus("control-status", error?.reason === "capacity" ? "No room right now." : "Could not connect.")
  }
})

$("hearth-input").addEventListener("input", (event) => {
  $("char-count").textContent = String(event.target.value.length)
})

$("hearth-form").addEventListener("submit", async (event) => {
  event.preventDefault()
  const contribution = $("hearth-input").value.trim()
  if (!contribution) return

  setStatus("hearth-status", "Standing near the Hearth…")

  try {
    const reply = await push("hearth:submit", {contribution})
    markAttempted()
    state.ownAnchor = contribution
    if (reply.status === "waiting") setStatus("hearth-status", "Your thought is here. Someone may cross your path.")
  } catch (error) {
    if (error?.reason === "already_participated") return finishAttempt()
    setStatus("hearth-status", error?.reason === "capacity" ? "The Hearth is full right now." : "That could not be placed here.")
  }
})

$("step-in").addEventListener("click", async () => {
  if (!state.bridgeId) return
  setStatus("bridge-status", "Waiting for them to step in too…")
  try {
    await push("bridge:step_in", {bridge_id: state.bridgeId})
  } catch {
    finishAttempt("That moment ended. Thanks for taking part.")
  }
})

$("pass").addEventListener("click", async () => {
  if (state.bridgeId) {
    try { await push("bridge:pass", {bridge_id: state.bridgeId}) } catch {}
  }
  finishAttempt()
})

$("message-form").addEventListener("submit", async (event) => {
  event.preventDefault()
  const input = $("message-input")
  const content = input.value.trim()
  if (!content || !state.roomId) return

  try {
    await push("room:message", {room_id: state.roomId, content})
    appendMessage("me", content)
    input.value = ""
  } catch (error) {
    if (error?.reason === "no_room") showFeedback()
  }
})

$("leave-room").addEventListener("click", async () => {
  if (state.roomId) {
    try { await push("room:leave", {room_id: state.roomId}) } catch {}
  }
  showFeedback()
})

$("feedback-actions").addEventListener("click", async (event) => {
  const reason = event.target?.dataset?.reason
  if (!reason) return
  try { await push("experiment:feedback", {reason}) } catch {}
  finishAttempt()
})

$("close-feedback").addEventListener("click", () => finishAttempt())

bootstrap().catch(() => {
  document.body.textContent = "This lab could not start."
})
