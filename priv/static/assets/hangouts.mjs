export const HANGOUTS_PHASES = Object.freeze({
  ENTRY: "ENTRY",
  WAITING: "WAITING",
  ROOM: "ROOM",
  RECONNECTING: "RECONNECTING",
  ENDED: "ENDED"
})

export const REPORT_CATEGORIES = Object.freeze([
  "harassment",
  "sexual_content",
  "hate",
  "threat",
  "spam_scam",
  "personal_information",
  "other"
])

export const CANONICAL_REACTIONS = Object.freeze(["🔥", "💡", "❤️", "😂"])

export function isTreatmentArm(experimentArm) {
  return experimentArm === "GROUP_WITH_CONTENT"
}

export function createHangoutState(initial = {}) {
  return {
    phase: HANGOUTS_PHASES.ENTRY,
    mode: "hangout",
    language_tag: "en",
    queue_status: "idle",
    queue_attempt_id: null,
    room_id: null,
    room_snapshot: null,
    current_content: null,
    messages: [],
    reactions: {},
    skip_status: {votes: 0, required: 0},
    connectivity: "connected",
    error: null,
    ...initial
  }
}

export function hangoutReducer(state, action) {
  if (!action || !action.type) return state

  if (state.phase === HANGOUTS_PHASES.ENDED && action.type !== "RESET" && action.type !== "SELECT_LANGUAGE") {
    return state
  }

  switch (action.type) {
    case "SELECT_LANGUAGE":
      return {
        ...state,
        language_tag: action.language_tag || state.language_tag
      }

    case "QUEUE_ENTER":
      return {
        ...state,
        phase: HANGOUTS_PHASES.WAITING,
        queue_status: "queued",
        queue_attempt_id: action.queue_attempt_id || null,
        language_tag: action.language_tag || state.language_tag,
        error: null
      }

    case "QUEUE_CANCEL":
      return {
        ...state,
        phase: HANGOUTS_PHASES.ENTRY,
        queue_status: "idle",
        queue_attempt_id: null,
        error: null
      }

    case "ROOM_FORMED":
      return {
        ...state,
        room_id: action.room_id,
        queue_status: "formed"
      }

    case "ROOM_SNAPSHOT": {
      const snapshot = action.snapshot
      if (!snapshot) return state

      const isTerminal = snapshot.status === "ENDED"
      const treatment = isTreatmentArm(snapshot.experiment_arm)

      return {
        ...state,
        phase: isTerminal ? HANGOUTS_PHASES.ENDED : HANGOUTS_PHASES.ROOM,
        room_id: snapshot.room_id,
        room_snapshot: snapshot,
        current_content: treatment ? (snapshot.current_content || null) : null,
        messages: Array.isArray(snapshot.messages) ? [...snapshot.messages] : [],
        reactions: treatment ? (snapshot.reactions || {}) : {},
        skip_status: treatment
          ? (snapshot.skip_status || {votes: snapshot.skip_votes_count || 0, required: snapshot.skip_quorum || 0})
          : {votes: 0, required: 0},
        connectivity: "connected",
        error: null
      }
    }

    case "MESSAGE_ACCEPTED": {
      const msg = action.message
      if (!msg) return state

      const exists = state.messages.some(
        (m) => (msg.sequence && m.sequence === msg.sequence) || (msg.client_message_id && m.client_message_id === msg.client_message_id)
      )

      if (exists) {
        const updated = state.messages.map((m) => {
          if ((msg.sequence && m.sequence === msg.sequence) || (msg.client_message_id && m.client_message_id === msg.client_message_id)) {
            return {...m, ...msg}
          }
          return m
        })
        return {...state, messages: updated}
      }

      const nextMessages = [...state.messages, msg].sort((a, b) => (a.sequence || 0) - (b.sequence || 0))
      return {...state, messages: nextMessages}
    }

    case "CONTENT_ACTIVATED":
    case "CONTENT_ADVANCED": {
      const isTreatment = state.room_snapshot ? isTreatmentArm(state.room_snapshot.experiment_arm) : true
      if (!isTreatment) return state

      return {
        ...state,
        current_content: action.content || null,
        reactions: {},
        skip_status: {votes: 0, required: 0}
      }
    }

    case "REACTIONS_UPDATED": {
      const isTreatment = state.room_snapshot ? isTreatmentArm(state.room_snapshot.experiment_arm) : true
      if (!isTreatment) return state

      return {
        ...state,
        reactions: action.reactions || {}
      }
    }

    case "SKIP_UPDATED": {
      const isTreatment = state.room_snapshot ? isTreatmentArm(state.room_snapshot.experiment_arm) : true
      if (!isTreatment) return state

      return {
        ...state,
        skip_status: action.skip_status || {votes: 0, required: 0}
      }
    }

    case "MEMBER_JOINED":
    case "MEMBER_UPDATED":
    case "MEMBER_LEFT": {
      if (!state.room_snapshot) return state
      const updatedMembers = action.members || state.room_snapshot.members
      return {
        ...state,
        room_snapshot: {
          ...state.room_snapshot,
          members: updatedMembers
        }
      }
    }

    case "SOCKET_DISCONNECTED": {
      if (state.phase === HANGOUTS_PHASES.ROOM) {
        return {
          ...state,
          phase: HANGOUTS_PHASES.RECONNECTING,
          connectivity: "disconnected"
        }
      }
      return {...state, connectivity: "disconnected"}
    }

    case "SOCKET_RECONNECTED": {
      if (state.phase === HANGOUTS_PHASES.RECONNECTING) {
        return {
          ...state,
          phase: HANGOUTS_PHASES.ROOM,
          connectivity: "connected"
        }
      }
      return {...state, connectivity: "connected"}
    }

    case "ROOM_ENDED":
      return {
        ...state,
        phase: HANGOUTS_PHASES.ENDED,
        connectivity: "connected"
      }

    case "SET_ERROR":
      return {
        ...state,
        error: action.error || null
      }

    case "RESET":
      return createHangoutState({language_tag: state.language_tag})

    default:
      return state
  }
}

