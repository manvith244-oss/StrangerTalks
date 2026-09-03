import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

const html = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const app = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const css = readFileSync(new URL("../../priv/static/assets/app.css", import.meta.url), "utf8")
const source = `${html}\n${app}`

const exactCopy = [
  "Temporary Conversation",
  "This Conversation isn't kept as a permanent chat history. StrangerTalks temporarily keeps enough recent Conversation information to keep the chat working and help it recover from a short connection interruption.",
  "How this works",
  "Learn what happens to this Conversation when it ends",
  "How this Conversation works",
  "Temporary by design",
  "This is a temporary Conversation, not a permanent chat-history thread.",
  "While it's active or recoverable, StrangerTalks keeps enough recent Conversation information for messaging, delivery, and reconnect to work.",
  "If your connection drops",
  "A short connection interruption doesn't automatically end the Conversation. StrangerTalks may be able to reconnect you and restore the current Conversation.",
  "When the Conversation ends",
  "When the Conversation ends, the live temporary Conversation is no longer available as an active Conversation. StrangerTalks also removes the server-owned voice-note audio for that Conversation.",
  "If a participant chooses to keep a local Conversation copy on their own device, that copy has a separate local lifetime; Fade removes that participant-local transcript and summary.",
  "Safety reports are different",
  "If you submit a safety report, that report is stored separately and can remain after the Conversation ends.",
  "An unsent text message may be kept temporarily inside the active Conversation for safety reporting. If that unsent message is reported while the safety copy is still available, the specific message text may be stored with the report.",
  "The current report flow does not automatically save the ordinary chat transcript, Reply structure, GIF or sticker choice, voice-note identity or audio, or the surrounding Conversation history into the report.",
  "Limited safety evidence is minimized or deleted on its own safety-retention schedule. Unsend or Fade can remove participant-visible or local content, but they do not erase safety evidence already authorized for safety handling.",
  "The other person can still keep what they receive",
  "Temporary doesn't mean the other participant cannot save what they see or hear. They can take screenshots, record their screen, copy text, photograph the screen, or otherwise keep information outside StrangerTalks.",
  "The other participant can still keep information they receive—for example by taking a screenshot, recording the screen, copying text, photographing the screen, or saving it another way. StrangerTalks can't remove copies they keep outside the temporary Conversation.",
  "Reconnecting…",
  "Your Conversation may still recover.",
  "End this Conversation?",
  "This ends the live temporary Conversation. Its ordinary Conversation history won't remain available as an active chat, and StrangerTalks will remove the server-owned voice-note audio for this Conversation.",
  "Safety reports are stored separately, and copies already saved on either participant's device can remain.",
  "End Conversation",
  "Cancel",
  "This Conversation can't be restored",
  "The live Conversation is no longer available to recover.",
  "This doesn't mean copies already saved on a participant's device or separate safety records have been removed.",
  "About this report",
  "Reports are stored separately for safety and can remain after this Conversation ends.",
  "Submitting this report does not automatically save the ordinary Conversation transcript, Reply structure, GIF or sticker choice, voice-note identity or audio, or surrounding chat history into the report.",
  "Limited safety evidence is minimized or deleted on its own safety-retention schedule. Unsend or Fade can remove participant-visible or local content, but they do not erase safety evidence already authorized for safety handling.",
  "Submit Report"
]

function oneLMarkup() {
  const selectors = [
    /<aside class="temporary-entry"[\s\S]*?<\/aside>/,
    /<div class="temporary-conversation-cue"[\s\S]*?<\/div>/,
    /<section data-screen="unrecoverable"[\s\S]*?<\/section>/,
    /<div id="lifetime-details-backdrop"[\s\S]*?<div id="end-confirmation-backdrop"/,
    /<div id="end-confirmation-backdrop"[\s\S]*?<\/main>/
  ]
  return selectors.map((pattern) => html.match(pattern)?.[0] || "").join("\n") + "\n" +
    (app.match(/function initializeLifetimePresentation\(\)[\s\S]*?^}/m)?.[0] || "") + "\n" +
    (app.match(/function renderPresenceText\(\)[\s\S]*?^}/m)?.[0] || "")
}

