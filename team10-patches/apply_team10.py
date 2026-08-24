from pathlib import Path
import re

APP = Path("priv/static/assets/app.js")
INDEX = Path("priv/static/index.html")


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}")
    return text.replace(old, new, 1)


app = APP.read_text()
app = replace_once(
    app,
    'import {applyReconciliationIfCurrent, createSessionReconciliationGuard} from "./session_reconciliation_guard.mjs"\n',
    'import {applyReconciliationIfCurrent, createSessionReconciliationGuard} from "./session_reconciliation_guard.mjs"\nimport {createGifSearchGuard, gifSearchPath, insertEmojiIntoDraft, sanitizeGifResults} from "./expression_surface.mjs"\n',
    "expression helper import",
)

for old, new in [
    ('label: "A friendly wave"', 'label: "A friendly wave sticker"'),
    ('label: "A bright spark"', 'label: "A bright spark sticker"'),
    ('label: "A happy bouncing face"', 'label: "A happy bouncing animated sticker"'),
    ('label: "A calm breathing glow"', 'label: "A calm breathing animated sticker"'),
]:
    app = replace_once(app, old, new, f"catalog label {old}")

app = replace_once(
    app,
    '  activeReactionPickerTarget: null,\n',
    '  activeReactionPickerTarget: null,\n  gifSearchGuard: createGifSearchGuard(),\n  gifSearchTimer: null,\n  gifProviderAvailable: null,\n  composerEmojiPicker: null,\n  expressiveSelectionInFlight: new Set(),\n',
    "expression app state",
)

app = replace_once(
    app,
    'function markConversationAuthorityTransition() {\n  app.sessionReconciliationGuard.transition()\n}\n',
    'function markConversationAuthorityTransition() {\n  app.sessionReconciliationGuard.transition()\n  app.gifSearchGuard.invalidate()\n  closeEmojiPicker(false)\n  closeGifPicker(false)\n}\n',
    "authority invalidation",
)

app = replace_once(
    app,
    '  $("#expressive-composer").hidden = name !== "conversation"\n  if (name !== "conversation") closeExpressivePicker(false)\n',
    '  $("#expressive-composer").hidden = name !== "conversation"\n  if (name !== "conversation") {\n    app.gifSearchGuard.invalidate()\n    closeExpressivePicker(false)\n    closeEmojiPicker(false)\n    closeGifPicker(false)\n  }\n',
    "screen terminal cleanup",
)

app = replace_once(
    app,
    'function openExpressivePicker() {\n  renderExpressiveResults("")\n',
    'function openExpressivePicker() {\n  closeReactionPicker()\n  closeEmojiPicker(false)\n  closeGifPicker(false)\n  renderExpressiveResults("")\n',
    "sticker picker exclusivity",
)

close_block = '''function closeExpressivePicker(returnFocus = true) {
  const picker = $("#expressive-picker")
  if (!picker) return
  picker.hidden = true
  $("#expressive-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus && $("#expressive-open") && !$("#expressive-open").hidden) $("#expressive-open").focus()
}

async function sendExpressive(expressiveId) {'''

