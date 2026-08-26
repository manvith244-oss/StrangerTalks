import {Socket} from "/vendor/phoenix.mjs"
import {listRecords} from "./local_data.mjs"
import {
  createGifSearchGuard,
  gifSearchPath,
  insertEmojiIntoDraft,
  sanitizeGifResults,
  sendWithSameIdentityRetry
} from "./expression_surface.mjs"

const APP_ENTRY = "/assets/app.js?v=20260807_v2"
const GIF_DEBOUNCE_MS = 250
const EXPRESSIVE_DOUBLE_TAP_MS = 600

const channelAuthority = {
  channel: null,
  conversationId: null,
  generation: 0
}

const gifSearchGuard = createGifSearchGuard()
let gifSearchTimer = null
let gifProviderAvailable = null
let emojiPickerElement = null
let lastStickerSelection = {element: null, at: 0}
let gifSelectionLock = new Map()

function currentAuthority(channel, generation, conversationId) {
  return channelAuthority.channel === channel &&
    channelAuthority.generation === generation &&
    channelAuthority.conversationId === conversationId
}

function terminateExpressionAuthority() {
  channelAuthority.generation += 1
  channelAuthority.channel = null
  channelAuthority.conversationId = null
  gifSearchGuard.invalidate()
  clearTimeout(gifSearchTimer)
  gifSearchTimer = null
  closeEmojiPicker(false)
  closeGifPicker(false)
}

function pushPromise(channel, event, payload) {
  return new Promise((resolve, reject) => {
    channel.push(event, payload)
      .receive("ok", resolve)
      .receive("error", reject)
      .receive("timeout", () => reject({reason: "timeout"}))
  })
}

function patchExpressiveRetry(channel, conversationId, generation) {
  if (channel.__team10ExpressiveRetryPatched) return
  channel.__team10ExpressiveRetryPatched = true
  const originalPush = channel.push.bind(channel)
  const originalJoin = channel.join.bind(channel)

  channel.push = function(event, payload, timeout) {
    const push = originalPush(event, payload, timeout)
    const expressiveId = event === "message:send" ? payload?.expressive_id : null

    if (typeof expressiveId === "string" && !expressiveId.startsWith("gif:")) {
      push.receive("timeout", () => {
        if (!currentAuthority(channel, generation, conversationId)) return
        originalPush(event, payload, timeout)
          .receive("error", () => {})
          .receive("timeout", () => {})
      })
    }

    return push
  }

  channel.join = function(timeout) {
    const push = originalJoin(timeout)
    push.receive("ok", () => {
      if (!currentAuthority(channel, generation, conversationId)) return
      retryAmbiguousExpressiveRecords(channel, conversationId, generation).catch(() => {})
    })
    return push
  }
}

async function retryAmbiguousExpressiveRecords(channel, conversationId, generation) {
  const records = await listRecords()
  if (!currentAuthority(channel, generation, conversationId)) return

  const pending = records.filter((record) =>
    record?.type === "local_message" &&
    record?.value?.conversation_id === conversationId &&
    record?.value?.mine === true &&
    record?.value?.type === "expressive" &&
    record?.value?.delivery_status === "sending" &&
    typeof record?.value?.expressive?.id === "string"
  )

  for (const record of pending) {
    if (!currentAuthority(channel, generation, conversationId)) return
    const messageId = record.value.client_message_id || record.value.message_id
    if (!messageId) continue
    channel.push("message:send", {
      client_message_id: messageId,
      message_id: messageId,
      expressive_id: record.value.expressive.id
    }).receive("error", () => {}).receive("timeout", () => {})
  }
}

const originalSocketChannel = Socket.prototype.channel
Socket.prototype.channel = function(topic, params) {
  const channel = originalSocketChannel.call(this, topic, params)
  if (typeof topic === "string" && topic.startsWith("conversation:")) {
    const conversationId = topic.slice("conversation:".length)
    channelAuthority.generation += 1
    channelAuthority.channel = channel
    channelAuthority.conversationId = conversationId
    gifSearchGuard.invalidate()
    const generation = channelAuthority.generation
    patchExpressiveRetry(channel, conversationId, generation)
  }
  return channel
}

await import(APP_ENTRY)
await import("/assets/mobile_flow.mjs?v=20260827_f09")
initializeExpressionSurface()

