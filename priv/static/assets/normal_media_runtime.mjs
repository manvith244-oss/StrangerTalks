import {activeConversations, getRecord, listRecords} from "./local_data.mjs"
import {
  compareTimelineKeys,
  dedupeNormalMedia,
  genericTimelineKey,
  normalMediaDraftMatchesRuntime,
  normalMediaKind,
  normalMediaLabel,
  normalMediaTimelineKey,
  validNormalMediaFile
} from "./normal_media.mjs"

const IDENTITY_KEY = "strangertalks.identity.v1"
const POLL_MS = 650

const state = {
  activeConversationId: null,
  draft: null,
  previewUrl: null,
  previewGeneration: 0,
  mediaUrls: new Map(),
  renderedIds: new Set(),
  pollTimer: null,
  polling: false,
  viewerReturnFocus: null
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
  const identity = await getRecord(IDENTITY_KEY).catch(() => null)
  if (!identity?.value?.participant_id || !identity?.value?.token) return null

  const records = await listRecords().catch(() => [])
  const conversation = activeConversations(records)
    .slice()
    .sort((a, b) => String(b.updated_at || b.value?.started_at || "").localeCompare(String(a.updated_at || a.value?.started_at || "")))[0]

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
  const video = container?.querySelector("video")
  if (video) {
    video.pause()
    video.removeAttribute("src")
    video.load()
  }
  container?.replaceChildren()

  if (hide && byId("normal-media-preview")) byId("normal-media-preview").hidden = true
}

function closeViewer({restoreFocus = true} = {}) {
  const viewer = byId("normal-media-viewer")
  if (!viewer || viewer.hidden) return

  const video = viewer.querySelector("video")
  if (video) video.pause()
  viewer.hidden = true
  viewer.querySelector(".normal-media-viewer-content")?.replaceChildren()

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
    .normal-media-meta, .normal-media-mode-note { font-size: .8rem; opacity: .76; }
    .normal-media-mode-note { margin: .35rem 0 0; }
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
  const form = byId("message-form")
  if (!controls || !form) return

  const picker = document.createElement("button")
  picker.id = "normal-media-picker-btn"
  picker.type = "button"
  picker.textContent = "Photo / Video"
  picker.setAttribute("aria-describedby", "normal-media-mode-note")

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

  controls.append(picker, input)
  controls.after(note)

  form.insertAdjacentHTML(
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

  picker.addEventListener("click", () => input.click())
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
  if (!runtime || !conversationScreenActive()) {
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
      const image = document.createElement("img")
      image.src = state.previewUrl
      image.alt = "Normal photo preview"
      container.replaceChildren(image)
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
        announce("The Conversation ended. This media is no longer available here.")
        if (state.draft?.generation === draft.generation) clearPreview()
        return
      }

      if (state.draft?.generation === draft.generation) {
        if (status) status.textContent = "Send rejected. The server did not accept this media. You can retry."
        if (send) {
          send.disabled = false
          send.textContent = "Retry send"
        }
      }
      announce(`Media send was rejected${payload.error ? `: ${payload.error}` : "."}`)
      return
    }

    if (state.draft?.generation === draft.generation) {
      if (status) status.textContent = "Sent"
      clearPreview()
    }

    await renderMedia(payload, stillCurrent)
    await reconcileTimeline(stillCurrent, [payload])
    announce(`${normalMediaLabel(payload.kind)} sent.`)
  } catch (_error) {
    const stillCurrent = await currentRuntime()
    if (!stillCurrent || stillCurrent.conversationId !== draft.originConversationId) return

    if (state.draft?.generation === draft.generation) {
      if (status) status.textContent = "Send not confirmed. It may have been accepted; retry safely with the same media ID."
      if (send) {
        send.disabled = false
        send.textContent = "Retry send"
      }
    }
    announce("Media send was not confirmed. Retry is idempotent and will not create a second logical item.")
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

async function openPhoto(item, runtime, trigger) {
  const viewer = byId("normal-media-viewer")
  const content = viewer?.querySelector(".normal-media-viewer-content")
  if (!viewer || !content) return

  try {
    const url = await mediaUrl(runtime, item)
    const current = await currentRuntime()
    if (!current || current.conversationId !== runtime.conversationId || !conversationScreenActive()) return

    const image = document.createElement("img")
    image.src = url
    image.alt = item.mine ? "Photo you sent" : "Photo from Stranger"
    content.replaceChildren(image)
    state.viewerReturnFocus = trigger
    viewer.hidden = false
    byId("normal-media-viewer-close")?.focus()
  } catch (_error) {
    announce("This media is no longer available in the current Conversation.")
  }
}

async function renderMedia(item, runtime) {
  if (!item?.client_message_id || !item?.kind) return
  if (runtime.conversationId !== state.activeConversationId) transitionConversation(runtime.conversationId)

  const container = byId("messages")
  if (!container) return
  const existing = container.querySelector(`[data-normal-media-id="${CSS.escape(item.client_message_id)}"]`)
  if (existing) {
    state.renderedIds.add(item.client_message_id)
    return
  }

  const node = document.createElement("li")
  node.className = `message normal-media-message${item.mine ? " mine" : ""}`
  node.dataset.normalMediaId = item.client_message_id
  node.dataset.anchorSequence = String(item.anchor_sequence)
  node.dataset.anchorOrdinal = String(item.anchor_ordinal)
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
    const open = document.createElement("button")
    open.type = "button"
    open.textContent = "Open photo"
    open.setAttribute("aria-label", "Open photo")
    open.addEventListener("click", (event) => {
      event.stopPropagation()
      openPhoto(item, runtime, open)
    })
    card.append(open)
  } else {
    const video = document.createElement("video")
    video.controls = true
    video.playsInline = true
    video.preload = "metadata"
    video.setAttribute("aria-label", item.mine ? "Video you sent" : "Video from Stranger")
    card.append(video)
    mediaUrl(runtime, item)
      .then((url) => {
        if (!node.isConnected || state.activeConversationId !== runtime.conversationId) return
        video.src = url
        video.load()
      })
      .catch(() => {
        meta.textContent = "Normal · media unavailable"
      })
  }

  card.append(meta)
  node.append(card)
  container.append(node)
  state.renderedIds.add(item.client_message_id)
}

