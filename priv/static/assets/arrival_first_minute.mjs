const FIRST_MINUTE_FAILURE = "StrangerTalks could not start. Please reload."

function appendDescriptionId(element, id) {
  if (!element || !id) return
  const ids = new Set((element.getAttribute("aria-describedby") || "").split(/\s+/).filter(Boolean))
  ids.add(id)
  element.setAttribute("aria-describedby", [...ids].join(" "))
}

function focusScreenHeading(screen) {
  if (!screen) return
  const heading = screen.querySelector("h1")
  if (!heading) return
  if (!heading.hasAttribute("tabindex")) heading.setAttribute("tabindex", "-1")
  try {
    heading.focus({preventScroll: true})
  } catch (_error) {
    heading.focus()
  }
}

function activeScreen(documentRef) {
  return documentRef.querySelector("[data-screen].active")
}

export function installArrivalFirstMinute(documentRef = globalThis.document, windowRef = globalThis.window) {
  if (!documentRef || !windowRef || documentRef.documentElement?.dataset.arrivalFirstMinuteInstalled === "true") return
  documentRef.documentElement.dataset.arrivalFirstMinuteInstalled = "true"

  const doorsScreen = documentRef.querySelector('[data-screen="doors"]')
  const doorGrid = documentRef.querySelector("#doors")
  const languageSelect = documentRef.querySelector("#conversation-language")
  const status = documentRef.querySelector("#status")
  const queueLede = documentRef.querySelector("#queue-lede")
  const leaveQueue = documentRef.querySelector("#leave-queue")

  if (!doorsScreen || !doorGrid || !languageSelect || !status) return

  let joinInFlight = false
  let screenFocusScheduled = false

  const arrivalLede = doorsScreen.querySelector(":scope > .lede")
  let trustCue = documentRef.querySelector("#arrival-trust-cue")
  if (!trustCue) {
    trustCue = documentRef.createElement("p")
    trustCue.id = "arrival-trust-cue"
    trustCue.textContent = "Anonymous, one-to-one conversation with another person. No profile required."
    arrivalLede?.after(trustCue)
  }

  let languageHelp = documentRef.querySelector("#conversation-language-help")
  if (!languageHelp) {
    languageHelp = documentRef.createElement("p")
    languageHelp.id = "conversation-language-help"
    languageHelp.textContent = "Choose the language you want both people to use."
    languageSelect.after(languageHelp)
  }

  let feedback = documentRef.querySelector("#arrival-feedback")
  if (!feedback) {
    feedback = documentRef.createElement("p")
    feedback.id = "arrival-feedback"
    feedback.setAttribute("role", "status")
    feedback.setAttribute("aria-live", "polite")
    feedback.hidden = true
    languageHelp.after(feedback)
  }

  appendDescriptionId(languageSelect, languageHelp.id)
  appendDescriptionId(languageSelect, feedback.id)

  const setFeedback = (message, {languageError = false} = {}) => {
    feedback.textContent = message || ""
    feedback.hidden = !message
    if (languageError) languageSelect.setAttribute("aria-invalid", "true")
    else languageSelect.removeAttribute("aria-invalid")
  }

  const clearFeedback = () => setFeedback("")

  const queueDoorLabel = () => documentRef.querySelector("#queue-door")?.textContent?.trim() || "the same option"
  const restoreQueueCopy = () => {
    if (queueLede) queueLede.textContent = `Looking for someone who chose ${queueDoorLabel()} too.`
  }

  const setDoorBusy = (busy) => {
    joinInFlight = busy
    doorGrid.setAttribute("aria-busy", busy ? "true" : "false")
  }

  const ensureStartupFailure = () => {
    let panel = documentRef.querySelector("#arrival-startup-failure")
    if (panel) return panel

    panel = documentRef.createElement("aside")
    panel.id = "arrival-startup-failure"
    panel.className = "temporary-entry"
    panel.setAttribute("role", "alert")

    const title = documentRef.createElement("h2")
    title.textContent = "StrangerTalks couldn't connect"
    const copy = documentRef.createElement("p")
    copy.textContent = "Your anonymous session did not start, so matching has not begun. Retry when your connection is ready."
    const retry = documentRef.createElement("button")
    retry.type = "button"
    retry.textContent = "Retry"
    retry.addEventListener("click", () => windowRef.location.reload())

    panel.append(title, copy, retry)
    trustCue.after(panel)
    languageSelect.disabled = true
    doorGrid.querySelectorAll("button.door").forEach((button) => { button.disabled = true })
    return panel
  }

  doorGrid.addEventListener("click", (event) => {
    const door = event.target.closest?.("button.door")
    if (!door || !doorGrid.contains(door)) return

    if (!languageSelect.value) {
      event.preventDefault()
      event.stopImmediatePropagation()
      setDoorBusy(false)
      setFeedback("Choose a Conversation Language before picking a Door.", {languageError: true})
      status.textContent = "Choose a Conversation Language before picking a Door."
      languageSelect.focus()
      return
    }

    if (joinInFlight) {
      event.preventDefault()
      event.stopImmediatePropagation()
      return
    }

    clearFeedback()
    setDoorBusy(true)
  }, true)

  languageSelect.addEventListener("change", () => {
    if (languageSelect.value) clearFeedback()
  })

  leaveQueue?.addEventListener("click", () => {
    queueMicrotask(() => {
      if (activeScreen(documentRef)?.dataset.screen !== "queue") return
      leaveQueue.disabled = true
      leaveQueue.setAttribute("aria-busy", "true")
    })
  }, true)

  const resetLeaveQueue = () => {
    if (!leaveQueue) return
    leaveQueue.disabled = false
    leaveQueue.removeAttribute("aria-busy")
  }

  const scheduleScreenFocus = () => {
    if (screenFocusScheduled) return
    screenFocusScheduled = true
    windowRef.requestAnimationFrame(() => {
      screenFocusScheduled = false
      const screen = activeScreen(documentRef)
      if (!screen) return

      if (screen.dataset.screen === "doors") {
        setDoorBusy(false)
        resetLeaveQueue()
      }
      if (screen.dataset.screen !== "queue") resetLeaveQueue()
      focusScreenHeading(screen)
    })
  }

  const screenObserver = new MutationObserver(() => scheduleScreenFocus())
  documentRef.querySelectorAll("[data-screen]").forEach((screen) => {
    screenObserver.observe(screen, {attributes: true, attributeFilter: ["class"]})
  })

  const handleStatus = () => {
    const message = status.textContent.trim()
    const screenName = activeScreen(documentRef)?.dataset.screen

    if (message === FIRST_MINUTE_FAILURE) {
      setDoorBusy(false)
      setFeedback("StrangerTalks could not start. Matching has not begun.")
      const panel = ensureStartupFailure()
      panel.querySelector("button")?.focus()
      return
    }

    if (message === "Connecting…" && screenName === "queue") {
      if (queueLede) queueLede.textContent = "Connecting securely before matching starts…"
      return
    }

    if (message === "Connection interrupted. Reconnecting." && screenName === "queue") {
      if (queueLede) queueLede.textContent = "Connection interrupted. Reconnecting before matching continues…"
      return
    }

    if (message === "Queue status: queued") {
      restoreQueueCopy()
      return
    }

    if (message === "Could not cancel matching. Please try again." && screenName === "queue") {
      if (queueLede) queueLede.textContent = message
      resetLeaveQueue()
      return
    }

    if (message === "Could not start matching right now. Please try again." && screenName === "doors") {
      setDoorBusy(false)
      setFeedback(message)
    }
  }

  const statusObserver = new MutationObserver(handleStatus)
  statusObserver.observe(status, {childList: true, characterData: true, subtree: true})

  return {
    clearFeedback,
    handleStatus,
    scheduleScreenFocus
  }
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  installArrivalFirstMinute(document, window)
}