function initializeExpressionSurface() {
  const composer = document.querySelector("#expressive-composer")
  const stickerTrigger = document.querySelector("#expressive-open")
  const stickerPicker = document.querySelector("#expressive-picker")
  if (!composer || !stickerTrigger || !stickerPicker) return

  stickerTrigger.textContent = "Stickers"
  stickerTrigger.setAttribute("aria-label", "Open stickers")
  stickerPicker.setAttribute("aria-label", "Stickers")
  document.querySelector('label[for="expressive-search"]')?.replaceChildren(document.createTextNode("Search stickers"))
  document.querySelector("#expressive-results")?.setAttribute("aria-label", "Stickers")
  document.querySelector("#expressive-close")?.setAttribute("aria-label", "Close stickers")

  const actions = document.createElement("div")
  actions.className = "expression-actions"
  actions.setAttribute("role", "group")
  actions.setAttribute("aria-label", "Expression tools")

  const emojiButton = document.createElement("button")
  emojiButton.id = "emoji-open"
  emojiButton.type = "button"
  emojiButton.textContent = "Emoji"
  emojiButton.setAttribute("aria-expanded", "false")
  emojiButton.setAttribute("aria-controls", "emoji-composer-picker")

  const gifButton = document.createElement("button")
  gifButton.id = "gif-open"
  gifButton.type = "button"
  gifButton.textContent = "GIFs"
  gifButton.setAttribute("aria-expanded", "false")
  gifButton.setAttribute("aria-controls", "gif-picker")

  composer.insertBefore(actions, stickerTrigger)
  actions.append(emojiButton, stickerTrigger, gifButton)

  composer.append(buildEmojiPanel(), buildGifPanel(), buildExpressionSendStatus())

  emojiButton.addEventListener("click", () => {
    document.querySelector("#emoji-composer-picker").hidden ? openEmojiPicker() : closeEmojiPicker()
  })
  gifButton.addEventListener("click", () => {
    document.querySelector("#gif-picker").hidden ? openGifPicker() : closeGifPicker()
  })

  stickerTrigger.addEventListener("click", () => {
    closeEmojiPicker(false)
    closeGifPicker(false)
  }, true)

  document.querySelector("#expressive-results")?.addEventListener("click", guardStickerSelection, true)

  document.addEventListener("click", (event) => {
    if (event.target.closest(".react-action-btn, .reaction-picker")) {
      closeEmojiPicker(false)
      closeGifPicker(false)
    }
  }, true)

  document.addEventListener("pointerdown", (event) => {
    const emojiPanel = document.querySelector("#emoji-composer-picker")
    const gifPanel = document.querySelector("#gif-picker")
    if (emojiPanel && !emojiPanel.hidden && !emojiPanel.contains(event.target) && !emojiButton.contains(event.target)) {
      closeEmojiPicker(false)
    }
    if (gifPanel && !gifPanel.hidden && !gifPanel.contains(event.target) && !gifButton.contains(event.target)) {
      closeGifPicker(false)
    }
  })

  document.querySelector("#block")?.addEventListener("click", terminateExpressionAuthority, true)
  document.querySelector("#end-confirm")?.addEventListener("click", terminateExpressionAuthority, true)

  const observer = new MutationObserver(() => {
    if (composer.hidden) terminateExpressionAuthority()
  })
  observer.observe(composer, {attributes: true, attributeFilter: ["hidden"]})
}

function buildExpressionSendStatus() {
  const status = document.createElement("p")
  status.id = "expression-send-status"
  status.className = "expression-send-status"
  status.setAttribute("role", "status")
  status.setAttribute("aria-live", "polite")
  status.hidden = true
  return status
}

function setExpressionSendStatus(message) {
  const status = document.querySelector("#expression-send-status")
  if (!status) return
  status.textContent = message
  status.hidden = !message
}

function buildEmojiPanel() {
  const panel = document.createElement("section")
  panel.id = "emoji-composer-picker"
  panel.className = "emoji-composer-picker"
  panel.hidden = true
  panel.setAttribute("role", "dialog")
  panel.setAttribute("aria-label", "Emoji")
  panel.innerHTML = '<div class="emoji-composer-picker-head"><strong>Emoji</strong><button id="emoji-close" type="button" aria-label="Close emoji picker">Close</button></div><div id="emoji-picker-host"></div>'
  panel.querySelector("#emoji-close").addEventListener("click", () => closeEmojiPicker())
  panel.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault()
      closeEmojiPicker()
    }
  })
  return panel
}

async function ensureEmojiPicker() {
  if (emojiPickerElement) return emojiPickerElement
  await import("/assets/emoji_picker/index.js")
  const picker = document.createElement("emoji-picker")
  picker.className = "composer-full-emoji-picker"
  picker.dataSource = "/assets/emoji_picker/data.json"
  picker.locale = "en"
  picker.addEventListener("emoji-click", (event) => {
    const emoji = event.detail?.unicode || event.detail?.emoji?.unicode
    if (emoji) insertComposerEmoji(emoji)
  })
  document.querySelector("#emoji-picker-host")?.append(picker)
  emojiPickerElement = picker
  return picker
}