export function formatMessageIntent(body) {
  const clientMessageId = typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : "msg-" + Math.random().toString(36).slice(2, 11)

  return {
    client_message_id: clientMessageId,
    body: String(body || "").trim()
  }
}

export function formatReactionIntent(expectedContentSequence, reaction) {
  return {
    expected_content_sequence: Number(expectedContentSequence),
    reaction: String(reaction)
  }
}

export function formatSkipIntent(expectedContentSequence) {
  return {
    expected_content_sequence: Number(expectedContentSequence)
  }
}

export function formatBlockIntent(targetIdentitySlot) {
  return {
    target_identity_slot: Number(targetIdentitySlot)
  }
}

export function formatReportIntent(targetIdentitySlot, category, evidence = null) {
  if (!REPORT_CATEGORIES.includes(category)) {
    throw new Error(`invalid_category: ${category}. Allowed: ${REPORT_CATEGORIES.join(", ")}`)
  }

  const clientReportId = typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : "rep-" + Math.random().toString(36).slice(2, 11)

  return {
    client_report_id: clientReportId,
    target_identity_slot: Number(targetIdentitySlot),
    category,
    evidence: evidence ? String(evidence).slice(0, 4096) : null
  }
}

/**
 * Hangout Client Runtime
 */
export function createHangoutClient({
  getSocket,
  getParticipantId,
  presentScreen,
  announce
}) {
  let state = createHangoutState()
  let lobbyChannel = null
  let roomChannel = null

  function dispatch(action) {
    state = hangoutReducer(state, action)
    render(state)
    return state
  }

  function render(s) {
    if (typeof document === "undefined") return

    // Screen visibility
    const phaseToScreen = {
      [HANGOUTS_PHASES.ENTRY]: "hangout-entry",
      [HANGOUTS_PHASES.WAITING]: "hangout-waiting",
      [HANGOUTS_PHASES.ROOM]: "hangout-room",
      [HANGOUTS_PHASES.RECONNECTING]: "hangout-room",
      [HANGOUTS_PHASES.ENDED]: "hangout-ended"
    }

    const currentScreen = phaseToScreen[s.phase]
    if (currentScreen && typeof presentScreen === "function") {
      presentScreen(currentScreen)
    }

    // Reconnecting banner
    const reconnectBanner = document.getElementById("hangout-reconnecting-banner")
    if (reconnectBanner) {
      reconnectBanner.hidden = s.phase !== HANGOUTS_PHASES.RECONNECTING
    }

    // Waiting phase text
    const waitingStatus = document.getElementById("hangout-waiting-status")
    if (waitingStatus && s.phase === HANGOUTS_PHASES.WAITING) {
      waitingStatus.textContent = `Finding participants for ${s.language_tag} group…`
    }

    // Roster rendering in Room
    const roster = document.getElementById("hangout-roster")
    if (roster && s.room_snapshot?.members) {
      roster.replaceChildren()
      for (const member of s.room_snapshot.members) {
        const badge = document.createElement("span")
        badge.className = `hangout-member-badge${member.self ? " self" : ""}${member.status !== "ACTIVE" ? " inactive" : ""}`
        badge.dataset.slot = String(member.identity.slot)
        badge.textContent = `${member.identity.emoji} ${member.identity.label}${member.self ? " (You)" : ""}`
        roster.append(badge)
      }
    }

    // Treatment stimulus card
    const stimulus = document.getElementById("hangout-stimulus")
    const isTreatment = isTreatmentArm(s.room_snapshot?.experiment_arm)
    if (stimulus) {
      if (isTreatment && s.current_content) {
        stimulus.hidden = false
        const title = document.getElementById("hangout-stimulus-title")
        const text = document.getElementById("hangout-stimulus-text")
        if (title) title.textContent = s.current_content.title || "Group Topic"
        if (text) text.textContent = s.current_content.text || ""

        // Reactions
        const reactionsContainer = document.getElementById("hangout-reactions")
        if (reactionsContainer) {
          reactionsContainer.replaceChildren()
          for (const emoji of CANONICAL_REACTIONS) {
            const btn = document.createElement("button")
            btn.type = "button"
            btn.className = "hangout-reaction-btn"
            btn.dataset.reaction = emoji
            const count = s.reactions[emoji] || 0
            btn.textContent = `${emoji} ${count > 0 ? count : ""}`
            btn.setAttribute("aria-label", `React ${emoji}${count > 0 ? ` (${count})` : ""}`)
            btn.addEventListener("click", () => handleReact(emoji))
            reactionsContainer.append(btn)
          }
        }

        // Skip button
        const skipBtn = document.getElementById("hangout-skip-btn")
        const skipCount = document.getElementById("hangout-skip-count")
        const skipReq = document.getElementById("hangout-skip-required")
        if (skipCount) skipCount.textContent = String(s.skip_status.votes || 0)
        if (skipReq) skipReq.textContent = String(s.skip_status.required || 0)
        if (skipBtn) {
          skipBtn.hidden = false
        }
      } else {
        stimulus.hidden = true
      }
    }

    // Messages rendering
    const msgList = document.getElementById("hangout-messages")
    if (msgList) {
      msgList.replaceChildren()
      for (const msg of s.messages) {
        const li = document.createElement("li")
        const mySlot = s.room_snapshot?.members?.find((m) => m.self)?.identity?.slot
        const isMine = msg.sender?.slot === mySlot
        li.className = `hangout-message${isMine ? " mine" : ""}`
        li.dataset.sequence = String(msg.sequence || "")

        const header = document.createElement("div")
        header.className = "hangout-message-author"
        header.textContent = msg.sender ? `${msg.sender.emoji} ${msg.sender.label}` : "Group member"

        const body = document.createElement("div")
        body.className = "hangout-message-body"
        body.textContent = msg.body

        li.append(header, body)
        msgList.append(li)
      }

      const viewport = document.getElementById("hangout-message-viewport")
      if (viewport) {
        viewport.scrollTop = viewport.scrollHeight
      }
    }
  }

  function getLobby() {
    const socket = getSocket()
    const participantId = getParticipantId()
    if (!socket || !participantId) return null

    if (!lobbyChannel) {
      lobbyChannel = socket.channel(`hangout_lobby:${participantId}`, {})
      lobbyChannel.on("room:formed", (payload) => {
        if (payload?.room_id) {
          dispatch({type: "ROOM_FORMED", room_id: payload.room_id})
          joinRoom(payload.room_id)
        }
      })
      lobbyChannel.on("queue:status", (payload) => {
        if (payload?.status === "formed" && payload?.room_id) {
          dispatch({type: "ROOM_FORMED", room_id: payload.room_id})
          joinRoom(payload.room_id)
        }
      })
      lobbyChannel.join()
        .receive("ok", () => {})
        .receive("error", (resp) => {
          if (typeof announce === "function") announce("Failed to connect to Hangout lobby")
        })
    }
    return lobbyChannel
  }

  async function joinQueue(languageTag) {
    const lobby = getLobby()
    if (!lobby) return

    const tag = String(languageTag || "en").trim()
    dispatch({type: "SELECT_LANGUAGE", language_tag: tag})

    lobby.push("queue:join", {language_tag: tag})
      .receive("ok", (reply) => {
        dispatch({
          type: "QUEUE_ENTER",
          queue_attempt_id: reply.queue_attempt_id,
          language_tag: tag
        })
      })
      .receive("error", (err) => {
        const reason = err?.reason || "Could not join hangout queue"
        if (typeof announce === "function") announce(reason)
      })
  }

  async function leaveQueue() {
    if (!lobbyChannel) return
    lobbyChannel.push("queue:cancel", {})
      .receive("ok", () => {
        dispatch({type: "QUEUE_CANCEL"})
      })
      .receive("error", () => {
        dispatch({type: "QUEUE_CANCEL"})
      })
  }

  function joinRoom(roomId) {
    const socket = getSocket()
    if (!socket || !roomId) return

    if (roomChannel) {
      roomChannel.leave()
      roomChannel = null
    }

    roomChannel = socket.channel(`hangout:${roomId}`, {})

    roomChannel.on("room:activated", (snapshot) => {
      dispatch({type: "ROOM_SNAPSHOT", snapshot})
    })

    roomChannel.on("message:accepted", (payload) => {
      dispatch({type: "MESSAGE_ACCEPTED", message: payload})
    })

    roomChannel.on("content:activated", (payload) => {
      dispatch({type: "CONTENT_ACTIVATED", content: payload?.content})
    })

    roomChannel.on("content:advanced", (payload) => {
      dispatch({type: "CONTENT_ADVANCED", content: payload?.content})
    })

    roomChannel.on("reaction:added", (payload) => {
      dispatch({type: "REACTIONS_UPDATED", reactions: payload?.reactions})
    })

    roomChannel.on("content:skip_voted", (payload) => {
      dispatch({type: "SKIP_UPDATED", skip_status: payload?.skip_status})
    })

    roomChannel.on("member:joined", (payload) => {
      dispatch({type: "MEMBER_JOINED", members: payload?.members})
    })

    roomChannel.on("member:left", (payload) => {
      dispatch({type: "MEMBER_LEFT", members: payload?.members})
    })

    roomChannel.on("room:ended", () => {
      dispatch({type: "ROOM_ENDED"})
    })

    roomChannel.join()
      .receive("ok", (snapshot) => {
        dispatch({type: "ROOM_SNAPSHOT", snapshot})
      })
      .receive("error", (err) => {
        if (err?.reason === "hangout_ended") {
          dispatch({type: "ROOM_ENDED"})
        } else {
          if (typeof announce === "function") announce("Could not join Hangout room")
        }
      })
  }

  function sendMessage(body) {
    if (!roomChannel || state.phase !== HANGOUTS_PHASES.ROOM) return
    const intent = formatMessageIntent(body)
    roomChannel.push("message:send", intent)
      .receive("ok", (accepted) => {
        dispatch({type: "MESSAGE_ACCEPTED", message: accepted})
      })
      .receive("error", (err) => {
        if (typeof announce === "function") announce(err?.reason || "Failed to send message")
      })
  }

  function handleReact(reaction) {
    if (!roomChannel || !state.current_content) return
    const intent = formatReactionIntent(state.current_content.sequence, reaction)
    roomChannel.push("reaction:add", intent)
      .receive("ok", (result) => {
        if (result?.reactions) dispatch({type: "REACTIONS_UPDATED", reactions: result.reactions})
      })
  }

  function handleSkip() {
    if (!roomChannel || !state.current_content) return
    const intent = formatSkipIntent(state.current_content.sequence)
    roomChannel.push("content:skip_vote", intent)
      .receive("ok", (result) => {
        if (result?.skip_status) dispatch({type: "SKIP_UPDATED", skip_status: result.skip_status})
      })
  }

  function leaveRoom() {
    if (roomChannel) {
      roomChannel.push("room:leave", {})
      roomChannel.leave()
      roomChannel = null
    }
    dispatch({type: "ROOM_ENDED"})
  }

  function reportMember(targetSlot, category, evidence) {
    if (!roomChannel) return
    const intent = formatReportIntent(targetSlot, category, evidence)
    return new Promise((resolve, reject) => {
      roomChannel.push("safety:report", intent)
        .receive("ok", (res) => resolve(res))
        .receive("error", (err) => reject(err))
    })
  }

  function blockMember(targetSlot) {
    if (!roomChannel) return
    const intent = formatBlockIntent(targetSlot)
    return new Promise((resolve, reject) => {
      roomChannel.push("safety:block", intent)
        .receive("ok", (res) => resolve(res))
        .receive("error", (err) => reject(err))
    })
  }

  return {
    getState: () => state,
    dispatch,
    joinQueue,
    leaveQueue,
    joinRoom,
    sendMessage,
    handleReact,
    handleSkip,
    leaveRoom,
    reportMember,
    blockMember
  }
}