function recordTimelineKey(record) {
  if (!record?.value) return null
  if (record.type === "local_message") return genericTimelineKey(record.value.sequence)
  if (record.type === "local_voice_note") return genericTimelineKey(record.value.sequence)
  return null
}

function recordTimelineId(record) {
  if (!record?.value) return null
  if (record.type === "local_message") return record.value.client_message_id || record.value.message_id || null
  if (record.type === "local_voice_note") return record.value.voice_note_id || null
  return null
}

async function reconcileTimeline(runtime, mediaItems) {
  if (!runtime || runtime.conversationId !== state.activeConversationId) return
  const container = byId("messages")
  if (!container) return

  const records = await listRecords().catch(() => [])
  const genericKeys = new Map()
  for (const record of records) {
    if (record.value?.conversation_id !== runtime.conversationId) continue
    const id = recordTimelineId(record)
    const key = recordTimelineKey(record)
    if (id && key) genericKeys.set(id, key)
  }

  const mediaKeys = new Map()
  for (const item of mediaItems) {
    const key = normalMediaTimelineKey(item)
    if (key) mediaKeys.set(item.client_message_id, key)
  }

  const children = [...container.children]
  const keyed = children.map((node, originalIndex) => {
    let key = null
    if (node.dataset.normalMediaId) key = mediaKeys.get(node.dataset.normalMediaId) || null
    else if (node.dataset.messageId) key = genericKeys.get(node.dataset.messageId) || null
    else if (node.dataset.voiceNoteId) key = genericKeys.get(node.dataset.voiceNoteId) || null
    return {node, key, originalIndex}
  })

  keyed.sort((a, b) => {
    if (a.key && b.key) {
      const canonical = compareTimelineKeys(a.key, b.key)
      if (canonical !== 0) return canonical
    } else if (a.key && !b.key) {
      return -1
    } else if (!a.key && b.key) {
      return 1
    }
    return a.originalIndex - b.originalIndex
  })

  container.append(...keyed.map(({node}) => node))
}

async function syncNormalMedia() {
  if (state.polling) return
  state.polling = true

  try {
    const runtime = await currentRuntime()
    if (!runtime) {
      transitionConversation(null)
      return
    }

    transitionConversation(runtime.conversationId)
    if (!conversationScreenActive()) {
      closeViewer({restoreFocus: false})
      return
    }

    const response = await fetch(
      `/api/conversations/${encodeURIComponent(runtime.conversationId)}/normal-media`,
      {headers: {authorization: `Bearer ${runtime.token}`}, cache: "no-store"}
    )
    if (!response.ok) {
      if (response.status === 410 || response.status === 404) transitionConversation(null)
      return
    }

    const body = await response.json().catch(() => ({items: []}))
    const items = dedupeNormalMedia(body.items || [])
    const current = await currentRuntime()
    if (!current || current.conversationId !== runtime.conversationId || !conversationScreenActive()) return

    for (const item of items) await renderMedia(item, runtime)
    await reconcileTimeline(runtime, items)
  } finally {
    state.polling = false
  }
}

function startPolling() {
  if (state.pollTimer) return
  state.pollTimer = setInterval(() => syncNormalMedia().catch(() => {}), POLL_MS)
  syncNormalMedia().catch(() => {})
}

function cleanup() {
  clearPreview()
  releaseConversationUrls()
  if (state.pollTimer) clearInterval(state.pollTimer)
  state.pollTimer = null
  state.activeConversationId = null
}

function init() {
  injectStyles()
  injectUi()
  startPolling()
  window.addEventListener("beforeunload", cleanup, {once: true})
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init, {once: true})
} else {
  init()
}
