import {Socket} from "/vendor/phoenix.mjs"
import {FLOW_PHASE, createOperationGuard, loadingPresentation} from "./flow_loading.mjs"

const APP_ENTRY = "/assets/expression_runtime.mjs?v=20260824_v2"
const BOOT_WATCHDOG_MS = 15_000
const queueGuard = createOperationGuard()
let activeQueueAttemptId = null
let currentQueuePhase = FLOW_PHASE.MATCHMAKING_ADMISSION
let selectedDoor = null
let bootWatchdog = null
let startupFailureObserver = null

function node(selector) {
  return document.querySelector(selector)
}

function announcePhase(message) {
  const status = node("#queue-phase-status")
  if (status) status.textContent = message
}

function renderQueue(phase, context = {}) {
  currentQueuePhase = phase
  const presentation = loadingPresentation(phase, {door: context.door || selectedDoor})
  const section = node('[data-screen="queue"]')
  const title = node("#queue-title")
  const lede = node("#queue-lede")
  const leave = node("#leave-queue")

  if (title) title.textContent = presentation.title
  if (lede) lede.textContent = presentation.detail
  if (leave && "leaveEnabled" in presentation) leave.disabled = !presentation.leaveEnabled
  if (section) section.setAttribute("aria-busy", String(presentation.interaction === "blocked"))
  announcePhase(`${presentation.title} ${presentation.detail}`)
}

function resetQueuePresentation() {
  selectedDoor = null
  activeQueueAttemptId = null
  queueGuard.invalidate()
  renderQueue(FLOW_PHASE.MATCHMAKING_ADMISSION)
}

function queueAttemptMatches(payload) {
  if (!activeQueueAttemptId) return true
  return !payload?.queue_attempt_id || payload.queue_attempt_id === activeQueueAttemptId
}

function applyQueueSnapshot(snapshot) {
  const queue = snapshot?.queue
  if (!queue?.queue_attempt_id) return false
  activeQueueAttemptId = queue.queue_attempt_id
  if (queue.display_door) selectedDoor = queue.display_door
  renderQueue(FLOW_PHASE.MATCHMAKING_WAITING, {door: selectedDoor})
  return true
}

function stopBootWatchers() {
  clearTimeout(bootWatchdog)
  bootWatchdog = null
  startupFailureObserver?.disconnect()
  startupFailureObserver = null
}

function finishBoot(snapshot) {
  stopBootWatchers()
  const activeScreen = node("section.screen.active")?.dataset?.screen
  if (activeScreen === "queue") applyQueueSnapshot(snapshot)
  const bridge = node("#boot-bridge")
  if (bridge) {
    bridge.hidden = true
    bridge.setAttribute("aria-busy", "false")
  }
  document.body.classList.remove("flow-booting")
}

function renderBootFailure() {
  stopBootWatchers()
  const bridge = node("#boot-bridge")
  if (!bridge) return
  bridge.dataset.state = "error"
  bridge.setAttribute("aria-busy", "false")
  const title = bridge.querySelector("h1")
  const detail = bridge.querySelector(".lede")
  if (title) title.textContent = "StrangerTalks can’t confirm your session."
  if (detail) detail.textContent = "Your current state is still unknown. Reload to try restoring it again."
  if (!bridge.querySelector("button")) {
    const retry = document.createElement("button")
    retry.type = "button"
    retry.textContent = "Reload StrangerTalks"
    retry.addEventListener("click", () => location.reload())
    bridge.append(retry)
  }
}

function installBootWatchers() {
  bootWatchdog = setTimeout(() => {
    if (document.body.classList.contains("flow-booting")) renderBootFailure()
  }, BOOT_WATCHDOG_MS)

  const status = node("#status")
  if (!status) return
  startupFailureObserver = new MutationObserver(() => {
    if (!document.body.classList.contains("flow-booting")) return
    if (status.textContent.includes("StrangerTalks could not start")) renderBootFailure()
  })
  startupFailureObserver.observe(status, {childList: true, characterData: true, subtree: true})
}