export function setupHangoutsBrowser() {
  if (typeof window === "undefined" || typeof document === "undefined") return null

  function presentHangoutScreen(name) {
    document.querySelectorAll("[data-screen]").forEach((node) => {
      const active = node.dataset.screen === name
      node.classList.toggle("active", active)
      if (active) node.removeAttribute("hidden")
      else if (node.dataset.screen.startsWith("hangout-")) node.setAttribute("hidden", "")
    })

    const isHangoutScreen = name.startsWith("hangout-")
    document.querySelectorAll("#bottom-nav [data-go]").forEach((btn) => {
      if (btn.dataset.go === "hangout-entry" && isHangoutScreen) {
        btn.setAttribute("aria-current", "page")
      } else if (isHangoutScreen) {
        btn.removeAttribute("aria-current")
      }
    })
  }

  function announce(msg) {
    const status = document.getElementById("status")
    if (status) status.textContent = msg
  }

  const client = createHangoutClient({
    getSocket: () => window.app?.socket || null,
    getParticipantId: () => window.app?.identity?.participant_id || null,
    presentScreen: presentHangoutScreen,
    announce
  })

  // Wire UI event listeners
  document.addEventListener("click", (event) => {
    const target = event.target.closest("[data-go='hangout-entry'], #btn-enter-hangout")
    if (target) {
      event.preventDefault()
      event.stopImmediatePropagation()
      presentHangoutScreen("hangout-entry")
    }
  }, true)

  const joinBtn = document.getElementById("hangout-join-queue-btn")
  if (joinBtn) {
    joinBtn.addEventListener("click", () => {
      const select = document.getElementById("hangout-language")
      const customInput = document.getElementById("hangout-language-custom")
      const lang = select?.value === "custom" ? customInput?.value : select?.value
      client.joinQueue(lang || "en")
    })
  }

  const langSelect = document.getElementById("hangout-language")
  if (langSelect) {
    langSelect.addEventListener("change", () => {
      const customWrap = document.getElementById("hangout-custom-language-wrap")
      if (customWrap) customWrap.hidden = langSelect.value !== "custom"
    })
  }

  const leaveQueueBtn = document.getElementById("hangout-leave-queue-btn")
  if (leaveQueueBtn) {
    leaveQueueBtn.addEventListener("click", () => {
      client.leaveQueue()
      presentHangoutScreen("hangout-entry")
    })
  }

  const messageForm = document.getElementById("hangout-message-form")
  if (messageForm) {
    messageForm.addEventListener("submit", (e) => {
      e.preventDefault()
      const input = document.getElementById("hangout-message-input")
      const body = input?.value?.trim()
      if (body) {
        client.sendMessage(body)
        if (input) input.value = ""
      }
    })
  }

  const leaveRoomBtn = document.getElementById("hangout-leave-room-btn")
  if (leaveRoomBtn) {
    leaveRoomBtn.addEventListener("click", () => {
      client.leaveRoom()
      presentHangoutScreen("hangout-ended")
    })
  }

  const skipBtn = document.getElementById("hangout-skip-btn")
  if (skipBtn) {
    skipBtn.addEventListener("click", () => {
      client.handleSkip()
    })
  }

  // Safety report modal
  const reportOpenBtn = document.getElementById("hangout-report-open-btn")
  const reportDialog = document.getElementById("hangout-report-dialog-backdrop")
  const reportTargetSelect = document.getElementById("hangout-report-target")
  if (reportOpenBtn && reportDialog && reportTargetSelect) {
    reportOpenBtn.addEventListener("click", () => {
      const snapshot = client.getState().room_snapshot
      const others = snapshot?.members?.filter((m) => !m.self) || []
      reportTargetSelect.replaceChildren()
      for (const member of others) {
        const opt = document.createElement("option")
        opt.value = String(member.identity.slot)
        opt.textContent = `${member.identity.emoji} ${member.identity.label}`
        reportTargetSelect.append(opt)
      }
      reportDialog.hidden = false
    })

    document.getElementById("hangout-report-cancel-btn")?.addEventListener("click", () => {
      reportDialog.hidden = true
    })

    document.getElementById("hangout-report-submit-btn")?.addEventListener("click", async () => {
      const slot = reportTargetSelect.value
      const category = document.getElementById("hangout-report-category")?.value || "other"
      const evidence = document.getElementById("hangout-report-evidence")?.value || ""
      try {
        await client.reportMember(slot, category, evidence)
        reportDialog.hidden = true
        announce("Report submitted successfully.")
      } catch (e) {
        announce(e?.reason || "Could not submit report.")
      }
    })
  }

  // Safety block modal
  const blockOpenBtn = document.getElementById("hangout-block-open-btn")
  const blockDialog = document.getElementById("hangout-block-dialog-backdrop")
  const blockTargetSelect = document.getElementById("hangout-block-target")
  if (blockOpenBtn && blockDialog && blockTargetSelect) {
    blockOpenBtn.addEventListener("click", () => {
      const snapshot = client.getState().room_snapshot
      const others = snapshot?.members?.filter((m) => !m.self) || []
      blockTargetSelect.replaceChildren()
      for (const member of others) {
        const opt = document.createElement("option")
        opt.value = String(member.identity.slot)
        opt.textContent = `${member.identity.emoji} ${member.identity.label}`
        blockTargetSelect.append(opt)
      }
      blockDialog.hidden = false
    })

    document.getElementById("hangout-block-cancel-btn")?.addEventListener("click", () => {
      blockDialog.hidden = true
    })

    document.getElementById("hangout-block-submit-btn")?.addEventListener("click", async () => {
      const slot = blockTargetSelect.value
      try {
        await client.blockMember(slot)
        blockDialog.hidden = true
        announce("Member blocked.")
      } catch (e) {
        announce(e?.reason || "Could not block member.")
      }
    })
  }

  window.__hangoutClient = client
  document.documentElement.dataset.hangoutsBooted = "true"
  return client
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => setupHangoutsBrowser())
  } else {
    setupHangoutsBrowser()
  }
}
