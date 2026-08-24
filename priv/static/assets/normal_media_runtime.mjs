import {activeConversations, getRecord, listRecords} from "./local_data.mjs"
import {
  dedupeNormalMedia,
  normalMediaDraftMatchesRuntime,
  normalMediaKind,
  normalMediaLabel,
  validNormalMediaFile
} from "./normal_media.mjs"

const IDENTITY_KEY = "strangertalks.identity.v1"
const POLL_MS = 1000

const state = {
  draft: null,
  previewUrl: null,
  previewGeneration: 0,
  activeConversationId: null,
  mediaUrls: new Map(),
  renderedIds: new Set(),
  viewerReturnFocus: null,
  viewerMediaId: null,
  pollTimer: null,
  polling: false
}

function byId(id) {
  return document.getElementById(id)
}

function announce(message) {
  const status = byId("status")
  if (status) status.textContent = message
}

function conversationScreenActive() {
  return Boolean(document.querySelector('[data-screen="conversation"].active'))
}

async function currentRuntime() {
  if (!conversationScreenActive()) return null
  const identity = await getRecord(IDENTITY_KEY).catch(() => null)
  if (!identity?.value?.participant_id || !identity?.value?.token) return null

  const records = await listRecords().catch(() => [])
  const conversations = activeConversations(records)
    .slice()
    .sort((a, b) => String(b.updated_at || b.value?.started_at || "").localeCompare(String(a.updated_at || a.value?.started_at || "")))

  const conversation = conversations[0]
  if (!conversation?.value?.conversation_id) return null

  return {
    conversationId: conversation.value.conversation_id,
    participantId: identity.value.participant_id,
    token: identity.value.token
  }
}

function revokeUrl(url) {
  if (url) URL.revokeObjectURL(url)
}

function clearPreview({hide = true} = {}) {
  state.previewGeneration += 1
  revokeUrl(state.previewUrl)
  state.previewUrl = null
  state.draft = null

  const container = byId("normal-media-preview-container")
  if (container) {
    const video = container.querySelector("video")
    if (video) {
      video.pause()
      video.removeAttribute("src")
      video.load()
    }
    container.replaceChildren()
  }

  if (hide) {
    const sheet = byId("normal-media-preview")
    if (sheet) sheet.hidden = true
  }
}

function closeViewer({restoreFocus = true} = {}) {
  const viewer = byId("normal-media-viewer")
  if (!viewer || viewer.hidden) return
  const video = viewer.querySelector("video")
  if (video) video.pause()
  viewer.hidden = true
  viewer.querySelector(".normal-media-viewer-content")?.replaceChildren()
  state.viewerMediaId = null
  const returnFocus = state.viewerReturnFocus
  state.viewerReturnFocus = null
  if (restoreFocus) returnFocus?.focus()
}

function releaseConversationUrls() {
  closeViewer({restoreFocus: false})
  for (const url of state.mediaUrls.values()) revokeUrl(url)
  state.mediaUrls.clear()
  state.renderedIds.clear()
}

function transitionConversation(conversationId) {
  if (state.activeConversationId === conversationId) return
  clearPreview()
  releaseConversationUrls()
  state.activeConversationId = conversationId
}

function injectStyles() {
  if (byId("normal-media-style")) return
  const style = document.createElement("style")
  style.id = "normal-media-style"
  style.textContent = `
    .normal-media-message { max-width: min(76%, 32rem); }
    .normal-media-card { display: grid; gap: .45rem; min-width: 10rem; }
    .normal-media-card img, .normal-media-card video { display: block; width: min(20rem, 100%); max-height: 22rem; object-fit: contain; border-radius: .8rem; background: #111; }
    .normal-media-card button { min-height: 40px; }
    .normal-media-meta { font-size: .78rem; opacity: .72; }
    .normal-media-mode-note { margin: .35rem 0 0; font-size: .82rem; opacity: .78; }
    .normal-media-preview-container img, .normal-media-preview-container video { display: block; width: 100%; max-height: min(55vh, 30rem); object-fit: contain; background: #111; border-radius: .8rem; }
    .normal-media-viewer { position: fixed; inset: 0; z-index: 1000; display: grid; place-items: center; padding: 1rem; background: rgba(0,0,0,.86); }
    .normal-media-viewer[hidden] { display: none; }
    .normal-media-viewer-panel { width: min(94vw, 56rem); max-height: 94vh; display: grid; gap: .75rem; }
    .normal-media-viewer-content { min-height: 0; display: grid; place-items: center; }
    .normal-media-viewer-content img, .normal-media-viewer-content video { max-width: 100%; max-height: 78vh; object-fit: contain; }
    @media (max-width: 390px) { .normal-media-message { max-width: 86%; } .normal-media-viewer { padding: .5rem; } }
    @media (orientation: landscape) and (max-height: 500px) { .normal-media-viewer-content img, .normal-media-viewer-content video { max-height: 68vh; } }
  `
  document.head.append(style)
}