surface_block = '''function closeExpressivePicker(returnFocus = true) {
  const picker = $("#expressive-picker")
  if (!picker) return
  picker.hidden = true
  $("#expressive-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus && $("#expressive-open") && !$("#expressive-open").hidden) $("#expressive-open").focus()
}

async function ensureComposerEmojiPicker() {
  if (app.composerEmojiPicker) return app.composerEmojiPicker
  await import("/assets/emoji_picker/index.js")
  const picker = document.createElement("emoji-picker")
  picker.className = "composer-full-emoji-picker"
  picker.dataSource = "/assets/emoji_picker/data.json"
  picker.locale = "en"
  picker.addEventListener("emoji-click", (event) => {
    const emoji = event.detail?.unicode || event.detail?.emoji?.unicode
    if (emoji) insertComposerEmoji(emoji)
  })
  $("#emoji-picker-host")?.append(picker)
  app.composerEmojiPicker = picker
  return picker
}

function insertComposerEmoji(emoji) {
  const input = $("#message-input")
  if (!input || !app.conversation) return
  const {value, caret} = insertEmojiIntoDraft(input.value, input.selectionStart, input.selectionEnd, emoji)
  input.value = value
  input.setSelectionRange(caret, caret)
  input.dispatchEvent(new Event("input", {bubbles: true}))
  input.focus()
}

async function openEmojiPicker() {
  closeReactionPicker()
  closeExpressivePicker(false)
  closeGifPicker(false)
  const panel = $("#emoji-composer-picker")
  if (!panel || !app.conversation) return
  panel.hidden = false
  $("#emoji-open")?.setAttribute("aria-expanded", "true")
  const picker = await ensureComposerEmojiPicker()
  requestAnimationFrame(() => picker?.focus?.())
}

function closeEmojiPicker(returnFocus = true) {
  const panel = $("#emoji-composer-picker")
  if (!panel) return
  panel.hidden = true
  $("#emoji-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus) $("#message-input")?.focus()
}

function closeGifPicker(returnFocus = true) {
  const picker = $("#gif-picker")
  if (!picker) return
  picker.hidden = true
  app.gifSearchGuard.invalidate()
  clearTimeout(app.gifSearchTimer)
  app.gifSearchTimer = null
  $("#gif-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus) $("#gif-open")?.focus()
}

function setGifStatus(text, className = "") {
  const status = $("#gif-status")
  if (!status) return
  status.textContent = text
  status.className = `gif-status ${className}`.trim()
}

function renderGifResults(results, token) {
  const container = $("#gif-results")
  container.replaceChildren()
  results.forEach((result) => {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "gif-result"
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
      if (!app.gifSearchGuard.isCurrent(token, app.conversationId)) return
      const expressiveId = `gif:${result.reference}`
      sendExpressive(expressiveId, {
        id: expressiveId,
        kind: "gif",
        provider: result.provider,
        provider_asset_id: result.id,
        asset_path: result.media_url,
        label: result.label,
        width: result.width,
        height: result.height
      })
    })
    container.append(button)
  })
}

async function openGifPicker() {
  closeReactionPicker()
  closeExpressivePicker(false)
  closeEmojiPicker(false)
  const picker = $("#gif-picker")
  if (!picker || !app.conversation) return
  picker.hidden = false
  $("#gif-open")?.setAttribute("aria-expanded", "true")
  $("#gif-results")?.replaceChildren()
  setGifStatus("Checking GIF availability…")
  const conversationId = app.conversationId
  const authority = app.gifSearchGuard.begin(conversationId, "status")
  try {
    const response = await fetch("/api/gifs/status", {credentials: "same-origin"})
    const payload = await response.json().catch(() => ({}))
    if (!app.gifSearchGuard.isCurrent(authority, app.conversationId)) return
    app.gifProviderAvailable = response.ok && payload.available === true
    $("#gif-search").disabled = !app.gifProviderAvailable
    if (!app.gifProviderAvailable) {
      setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
      return
    }
    setGifStatus("Search for a GIF.")
    $("#gif-search").focus()
  } catch (_) {
    if (!app.gifSearchGuard.isCurrent(authority, app.conversationId)) return
    app.gifProviderAvailable = false
    $("#gif-search").disabled = true
    setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
  }
}

function scheduleGifSearch(query) {
  clearTimeout(app.gifSearchTimer)
  const term = String(query || "").trim()
  $("#gif-results")?.replaceChildren()
  if (!app.gifProviderAvailable) {
    setGifStatus("GIFs unavailable. Stickers, emoji, and normal messages still work.", "gif-unavailable")
    return
  }
  if (!term) {
    app.gifSearchGuard.invalidate()
    setGifStatus("Search for a GIF.")
    return
  }
  const conversationId = app.conversationId
  const token = app.gifSearchGuard.begin(conversationId, term)
  setGifStatus("Searching GIFs…")
  app.gifSearchTimer = setTimeout(async () => {
    try {
      const response = await fetch(gifSearchPath(term), {credentials: "same-origin"})
      const payload = await response.json().catch(() => ({}))
      if (!app.gifSearchGuard.isCurrent(token, app.conversationId)) return
      if (response.status === 429) {
        setGifStatus("GIF search is rate limited. Try again in a moment.")
        return
      }
      if (response.status === 503) {
        app.gifProviderAvailable = false
        $("#gif-search").disabled = true
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
      renderGifResults(results, token)
    } catch (_) {
      if (app.gifSearchGuard.isCurrent(token, app.conversationId)) setGifStatus("GIF search failed. Stickers and messages still work.")
    }
  }, 250)
}

async function sendExpressive(expressiveId, mediaOverride = null) {'''

