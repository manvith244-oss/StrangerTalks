const guestIdentityKey = "strangertalks_living_thread_identity_v1"

const statusNode = document.querySelector("#status")
const contentNode = document.querySelector("#content")
const contributionForm = document.querySelector("#contribution-form")
const continuationForm = document.querySelector("#continuation-form")
const debriefForm = document.querySelector("#debrief-form")
const seedNode = document.querySelector("#seed")

let identity = null
let identitySource = null

function setStatus(message) {
  statusNode.textContent = message
}

function hideForms() {
  contributionForm.hidden = true
  continuationForm.hidden = true
  debriefForm.hidden = true
}

function clearContent() {
  contentNode.replaceChildren()
}

function paragraph(text) {
  const node = document.createElement("p")
  node.textContent = text
  return node
}

function quote(text) {
  const node = document.createElement("blockquote")
  node.textContent = text
  return node
}

async function connectedIdentity() {
  try {
    const response = await fetch("/api/account/session", {credentials: "same-origin"})
    if (!response.ok) return null
    const account = await response.json()

    if (account?.connected && typeof account.participant_token === "string") {
      return {
        participant_id: account.participant_id,
        token: account.participant_token
      }
    }
  } catch (_error) {
    // The pilot can still use an ordinary anonymous participant.
  }

  return null
}

function loadGuestIdentity() {
  try {
    const raw = localStorage.getItem(guestIdentityKey)
    if (!raw) return null
    const candidate = JSON.parse(raw)

    if (
      candidate &&
      typeof candidate.participant_id === "string" &&
      typeof candidate.token === "string"
    ) {
      return candidate
    }
  } catch (_error) {
    // Treat unavailable/corrupt local storage as no recoverable pilot identity.
  }

  return null
}

function saveGuestIdentity(candidate) {
  try {
    localStorage.setItem(guestIdentityKey, JSON.stringify(candidate))
  } catch (_error) {
    // A storage-disabled browser can use the pilot for this page load, but cannot
    // be expected to preserve the 24-hour causal thread after closing it.
  }
}

function clearGuestIdentity() {
  try {
    localStorage.removeItem(guestIdentityKey)
  } catch (_error) {
    // Nothing else to do.
  }
}

async function createGuestIdentity() {
  const response = await fetch("/api/participants", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: "{}"
  })

  if (!response.ok) throw new Error("participant_bootstrap_failed")
  const candidate = await response.json()
  saveGuestIdentity(candidate)
  return candidate
}

async function bootstrapIdentity() {
  const connected = await connectedIdentity()

  if (connected) {
    identitySource = "account"
    return connected
  }

  const saved = loadGuestIdentity()
  if (saved) {
    identitySource = "guest"
    return saved
  }

  identitySource = "guest"
  return createGuestIdentity()
}

async function pilotFetch(path, init = {}, allowGuestRefresh = true) {
  const headers = new Headers(init.headers || {})
  headers.set("authorization", `Bearer ${identity.token}`)

  if (init.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json")
  }

  let response = await fetch(path, {...init, headers})

  if (response.status === 401 && identitySource === "guest" && allowGuestRefresh) {
    clearGuestIdentity()
    identity = await createGuestIdentity()
    response = await pilotFetch(path, init, false)
    return response
  }

  return response
}

async function jsonRequest(path, init = {}) {
  const response = await pilotFetch(path, init)
  let body = {}

  try {
    body = await response.json()
  } catch (_error) {
    body = {}
  }

  if (!response.ok) {
    const error = new Error(body.error || "pilot_request_failed")
    error.status = response.status
    throw error
  }

  return body
}

function renderResolved(experience) {
  setStatus("This one has finished unfolding.")
  clearContent()

  if (experience.role === "CONSEQUENCE_A") {
    contentNode.append(paragraph("You left:"), quote(experience.your_contribution || experience.seed))
    contentNode.append(paragraph("Another stranger carried it forward:"), quote(experience.continuation))
  } else {
    contentNode.append(paragraph("It began with:"), quote(experience.seed))
    contentNode.append(paragraph("Another stranger carried it forward:"), quote(experience.continuation))
  }

  debriefForm.hidden = false
}