async function openEmojiPicker() {
  closeGifPicker(false)
  if (!document.querySelector("#expressive-picker")?.hidden) document.querySelector("#expressive-close")?.click()
  const panel = document.querySelector("#emoji-composer-picker")
  if (!panel || !channelAuthority.channel) return
  panel.hidden = false
  document.querySelector("#emoji-open")?.setAttribute("aria-expanded", "true")
  const picker = await ensureEmojiPicker()
  requestAnimationFrame(() => picker?.focus?.())
}

function closeEmojiPicker(returnFocus = true) {
  const panel = document.querySelector("#emoji-composer-picker")
  if (!panel) return
  panel.hidden = true
  document.querySelector("#emoji-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus) document.querySelector("#message-input")?.focus()
}

function insertComposerEmoji(emoji) {
  const input = document.querySelector("#message-input")
  if (!input || !channelAuthority.channel) return
  const result = insertEmojiIntoDraft(input.value, input.selectionStart, input.selectionEnd, emoji)
  input.value = result.value
  input.setSelectionRange(result.caret, result.caret)
  input.dispatchEvent(new Event("input", {bubbles: true}))
  input.focus()
}

function buildGifPanel() {
  const panel = document.createElement("section")
  panel.id = "gif-picker"
  panel.className = "gif-picker"
  panel.hidden = true
  panel.setAttribute("role", "dialog")
  panel.setAttribute("aria-label", "GIF search")
  panel.innerHTML = '<div class="gif-picker-head"><strong>GIFs</strong><button id="gif-close" type="button" aria-label="Close GIF search">Close</button></div><label for="gif-search">Search GIFs</label><input id="gif-search" type="search" autocomplete="off" maxlength="80" disabled><div id="gif-status" class="gif-status" role="status" aria-live="polite">Checking GIF availability…</div><div id="gif-results" class="gif-results" role="listbox" aria-label="GIF results"></div>'
  panel.querySelector("#gif-close").addEventListener("click", () => closeGifPicker())
  panel.querySelector("#gif-search").addEventListener("input", (event) => scheduleGifSearch(event.target.value))
  panel.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault()
      closeGifPicker()
    }
  })
  return panel
}

function setGifStatus(message, className = "") {
  const status = document.querySelector("#gif-status")
  if (!status) return
  status.textContent = message
  status.className = `gif-status ${className}`.trim()
}

async function openGifPicker() {
  closeEmojiPicker(false)
  if (!document.querySelector("#expressive-picker")?.hidden) document.querySelector("#expressive-close")?.click()
  const panel = document.querySelector("#gif-picker")
  const search = document.querySelector("#gif-search")
  if (!panel || !search || !channelAuthority.channel) return
  panel.hidden = false
  document.querySelector("#gif-open")?.setAttribute("aria-expanded", "true")
  document.querySelector("#gif-results")?.replaceChildren()
  search.value = ""
  search.disabled = true
  setGifStatus("Checking GIF availability…")

  const conversationId = channelAuthority.conversationId
  const generation = channelAuthority.generation
  const token = gifSearchGuard.begin(conversationId, "status")

  try {
    const response = await fetch("/api/gifs/status", {credentials: "same-origin"})
    const payload = await response.json().catch(() => ({}))
    if (!gifSearchGuard.isCurrent(token, channelAuthority.conversationId) || generation !== channelAuthority.generation) return
    gifProviderAvailable = response.ok && payload.available === true
    search.disabled = !gifProviderAvailable
    if (!gifProviderAvailable) {
      setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
      return
    }
    setGifStatus("Search for a GIF.")
    search.focus()
  } catch (_) {
    if (!gifSearchGuard.isCurrent(token, channelAuthority.conversationId) || generation !== channelAuthority.generation) return
    gifProviderAvailable = false
    search.disabled = true
    setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
  }
}

