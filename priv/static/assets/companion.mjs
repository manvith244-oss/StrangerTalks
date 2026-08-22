import {activeConversations, getRecord, listRecords} from "./local_data.mjs"

const IDENTITY_KEY = "strangertalks.identity.v1"
const MAX_REQUEST_CHARS = 800
const MODES = Object.freeze([
  ["respond", "Help me reply"],
  ["continue", "Keep this going"],
  ["change_topic", "Change topic"],
  ["rephrase", "Rephrase my draft"],
  ["simplify", "Make this easier to say"],
  ["language_help", "Language help"],
  ["clarify", "Help me clarify"],
  ["deescalate", "De-escalate"],
  ["express_feeling", "Express a feeling"],
  ["icebreaker", "Give us an icebreaker"],
  ["story_prompt", "Give us something to talk about"]
])
const TONES = Object.freeze(["natural", "warm", "funny", "direct", "thoughtful", "light", "gentle", "confident"])

export function buildCompanionPayload({mode, request, draft, tone}) {
  const normalizedMode = typeof mode === "string" ? mode.trim().toLowerCase() : ""
  const normalizedTone = typeof tone === "string" ? tone.trim().toLowerCase() : "natural"
  const normalizedRequest = typeof request === "string" ? request.trim() : ""
  const normalizedDraft = typeof draft === "string" ? draft : ""

  if (!MODES.some(([id]) => id === normalizedMode)) throw new Error("invalid_mode")
  if (!TONES.includes(normalizedTone)) throw new Error("invalid_tone")
  if (normalizedRequest.length > MAX_REQUEST_CHARS) throw new Error("request_too_large")

  const payload = {mode: normalizedMode, tone: normalizedTone}
  if (normalizedRequest) payload.request = normalizedRequest
  if (normalizedDraft) payload.draft = normalizedDraft
  return payload
}

export function applyCompanionSuggestion({requestDraft, currentDraft, suggestion}) {
  if (typeof suggestion !== "string" || !suggestion.trim()) return {status: "invalid", draft: currentDraft}
  if (currentDraft !== requestDraft) return {status: "blocked_stale_draft", draft: currentDraft}
  return {status: "applied", draft: suggestion.trim()}
}

function newestActiveConversation(records) {
  return activeConversations(records)
    .slice()
    .sort((a, b) => Date.parse(b.updated_at || 0) - Date.parse(a.updated_at || 0))[0] || null
}

async function authority() {
  const [identity, records] = await Promise.all([getRecord(IDENTITY_KEY), listRecords()])
  const conversation = newestActiveConversation(records)
  if (!identity?.value?.token || !conversation?.value?.conversation_id) throw new Error("authority_unavailable")
  return {token: identity.value.token, conversationId: conversation.value.conversation_id}
}

function injectStyles() {
  if (document.getElementById("companion-styles")) return
  const style = document.createElement("style")
  style.id = "companion-styles"
  style.textContent = `
    .companion-panel{margin-top:.6rem;padding:.85rem;border:1px solid rgba(255,252,235,.18);border-radius:16px;background:rgba(18,20,28,.96)}
    .companion-head{display:flex;align-items:flex-start;justify-content:space-between;gap:.75rem}.companion-head h2{margin:.15rem 0}.companion-head p{margin:.15rem 0 .65rem;color:var(--muted,#b8b6ae)}
    .companion-grid{display:grid;grid-template-columns:1fr 1fr;gap:.55rem}.companion-panel label{display:grid;gap:.3rem;font-size:.9rem}.companion-panel select,.companion-panel textarea{width:100%}
    .companion-request{grid-column:1/-1;min-height:72px}.companion-actions{display:flex;gap:.5rem;align-items:center;margin-top:.65rem;flex-wrap:wrap}.companion-status{min-height:1.2rem;margin:.55rem 0 0;color:var(--muted,#b8b6ae)}
    .companion-suggestions{display:grid;gap:.55rem;margin-top:.7rem}.companion-suggestion{padding:.7rem;border:1px solid rgba(255,252,235,.14);border-radius:12px}.companion-suggestion strong{display:block;margin-bottom:.3rem}.companion-suggestion p{margin:.15rem 0 .55rem;white-space:pre-wrap}.companion-badge{font-size:.78rem;opacity:.72}
    @media(max-width:640px){.companion-grid{grid-template-columns:1fr}}
  `
  document.head.append(style)
}