function injectUi() {
  if (byId("normal-media-picker-btn")) return
  const controls = document.querySelector("#message-form .voice-controls")
  if (!controls) return

  const pickerButton = document.createElement("button")
  pickerButton.id = "normal-media-picker-btn"
  pickerButton.type = "button"
  pickerButton.textContent = "Photo / Video"
  pickerButton.setAttribute("aria-describedby", "normal-media-mode-note")

  const input = document.createElement("input")
  input.id = "normal-media-file-input"
  input.type = "file"
  input.accept = "image/jpeg,image/png,image/webp,video/mp4"
  input.hidden = true
  input.setAttribute("aria-label", "Choose a normal photo or video")

  const note = document.createElement("p")
  note.id = "normal-media-mode-note"
  note.className = "normal-media-mode-note"
  note.textContent = "Photo / Video can be reopened or replayed while this temporary Conversation remains available. View Once and View Twice use separate limited-open modes."

  controls.append(pickerButton, input)
  controls.after(note)

  const form = byId("message-form")
  form?.insertAdjacentHTML(
    "afterend",
    `<section id="normal-media-preview" class="voice-sheet" role="dialog" aria-modal="true" aria-labelledby="normal-media-preview-title" hidden>
      <h2 id="normal-media-preview-title">Preview normal media</h2>
      <div id="normal-media-preview-container" class="normal-media-preview-container"></div>
      <p id="normal-media-preview-status" role="status" aria-live="polite"></p>
      <div>
        <button id="normal-media-send" type="button" class="primary">Send normally</button>
        <button id="normal-media-cancel" type="button">Cancel</button>
      </div>
    </section>`
  )

  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="normal-media-viewer" class="normal-media-viewer" role="dialog" aria-modal="true" aria-label="Normal media viewer" hidden>
      <div class="normal-media-viewer-panel">
        <button id="normal-media-viewer-close" type="button" aria-label="Close media viewer">Close</button>
        <div class="normal-media-viewer-content"></div>
      </div>
    </div>`
  )

  pickerButton.addEventListener("click", () => input.click())
  input.addEventListener("change", () => {
    const file = input.files?.[0]
    input.value = ""
    if (file) selectFile(file).catch(() => announce("That media could not be previewed."))
  })
  byId("normal-media-cancel")?.addEventListener("click", () => clearPreview())
  byId("normal-media-send")?.addEventListener("click", () => sendDraft())
  byId("normal-media-viewer-close")?.addEventListener("click", () => closeViewer())
  byId("normal-media-viewer")?.addEventListener("click", (event) => {
    if (event.target === event.currentTarget) closeViewer()
  })
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !byId("normal-media-viewer")?.hidden) {
      event.preventDefault()
      closeViewer()
    }
  })
}

async function selectFile(file) {
  const runtime = await currentRuntime()
  if (!runtime) {
    announce("Open an active Conversation before choosing media.")
    return
  }

  transitionConversation(runtime.conversationId)

  if (!validNormalMediaFile(file)) {
    announce("Choose a supported JPEG, PNG, WebP photo up to 1 MB or MP4 video up to 5 MB.")
    return
  }

  const kind = normalMediaKind(file.type)
  const generation = state.previewGeneration + 1
  clearPreview({hide: false})
  state.previewGeneration = generation
  state.previewUrl = URL.createObjectURL(file)
  state.draft = {
    file,
    kind,
    clientMessageId: crypto.randomUUID(),
    originConversationId: runtime.conversationId,
    generation
  }

  const title = byId("normal-media-preview-title")
  const container = byId("normal-media-preview-container")
  const status = byId("normal-media-preview-status")
  const sheet = byId("normal-media-preview")
  const send = byId("normal-media-send")

  if (title) title.textContent = `Preview normal ${kind}`
  if (status) status.textContent = `${Math.max(1, Math.round(file.size / 1024))} KB · ${normalMediaLabel(kind)} ready · Reopenable in this temporary Conversation`
  if (send) {
    send.disabled = false
    send.textContent = "Send normally"
  }

  if (container) {
    if (kind === "photo") {
      const img = document.createElement("img")
      img.src = state.previewUrl
      img.alt = "Normal photo preview"
      container.replaceChildren(img)
    } else {
      const video = document.createElement("video")
      video.src = state.previewUrl
      video.controls = true
      video.playsInline = true
      video.preload = "metadata"
      video.setAttribute("aria-label", "Normal video preview")
      container.replaceChildren(video)
    }
  }

  if (sheet) sheet.hidden = false
  send?.focus()
}

async function sendDraft() {
  const draft = state.draft
  if (!draft) return
  const runtime = await currentRuntime()

  if (!runtime || !normalMediaDraftMatchesRuntime(draft, runtime.conversationId)) {
    announce("That media draft belongs to a Conversation that is no longer current.")
    clearPreview()
    return
  }

  const send = byId("normal-media-send")
  const status = byId("normal-media-preview-status")
  if (send) send.disabled = true
  if (status && state.draft?.generation === draft.generation) status.textContent = "Uploading / sending…"

  try {
    const response = await fetch(
      `/api/conversations/${encodeURIComponent(draft.originConversationId)}/normal-media/${encodeURIComponent(draft.clientMessageId)}/${draft.kind}`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${runtime.token}`,
          "content-type": "application/octet-stream"
        },
        body: draft.file
      }
    )

    const payload = await response.json().catch(() => ({}))
    const stillCurrent = await currentRuntime()
    if (!stillCurrent || stillCurrent.conversationId !== draft.originConversationId) return

    if (!response.ok) {
      if (response.status === 410) {
        announce("The Conversation ended before this media could be sent.")
        if (state.draft?.generation === draft.generation) clearPreview()
        return
      }
      throw new Error(payload.error || `upload_${response.status}`)
    }

    if (state.draft?.generation === draft.generation) {
      if (status) status.textContent = "Sent"
      clearPreview()
    }
    await renderMedia(payload, stillCurrent)
    announce(`${normalMediaLabel(payload.kind)} sent.`)
  } catch (_error) {
    const stillCurrent = await currentRuntime()
    if (!stillCurrent || stillCurrent.conversationId !== draft.originConversationId) return
    if (state.draft?.generation === draft.generation) {
      if (status) status.textContent = "Send failed. Nothing was delivered here. You can retry."
      if (send) {
        send.disabled = false
        send.textContent = "Retry send"
      }
    }
    announce("Media send failed. You can retry without creating a duplicate.")
  }
}