app = replace_once(app, close_block, surface_block, "expression surface functions")

app = replace_once(
    app,
    '  const media = EXPRESSIVE_CATALOG.find((item) => item.id === expressiveId)\n  if (!media || !app.conversation) return\n  const client_message_id = crypto.randomUUID()\n',
    '  const media = mediaOverride || EXPRESSIVE_CATALOG.find((item) => item.id === expressiveId)\n  if (!media || !app.conversation) return\n  if (app.replyState) {\n    announce("Send or cancel the text reply before sending a sticker or GIF.")\n    return\n  }\n  if (app.expressiveSelectionInFlight.has(expressiveId)) return\n  app.expressiveSelectionInFlight.add(expressiveId)\n  setTimeout(() => app.expressiveSelectionInFlight.delete(expressiveId), 600)\n  const conversationChannel = app.conversation\n  const conversationId = app.conversationId\n  const epochId = app.currentEpochId\n  const client_message_id = crypto.randomUUID()\n',
    "expressive send authority",
)

app = replace_once(
    app,
    '    const reply = await push(app.conversation, "message:send", {client_message_id, message_id: client_message_id, expressive_id: expressiveId})\n    updateMessageStatus(reply)\n    await markCanonicalSequenceApplied(reply.sequence)\n',
    '    const reply = await push(conversationChannel, "message:send", {client_message_id, message_id: client_message_id, expressive_id: expressiveId})\n    if (app.conversationId !== conversationId || app.currentEpochId !== epochId || app.conversation !== conversationChannel) return\n    updateMessageStatus(reply)\n    await markCanonicalSequenceApplied(reply.sequence)\n',
    "expressive stale callback",
)

app = replace_once(
    app,
    '    updateMessageStatus({client_message_id, message_id: client_message_id, status: "failed"})\n    handleDomainError(error)\n',
    '    if (app.conversationId === conversationId && app.currentEpochId === epochId && app.conversation === conversationChannel) {\n      updateMessageStatus({client_message_id, message_id: client_message_id, status: "failed"})\n      handleDomainError(error)\n    }\n',
    "expressive failure authority",
)

app = replace_once(
    app,
    '''        const sendPayload = {
          client_message_id: msgId,
          message_id: msgId,
          content: rec.value.content
        }
        if (rec.value.reply_to_client_message_id) {
          sendPayload.reply_to_client_message_id = rec.value.reply_to_client_message_id
        }
''',
    '''        const sendPayload = {
          client_message_id: msgId,
          message_id: msgId
        }
        if (rec.value.type === "expressive") {
          const expressiveId = rec.value.expressive?.id
          if (!expressiveId) continue
          sendPayload.expressive_id = expressiveId
        } else {
          sendPayload.content = rec.value.content
          if (rec.value.reply_to_client_message_id) {
            sendPayload.reply_to_client_message_id = rec.value.reply_to_client_message_id
          }
        }
''',
    "expressive reconnect retry",
)

app = replace_once(
    app,
    '''    img.src = media.asset_path || ""
    img.alt = media.label || "Expressive media"
    img.loading = "lazy"
    img.decoding = "async"
    if (media.kind === "loop") img.classList.add("expressive-loop")
''',
    '''    img.src = media.asset_path || ""
    img.alt = media.label || "Expressive media"
    img.loading = "lazy"
    img.decoding = "async"
    if (Number.isInteger(media.width) && media.width > 0) img.width = media.width
    if (Number.isInteger(media.height) && media.height > 0) img.height = media.height
    if (media.kind === "loop") img.classList.add("expressive-loop")
    if (media.kind === "gif") img.classList.add("expressive-gif")
''',
    "expressive dimensions",
)

