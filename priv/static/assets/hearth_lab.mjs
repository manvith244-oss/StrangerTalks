import {Socket} from "/vendor/phoenix.mjs"

const $ = (id) => document.getElementById(id)
const screens = ["hearth-screen", "bridge-screen", "room-screen", "feedback-screen"]

const state = {
  socket: null,
  channel: null,
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
  $("room-own-anchor").textContent = state.ownAnchor
  $("room-partner-anchor").textContent = state.partnerAnchor
  $("messages").replaceChildren()
  show("room-screen")
  $("message-input").focus()
}

function returnToHearth(message = "") {
  state.bridgeId = null
  state.roomId = null
  setStatus("hearth-status", message)
  show("hearth-screen")
}

function showFeedback() {
  state.roomId = null
  show("feedback-screen")
}

async function bootstrap() {
  const response = await fetch("/api/participants", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: "{}"
  })

  if (!response.ok) throw new Error("participant_issuance_failed")
  const identity = await response.json()

  const socket = new Socket("/socket", {
    authToken: () => identity.token,
    timeout: 5000,
    reconnectAfterMs: () => 500,
    rejoinAfterMs: () => 500
  })

  state.socket = socket
  socket.connect()

  const channel = socket.channel(`hearth:${identity.participant_id}`, {})
  state.channel = channel

  channel.on("bridge:offered", enterBridge)
  channel.on("bridge:dissolved", () => returnToHearth("The moment passed. You can place another thing here."))
  channel.on("hearth:reset", () => returnToHearth("That moment dissolved. You can try again."))
  channel.on("room:ready", enterRoom)
  channel.on("room:message", ({room_id: roomId, content}) => {
    if (roomId === state.roomId && typeof content === "string") appendMessage("them", content)
  })
  channel.on("room:partner_disconnected", ({room_id: roomId}) => {
    if (roomId === state.roomId) showFeedback()
  })

  channel.join(5000)
    .receive("ok", (payload) => {
      renderRecent(payload.recent)
      setStatus("hearth-status", "")
    })
    .receive("error", () => {
      setStatus("hearth-status", "This lab is not available right now.")
    })
    .receive("timeout", () => {
      setStatus("hearth-status", "Could not open the Hearth.")
    })
}

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
    state.ownAnchor = contribution
    if (reply.status === "waiting") setStatus("hearth-status", "Your thought is here. Someone may cross your path.")
  } catch (error) {
    setStatus("hearth-status", error?.reason === "capacity" ? "The Hearth is full right now." : "That could not be placed here.")
  }
})

$("step-in").addEventListener("click", async () => {
  if (!state.bridgeId) return
  setStatus("bridge-status", "Waiting for them to step in too…")
  try {
    await push("bridge:step_in", {bridge_id: state.bridgeId})
  } catch {
    returnToHearth("That moment passed.")
  }
})

$("pass").addEventListener("click", async () => {
  if (!state.bridgeId) returnToHearth()
  try { await push("bridge:pass", {bridge_id: state.bridgeId}) } catch {}
  returnToHearth()
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
  returnToHearth("Thanks. The next encounter starts clean.")
})

$("close-feedback").addEventListener("click", () => returnToHearth())

bootstrap().catch(() => setStatus("hearth-status", "This lab could not start."))