async function authenticatedBlob(runtime, clientMessageId) {
  const response = await fetch(
    `/api/conversations/${encodeURIComponent(runtime.conversationId)}/normal-media/${encodeURIComponent(clientMessageId)}`,
    {headers: {authorization: `Bearer ${runtime.token}`}, cache: "no-store"}
  )
  if (!response.ok) throw new Error(`media_${response.status}`)
  return response.blob()
}

async function mediaUrl(runtime, item) {
  const existing = state.mediaUrls.get(item.client_message_id)
  if (existing) return existing
  const blob = await authenticatedBlob(runtime, item.client_message_id)
  const current = await currentRuntime()
  if (!current || current.conversationId !== runtime.conversationId) throw new Error("stale_conversation")
  const url = URL.createObjectURL(blob)
  state.mediaUrls.set(item.client_message_id, url)
  return url
}

async function openViewer(item, runtime, trigger) {
  const viewer = byId("normal-media-viewer")
  const content = viewer?.querySelector(".normal-media-viewer-content")
  if (!viewer || !content) return

  try {
    const url = await mediaUrl(runtime, item)
    const current = await currentRuntime()
    if (!current || current.conversationId !== runtime.conversationId) return

    state.viewerReturnFocus = trigger
    state.viewerMediaId = item.client_message_id
    if (item.kind === "video") {
      const video = document.createElement("video")
      video.src = url
      video.controls = true
      video.playsInline = true
      video.preload = "metadata"
      video.setAttribute("aria-label", "Normal video")
      content.replaceChildren(video)
    } else {
      const img = document.createElement("img")
      img.src = url
      img.alt = "Normal photo"
      content.replaceChildren(img)
    }
    viewer.hidden = false
    byId("normal-media-viewer-close")?.focus()
  } catch (_error) {
    announce("This media is no longer available in the current Conversation.")
  }
}