function createUi() {
  const controls = document.querySelector("#message-form .voice-controls")
  const input = document.querySelector("#message-input")
  if (!controls || !input || document.getElementById("companion-control")) return

  injectStyles()

  const button = document.createElement("button")
  button.id = "companion-control"
  button.type = "button"
  button.textContent = "Ask StrangerTalks"
  button.setAttribute("aria-expanded", "false")
  button.setAttribute("aria-controls", "companion-panel")
  controls.prepend(button)

  const panel = document.createElement("section")
  panel.id = "companion-panel"
  panel.className = "companion-panel"
  panel.hidden = true
  panel.setAttribute("role", "dialog")
  panel.setAttribute("aria-modal", "false")
  panel.setAttribute("aria-labelledby", "companion-title")

  const modeOptions = MODES.map(([id, label]) => `<option value="${id}">${label}</option>`).join("")
  const toneOptions = TONES.map((tone) => `<option value="${tone}">${tone[0].toUpperCase()}${tone.slice(1)}</option>`).join("")

  panel.innerHTML = `
    <div class="companion-head"><div><span class="companion-badge">StrangerTalks Companion</span><h2 id="companion-title">Need a hand?</h2><p>Suggestions stay in your draft until you choose to Send.</p></div><button id="companion-close" type="button" aria-label="Close StrangerTalks Companion">Close</button></div>
    <div class="companion-grid">
      <label>Help with<select id="companion-mode">${modeOptions}</select></label>
      <label>Tone<select id="companion-tone">${toneOptions}</select></label>
      <label class="companion-request">What do you want help with?<textarea id="companion-request" maxlength="${MAX_REQUEST_CHARS}" placeholder="Example: How can I disagree without sounding rude?"></textarea></label>
    </div>
    <div class="companion-actions"><button id="companion-generate" type="button" class="primary">Get suggestions</button><button id="companion-cancel" type="button" hidden>Cancel</button></div>
    <p id="companion-status" class="companion-status" role="status" aria-live="polite"></p>
    <div id="companion-suggestions" class="companion-suggestions"></div>
  `

  controls.parentElement.append(panel)

  const close = () => {
    panel.hidden = true
    button.setAttribute("aria-expanded", "false")
    button.focus()
  }

  button.addEventListener("click", () => {
    const opening = panel.hidden
    panel.hidden = !opening
    button.setAttribute("aria-expanded", String(opening))
    if (opening) panel.querySelector("#companion-mode")?.focus()
  })
  panel.querySelector("#companion-close")?.addEventListener("click", close)

  let generation = 0
  let controller = null
  let requestDraft = ""

  const status = panel.querySelector("#companion-status")
  const suggestionsNode = panel.querySelector("#companion-suggestions")
  const generateButton = panel.querySelector("#companion-generate")
  const cancelButton = panel.querySelector("#companion-cancel")

  cancelButton.addEventListener("click", () => {
    generation += 1
    controller?.abort()
    controller = null
    generateButton.disabled = false
    cancelButton.hidden = true
    status.textContent = "Cancelled."
  })

  generateButton.addEventListener("click", async () => {
    generation += 1
    const mine = generation
    controller?.abort()
    controller = new AbortController()
    requestDraft = input.value
    suggestionsNode.replaceChildren()
    status.textContent = "Thinking…"
    generateButton.disabled = true
    cancelButton.hidden = false

    try {
      const auth = await authority()
      const payload = buildCompanionPayload({
        mode: panel.querySelector("#companion-mode").value,
        tone: panel.querySelector("#companion-tone").value,
        request: panel.querySelector("#companion-request").value,
        draft: requestDraft
      })

      const response = await fetch(`/api/conversations/${encodeURIComponent(auth.conversationId)}/companion`, {
        method: "POST",
        headers: {"content-type": "application/json", authorization: `Bearer ${auth.token}`},
        body: JSON.stringify(payload),
        signal: controller.signal,
        cache: "no-store"
      })
      const body = await response.json().catch(() => ({}))
      if (mine !== generation) return
      const latest = await authority()
      if (latest.conversationId !== auth.conversationId) throw new Error("stale_conversation")

      if (!response.ok) {
        const code = body?.error?.code
        if (code === "COMPANION_STALE") throw new Error("stale_conversation")
        if (code === "COMPANION_RATE_LIMITED") throw new Error("rate_limited")
        if (code === "COMPANION_OUTPUT_REJECTED") throw new Error("output_rejected")
        throw new Error("companion_unavailable")
      }

      if (body.status === "declined") {
        status.textContent = body.reason || "StrangerTalks Companion can’t help with that request."
        return
      }

      if (!Array.isArray(body.suggestions) || body.suggestions.length === 0) throw new Error("invalid_response")
      status.textContent = "Choose one, edit it, or ignore it. Nothing is sent automatically."

      for (const suggestion of body.suggestions) {
        const card = document.createElement("div")
        card.className = "companion-suggestion"
        const label = document.createElement("strong")
        label.textContent = suggestion.style || "Suggestion"
        const text = document.createElement("p")
        text.textContent = suggestion.text || ""
        const use = document.createElement("button")
        use.type = "button"
        use.textContent = "Use in draft"
        use.addEventListener("click", () => {
          const applied = applyCompanionSuggestion({requestDraft, currentDraft: input.value, suggestion: suggestion.text})
          if (applied.status !== "applied") {
            status.textContent = "Your draft changed while this suggestion was being prepared. Generate again so nothing you typed gets overwritten."
            return
          }
          input.value = applied.draft
          input.dispatchEvent(new Event("input", {bubbles: true}))
          input.focus()
          status.textContent = "Added to your draft. Edit it if you want, then press Send when you’re ready."
        })
        card.append(label, text, use)
        suggestionsNode.append(card)
      }
    } catch (error) {
      if (mine !== generation || error?.name === "AbortError") return
      if (error?.message === "stale_conversation") status.textContent = "The Conversation changed while I was helping. Try again with the current Conversation."
      else if (error?.message === "rate_limited") status.textContent = "Too many requests right now. Give it a bit and try again."
      else if (error?.message === "output_rejected") status.textContent = "I couldn’t provide a safe suggestion for that. Try asking in a different way."
      else status.textContent = "Couldn’t help with that right now. Your Conversation still works normally."
    } finally {
      if (mine === generation) {
        controller = null
        generateButton.disabled = false
        cancelButton.hidden = true
      }
    }
  })
}

function boot() {
  createUi()
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot, {once: true})
  else boot()
}