function renderConsequence(experience) {
  if (experience.state === "NEEDS_CONTRIBUTION") {
    setStatus("Leave one small thing. If another stranger picks it up, it can continue without you.")
    contributionForm.hidden = false
    return
  }

  if (experience.status === "WAITING_FOR_B") {
    setStatus("Your piece is here. Still waiting for someone to carry this forward.")
    clearContent()
    contentNode.append(quote(experience.your_contribution || experience.seed))
    return
  }

  if (experience.status === "CONTINUED") {
    setStatus("Someone carried your piece forward. It is still unfolding.")
    clearContent()
    contentNode.append(paragraph("You left:"), quote(experience.your_contribution || experience.seed))
    return
  }

  if (experience.status === "LIQUIDITY_FAILURE") {
    setStatus("No one picked this one up this time.")
    clearContent()
    contentNode.append(quote(experience.your_contribution || experience.seed))
    return
  }

  if (experience.status === "RESOLVED") {
    renderResolved(experience)
  }
}

function renderSpectator(experience) {
  if (experience.state === "WAITING_FOR_THREAD") {
    setStatus("Nothing is ready to watch right now.")
    return
  }

  if (experience.status === "RESOLVED") {
    renderResolved(experience)
    return
  }

  setStatus(
    experience.status === "LIQUIDITY_FAILURE"
      ? "No one picked this one up this time."
      : "You're watching one small anonymous thing unfold."
  )
  clearContent()
  contentNode.append(quote(experience.seed))
}

function renderCarrier(experience) {
  if (experience.state === "WAITING_FOR_THREAD") {
    setStatus("Nothing is waiting for you to carry forward right now.")
    return
  }

  if (experience.state === "CAN_CONTINUE") {
    setStatus("A stranger left something unfinished.")
    seedNode.textContent = experience.seed
    continuationForm.hidden = false
    return
  }

  if (experience.state === "CARRIED") {
    setStatus("You carried one forward. That's all this small test needs from you.")
    clearContent()
    contentNode.append(paragraph("What you received:"), quote(experience.seed))
  }
}

function render(experience) {
  hideForms()
  clearContent()

  switch (experience.role) {
    case "CONSEQUENCE_A":
      renderConsequence(experience)
      break
    case "SPECTATOR_A":
      renderSpectator(experience)
      break
    case "CARRIER_B":
      renderCarrier(experience)
      break
    default:
      setStatus("This pilot isn't available right now.")
  }
}

async function loadExperience() {
  setStatus("Opening…")
  const experience = await jsonRequest("/api/living-thread")
  render(experience)
}

contributionForm.addEventListener("submit", async (event) => {
  event.preventDefault()
  const textarea = contributionForm.elements.body
  const body = textarea.value.trim()
  if (!body) return

  contributionForm.querySelector("button").disabled = true

  try {
    const created = await jsonRequest("/api/living-thread/start", {
      method: "POST",
      body: JSON.stringify({body})
    })

    hideForms()
    clearContent()
    setStatus("Your piece is here. Still waiting for someone to carry this forward.")
    contentNode.append(quote(body))
    contentNode.dataset.threadId = created.thread_id
  } catch (_error) {
    setStatus("That didn't save. Try once more.")
  } finally {
    contributionForm.querySelector("button").disabled = false
  }
})

continuationForm.addEventListener("submit", async (event) => {
  event.preventDefault()
  const textarea = continuationForm.elements.body
  const body = textarea.value.trim()
  if (!body) return

  continuationForm.querySelector("button").disabled = true

  try {
    await jsonRequest("/api/living-thread/continue", {
      method: "POST",
      body: JSON.stringify({body})
    })

    hideForms()
    clearContent()
    setStatus("You carried one forward. That's all this small test needs from you.")
    contentNode.append(paragraph("What you received:"), quote(seedNode.textContent))
  } catch (error) {
    if (error.message === "no_waiting_thread") {
      hideForms()
      setStatus("That one is no longer waiting. Nothing was rescued or backfilled.")
    } else {
      setStatus("That didn't save. Try once more.")
    }
  } finally {
    continuationForm.querySelector("button").disabled = false
  }
})

debriefForm.addEventListener("submit", async (event) => {
  event.preventDefault()
  const data = new FormData(debriefForm)
  const answer = data.get("answer")
  if (!answer) return

  debriefForm.querySelector("button").disabled = true

  try {
    await jsonRequest("/api/living-thread/debrief", {
      method: "POST",
      body: JSON.stringify({
        answer,
        reason: String(data.get("reason") || "").trim() || null
      })
    })

    debriefForm.hidden = true
    contentNode.append(paragraph("Thanks. That's enough for this test."))
  } catch (_error) {
    setStatus("Your answer didn't save. You can try again.")
    debriefForm.querySelector("button").disabled = false
  }
})

try {
  identity = await bootstrapIdentity()
  await loadExperience()
} catch (_error) {
  hideForms()
  setStatus("This pilot couldn't open right now.")
}