async function renderMedia(item, runtime) {
  if (!item?.client_message_id || !item?.kind) return
  const container = byId("messages")
  if (!container) return
  if (container.querySelector(`[data-normal-media-id="${item.client_message_id}"]`)) {
    state.renderedIds.add(item.client_message_id)
    return
  }

  const node = document.createElement("li")
  node.className = `message normal-media-message${item.mine ? " mine" : ""}`
  node.dataset.normalMediaId = item.client_message_id
  node.dataset.normalMediaSequence = String(item.sequence || "")
  node.tabIndex = 0

  const card = document.createElement("div")
  card.className = "normal-media-card"
  const label = document.createElement("strong")
  label.textContent = normalMediaLabel(item.kind)
  const meta = document.createElement("span")
  meta.className = "normal-media-meta"
  meta.textContent = "Normal · reopenable while this Conversation is available"
  card.append(label)

  if (item.kind === "photo") {
    const img = document.createElement("img")
    img.alt = item.mine ? "Photo you sent" : "Photo from Stranger"
    img.loading = "lazy"
    const open = document.createElement("button")
    open.type = "button"
    open.textContent = "Open photo"
    open.addEventListener("click", () => openViewer(item, runtime, open))
    card.append(img, open)
    mediaUrl(runtime, item).then((url) => {
      if (node.isConnected && state.activeConversationId === runtime.conversationId) img.src = url
    }).catch(() => {
      open.disabled = true
      open.textContent = "Photo unavailable"
    })
  } else {
    const video = document.createElement("video")
    video.controls = true
    video.playsInline = true
    video.preload = "metadata"
    video.setAttribute("aria-label", item.mine ? "Video you sent" : "Video from Stranger")
    mediaUrl(runtime, item).then((url) => {
      if (node.isConnected && state.activeConversationId === runtime.conversationId) video.src = url
    }).catch(() => {
      video.replaceWith(document.createTextNode("Video unavailable"))
    })
    card.append(video)
  }

  card.append(meta)
  node.append(card)
  container.append(node)
  state.renderedIds.add(item.client_message_id)
}

async function reconcile() {
  if (state.polling) return
  state.polling = true
  try {
    const runtime = await currentRuntime()
    if (!runtime) {
      if (state.activeConversationId) transitionConversation(null)
      return
    }

    transitionConversation(runtime.conversationId)
    const response = await fetch(
      `/api/conversations/${encodeURIComponent(runtime.conversationId)}/normal-media`,
      {headers: {authorization: `Bearer ${runtime.token}`}, cache: "no-store"}
    )

    if (response.status === 410 || response.status === 404 || response.status === 403) {
      transitionConversation(null)
      return
    }
    if (!response.ok) return

    const payload = await response.json()
    for (const item of dedupeNormalMedia(payload.items)) await renderMedia(item, runtime)
  } catch (_error) {
    // Reconnect polling is intentionally quiet; the main Conversation UI owns connection messaging.
  } finally {
    state.polling = false
  }
}

function start() {
  injectStyles()
  injectUi()
  reconcile()
  state.pollTimer = window.setInterval(reconcile, POLL_MS)
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, {once: true})
  } else {
    start()
  }
}