listener_anchor = '$("#expressive-open").addEventListener("click", () => $("#expressive-picker").hidden ? openExpressivePicker() : closeExpressivePicker())\n'
listener_insert = '''$("#emoji-open").addEventListener("click", () => $("#emoji-composer-picker").hidden ? openEmojiPicker() : closeEmojiPicker())
$("#emoji-close").addEventListener("click", () => closeEmojiPicker())
$("#emoji-composer-picker").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault()
    closeEmojiPicker()
  }
})
$("#gif-open").addEventListener("click", () => $("#gif-picker").hidden ? openGifPicker() : closeGifPicker())
$("#gif-close").addEventListener("click", () => closeGifPicker())
$("#gif-search").addEventListener("input", (event) => scheduleGifSearch(event.target.value))
$("#gif-picker").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault()
    closeGifPicker()
  }
})
document.addEventListener("pointerdown", (event) => {
  const expressiveComposer = $("#expressive-composer")
  if (!expressiveComposer || expressiveComposer.hidden || expressiveComposer.contains(event.target)) return
  closeExpressivePicker(false)
  closeEmojiPicker(false)
  closeGifPicker(false)
})
''' + listener_anchor
app = replace_once(app, listener_anchor, listener_insert, "expression listeners")

APP.write_text(app)

index = INDEX.read_text()
index = replace_once(
    index,
    '    <link rel="stylesheet" href="/assets/app.css?v=20260807_v2">\n',
    '    <link rel="stylesheet" href="/assets/app.css?v=20260807_v2">\n    <link rel="stylesheet" href="/assets/expression_surface.css?v=20260824_v1">\n',
    "expression css link",
)

old_surface = '      <div id="expressive-composer" class="expressive-composer" hidden><button id="expressive-open" type="button" aria-expanded="false" aria-controls="expressive-picker">GIFs &amp; stickers</button><section id="expressive-picker" class="expressive-picker" role="dialog" aria-label="GIFs and stickers" hidden><div class="expressive-picker-head"><label for="expressive-search">Find an expression</label><input id="expressive-search" type="search" autocomplete="off" maxlength="40"><button id="expressive-close" type="button" aria-label="Close GIFs and stickers">Close</button></div><div id="expressive-results" class="expressive-results" role="listbox" aria-label="Expressive media"></div></section></div>\n'
new_surface = '''      <div id="expressive-composer" class="expressive-composer" hidden>
        <div class="expression-actions" role="group" aria-label="Expression tools">
          <button id="emoji-open" type="button" aria-expanded="false" aria-controls="emoji-composer-picker">Emoji</button>
          <button id="expressive-open" type="button" aria-expanded="false" aria-controls="expressive-picker">Stickers</button>
          <button id="gif-open" type="button" aria-expanded="false" aria-controls="gif-picker">GIFs</button>
        </div>
        <section id="emoji-composer-picker" class="emoji-composer-picker" role="dialog" aria-label="Emoji" hidden><div class="emoji-composer-picker-head"><strong>Emoji</strong><button id="emoji-close" type="button" aria-label="Close emoji picker">Close</button></div><div id="emoji-picker-host"></div></section>
        <section id="expressive-picker" class="expressive-picker" role="dialog" aria-label="Stickers" hidden><div class="expressive-picker-head"><label for="expressive-search">Search stickers</label><input id="expressive-search" type="search" autocomplete="off" maxlength="40"><button id="expressive-close" type="button" aria-label="Close stickers">Close</button></div><div id="expressive-results" class="expressive-results" role="listbox" aria-label="Stickers"></div></section>
        <section id="gif-picker" class="gif-picker" role="dialog" aria-label="GIF search" hidden><div class="gif-picker-head"><strong>GIFs</strong><button id="gif-close" type="button" aria-label="Close GIF search">Close</button></div><label for="gif-search">Search GIFs</label><input id="gif-search" type="search" autocomplete="off" maxlength="80" disabled><div id="gif-status" class="gif-status" role="status" aria-live="polite">Checking GIF availability…</div><div id="gif-results" class="gif-results" role="listbox" aria-label="GIF results"></div></section>
      </div>
'''
index = replace_once(index, old_surface, new_surface, "expression composer markup")
INDEX.write_text(index)

print("Team 10 app/index patch applied")