function withQueueCompletion(push, event, payload) {
  if (event === "queue:join") {
    const token = queueGuard.begin("queue-admission")
    renderQueue(FLOW_PHASE.MATCHMAKING_ADMISSION, {door: selectedDoor})
    push.receive("ok", (result) => {
      if (!queueGuard.current(token)) return
      activeQueueAttemptId = result?.queue_attempt_id || activeQueueAttemptId
      renderQueue(FLOW_PHASE.MATCHMAKING_WAITING, {door: selectedDoor})
    })
    push.receive("error", () => {
      if (!queueGuard.current(token)) return
      resetQueuePresentation()
    })
    push.receive("timeout", () => {
      if (!queueGuard.current(token)) return
      resetQueuePresentation()
    })
    return
  }

  if (event === "queue:leave") {
    const token = queueGuard.begin("queue-cancel")
    renderQueue(FLOW_PHASE.MATCHMAKING_CANCELLING, {door: selectedDoor})
    push.receive("ok", (result) => {
      if (!queueGuard.current(token)) return
      if (result?.status === "left") {
        activeQueueAttemptId = null
        renderQueue(FLOW_PHASE.MATCHMAKING_CANCELLED, {door: selectedDoor})
      }
    })
    push.receive("error", () => {
      if (!queueGuard.current(token)) return
      renderQueue(FLOW_PHASE.MATCHMAKING_WAITING, {door: selectedDoor})
    })
    push.receive("timeout", () => {
      if (!queueGuard.current(token)) return
      renderQueue(FLOW_PHASE.MATCHMAKING_WAITING, {door: selectedDoor})
    })
    return
  }

  if (event === "session:reconcile") {
    const token = queueGuard.begin("session-reconcile")
    push.receive("ok", (result) => {
      if (!queueGuard.current(token)) return
      const activeScreen = node("section.screen.active")?.dataset?.screen
      if (activeScreen === "match" || activeScreen === "conversation") return
      if (!applyQueueSnapshot(result?.snapshot)) resetQueuePresentation()
    })
  }
}

function withBlockCompletion(push) {
  const button = node("#block")
  if (!button) return
  const priorText = button.textContent
  button.disabled = true
  button.textContent = "Blocking…"
  const restore = () => {
    button.disabled = false
    button.textContent = priorText
  }
  push.receive("ok", () => { button.textContent = "Blocked" })
  push.receive("error", restore)
  push.receive("timeout", restore)
}

function patchParticipantChannel(channel) {
  if (channel.__f07ParticipantPatched) return channel
  channel.__f07ParticipantPatched = true

  const originalPush = channel.push.bind(channel)
  channel.push = function(event, payload = {}, timeout) {
    const push = originalPush(event, payload, timeout)
    withQueueCompletion(push, event, payload)
    return push
  }

  const originalOn = channel.on.bind(channel)
  channel.on = function(event, callback) {
    return originalOn(event, (payload) => {
      if (event === "queue:status") {
        if (!queueAttemptMatches(payload)) return callback(payload)
        if (payload?.status === "queued" && payload.queue_attempt_id) {
          if (currentQueuePhase !== FLOW_PHASE.MATCHMAKING_CANCELLING) {
            activeQueueAttemptId = payload.queue_attempt_id
            renderQueue(FLOW_PHASE.MATCHMAKING_WAITING, {door: selectedDoor})
          }
        } else if (["left", "timed_out"].includes(payload?.status)) {
          resetQueuePresentation()
        }
      } else if (event === "match_found") {
        queueGuard.invalidate()
        activeQueueAttemptId = null
        renderQueue(FLOW_PHASE.ENTERING_CONVERSATION, {door: selectedDoor})
      } else if (event === "transition:recovery_failed") {
        resetQueuePresentation()
      }
      return callback(payload)
    })
  }

  const originalJoin = channel.join.bind(channel)
  channel.join = function(timeout) {
    const push = originalJoin(timeout)
    const originalReceive = push.receive.bind(push)

    originalReceive("timeout", renderBootFailure)

    push.receive = function(status, callback) {
      if (status === "ok") {
        return originalReceive(status, async (payload) => {
          try {
            return await callback(payload)
          } finally {
            finishBoot(payload?.snapshot)
          }
        })
      }
      if (status === "error") {
        return originalReceive(status, async (payload) => {
          try {
            return await callback(payload)
          } finally {
            renderBootFailure()
          }
        })
      }
      return originalReceive(status, callback)
    }
    return push
  }

  return channel
}

function patchConversationChannel(channel) {
  if (channel.__f07ConversationPatched) return channel
  channel.__f07ConversationPatched = true
  const originalPush = channel.push.bind(channel)
  channel.push = function(event, payload = {}, timeout) {
    const push = originalPush(event, payload, timeout)
    if (event === "conversation:block") withBlockCompletion(push)
    return push
  }
  return channel
}

const originalSocketChannel = Socket.prototype.channel
Socket.prototype.channel = function(topic, params) {
  const channel = originalSocketChannel.call(this, topic, params)
  if (typeof topic === "string" && topic.startsWith("participant:")) return patchParticipantChannel(channel)
  if (typeof topic === "string" && topic.startsWith("conversation:")) return patchConversationChannel(channel)
  return channel
}

document.addEventListener("click", (event) => {
  const door = event.target.closest(".door")
  if (!door) return
  const language = node("#conversation-language")?.value
  if (!language) return
  selectedDoor = door.querySelector("strong")?.textContent?.trim() || null
  renderQueue(FLOW_PHASE.MATCHMAKING_ADMISSION, {door: selectedDoor})
  queueMicrotask(() => renderQueue(FLOW_PHASE.MATCHMAKING_ADMISSION, {door: selectedDoor}))
}, true)

installBootWatchers()
await import(APP_ENTRY)