test("Feature 1L exact-copy contract locks Surfaces A-G and claims C1-C11", () => {
  for (const copy of exactCopy) assert.ok(source.includes(copy), `missing frozen 1L copy: ${copy}`)
  assert.equal(oneLMarkup().includes("diagnostic"), false, "C12 diagnostics remain internal-only")
})

test("Feature 1L forbidden-claim contract rejects F1-F15 and stronger equivalents", () => {
  const copy = oneLMarkup().toLowerCase()
  const forbidden = [
    /nothing is stored/,
    /everything disappears (?:instantly|when you leave)/,
    /closing or refreshing[^.]*deletes everything/,
    /all copies of a voice note[^.]*deleted/,
    /reports? (?:are|is) deleted after/,
    /reports? save(?:s)? the entire conversation/,
    /nothing from a conversation is stored in postgresql/,
    /(?:completely|fully) private/,
    /impossible to save/,
    /deleted from every device/,
    /gone forever/,
    /server restart deletes everything/,
    /securely (?:deleted|erased|removed)/,
    /(?:wiped|destroyed) everywhere/,
    /nothing remains/,
    /cannot be saved/,
    /prevents? (?:screenshots|recordings)/
  ]
  for (const claim of forbidden) assert.doesNotMatch(copy, claim)
})

test("Feature 1L presentation owns accessible dialogs, report disclosure, and terminal distinction", () => {
  assert.match(html, /id="lifetime-details-dialog"[^>]*role="dialog"[^>]*aria-modal="true"/)
  assert.match(html, /id="end-confirmation-dialog"[^>]*role="dialog"[^>]*aria-modal="true"/)
  assert.match(html, /data-lifetime-details[^>]*aria-haspopup="dialog"[^>]*aria-controls="lifetime-details-dialog"/)
  assert.match(app, /event\.key === "Escape"/)
  assert.match(app, /event\.key !== "Tab"/)
  assert.match(app, /returnFocus\?\.focus\(\)/)
  assert.match(app, /return show\("unrecoverable"\)/)
  assert.match(app, /push\(app\.conversation, "conversation:end"\)/)
  assert.match(app, /const payload = \{category, evidence: app\.reportTargetMessageId \? null/)
  assert.match(app, /push\(app\.conversation, "conversation:report", payload\)/)
})

test("Feature 1L adds no privacy tracking, persistence, sync, or server event", () => {
  for (const event of ["opened_privacy_sheet", "privacy_read_duration", "viewed_report_retention", "dismissed_ephemeral_notice"]) {
    assert.equal(source.includes(event), false)
  }
  assert.doesNotMatch(app, /push\([^\n]+"[^"\n]*(?:privacy|lifetime|ephemeral|temporary)[^"\n]*"/i)
  const presentation = ["disclosureFocusables", "openDisclosureDialog", "closeDisclosureDialog", "handleDisclosureDialogKeydown", "initializeLifetimePresentation"]
    .map((name) => app.match(new RegExp(`function ${name}\\([^]*?\\n}`))?.[0] || "")
    .join("\n")
  assert.doesNotMatch(presentation, /putRecord|deleteRecord|localStorage|indexedDB|push\(/)
  assert.doesNotMatch(presentation, /sync:reconcile|phx_join|analytics|telemetry/i)
})

test("Feature 1L device and accessibility CSS is text-first and responsive", () => {
  assert.match(css, /\.dialog-backdrop[\s\S]*position: fixed/)
  assert.match(css, /\.lifetime-dialog,[\s\S]*max-height:[^;]+;[\s\S]*overflow-y: auto/)
  assert.match(css, /\.text-action[\s\S]*min-height: 2\.75rem/)
  assert.match(css, /@media \(max-width: 40rem\)[\s\S]*\.report-form/)
  assert.match(css, /@media \(forced-colors: active\)[\s\S]*\.lifetime-dialog/)
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/)
})