function closeGifPicker(returnFocus = true) {
  const panel = document.querySelector("#gif-picker")
  if (!panel) return
  panel.hidden = true
  gifSearchGuard.invalidate()
  clearTimeout(gifSearchTimer)
  gifSearchTimer = null
  document.querySelector("#gif-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus) document.querySelector("#gif-open")?.focus()
}

function scheduleGifSearch(rawQuery) {
  clearTimeout(gifSearchTimer)
  const query = String(rawQuery || "").trim()
  document.querySelector("#gif-results")?.replaceChildren()

  if (!gifProviderAvailable) {
    setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
    return
  }
  if (!query) {
    gifSearchGuard.invalidate()
    setGifStatus("Search for a GIF.")
    return
  }

  const conversationId = channelAuthority.conversationId
  const generation = channelAuthority.generation
  const token = gifSearchGuard.begin(conversationId, query)
  setGifStatus("Searching GIFs…")

  gifSearchTimer = setTimeout(async () => {
    try {
      const response = await fetch(gifSearchPath(query), {credentials: "same-origin"})
      const payload = await response.json().catch(() => ({}))
      if (!gifSearchGuard.isCurrent(token, channelAuthority.conversationId) || generation !== channelAuthority.generation) return

      if (response.status === 429) {
        setGifStatus("GIF search is rate limited. Try again in a moment.")
        return
      }
      if (response.status === 503) {
        gifProviderAvailable = false
        document.querySelector("#gif-search").disabled = true
        setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
        return
      }
      if (!response.ok) {
        setGifStatus("GIF search failed. Try another search.")
        return
      }

      const results = sanitizeGifResults(payload.results)
      if (!results.length) {
        setGifStatus("No GIFs found. Try another search.")
        return
      }
      setGifStatus(`${results.length} GIF${results.length === 1 ? "" : "s"} found.`)
      renderGifResults(results, token, generation)
    } catch (_) {
      if (gifSearchGuard.isCurrent(token, channelAuthority.conversationId) && generation === channelAuthority.generation) {
        setGifStatus("GIF search failed. Stickers and messages still work.")
      }
    }
  }, GIF_DEBOUNCE_MS)
}

function renderGifResults(results, token, generation) {
  const container = document.querySelector("#gif-results")
  if (!container) return
  container.replaceChildren()

  for (const result of results) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "gif-result"
    button.setAttribute("role", "option")
    button.setAttribute("aria-label", result.label)

    const image = document.createElement("img")
    image.src = result.media_url
    image.alt = result.label
    image.loading = "lazy"
    image.decoding = "async"
    image.width = result.width
    image.height = result.height
    image.addEventListener("error", () => {
      const fallback = document.createElement("span")
      fallback.className = "expression-media-placeholder"
      fallback.textContent = "GIF unavailable"
      image.replaceWith(fallback)
      button.disabled = true
    }, {once: true})
    button.append(image)

    button.addEventListener("click", () => {
      if (!gifSearchGuard.isCurrent(token, channelAuthority.conversationId) || generation !== channelAuthority.generation) return
      sendGif(result).catch(() => {})
    })
    container.append(button)
  }
}

function replyIsActive() {
  const staging = document.querySelector("#reply-staging")
  return Boolean(staging && !staging.hidden)
}

function guardStickerSelection(event) {
  const button = event.target.closest("button")
  if (!button) return

  if (replyIsActive()) {
    event.preventDefault()
    event.stopImmediatePropagation()
    setExpressionSendStatus("Send or cancel the text reply before sending a sticker.")
    return
  }

  const now = performance.now()
  if (lastStickerSelection.element === button && now - lastStickerSelection.at < EXPRESSIVE_DOUBLE_TAP_MS) {
    event.preventDefault()
    event.stopImmediatePropagation()
    return
  }
  lastStickerSelection = {element: button, at: now}
}

async function sendGif(result) {
  if (replyIsActive()) {
    setExpressionSendStatus("Send or cancel the text reply before sending a GIF.")
    return
  }

  const lockKey = result.reference
  if (gifSelectionLock.has(lockKey)) return
  gifSelectionLock.set(lockKey, performance.now())
  setTimeout(() => gifSelectionLock.delete(lockKey), EXPRESSIVE_DOUBLE_TAP_MS)

  const channel = channelAuthority.channel
  const conversationId = channelAuthority.conversationId
  const generation = channelAuthority.generation
  if (!channel || !conversationId) return

  const clientMessageId = crypto.randomUUID()
  const payload = {
    client_message_id: clientMessageId,
    message_id: clientMessageId,
    expressive_id: `gif:${result.reference}`
  }

  closeGifPicker(false)
  setExpressionSendStatus("Sending GIF…")

  try {
    await sendWithSameIdentityRetry(
      (samePayload) => pushPromise(channel, "message:send", samePayload),
      payload
    )
    if (!currentAuthority(channel, generation, conversationId)) return
    setExpressionSendStatus("GIF sent.")
  } catch (error) {
    if (!currentAuthority(channel, generation, conversationId)) return
    setExpressionSendStatus(error?.reason === "timeout" ? "GIF send timed out. Try again." : "GIF was not sent.")
  }
}
