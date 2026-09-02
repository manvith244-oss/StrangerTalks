import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {ATMOSPHERES} from "../../priv/static/assets/atmospheres.mjs"
import {
  PROMPT_CATALOG, PROMPT_CATEGORIES, approvedPrompt, approvedPromptCategory,
  initialPromptCardState, insertPromptDraft, promptsForCategory, transitionPromptCards
} from "../../priv/static/assets/prompt_cards.mjs"

const appSource = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const cssSource = readFileSync(new URL("../../priv/static/assets/app.css", import.meta.url), "utf8")
const htmlSource = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const promptModuleSource = readFileSync(new URL("../../priv/static/assets/prompt_cards.mjs", import.meta.url), "utf8")
const promptRuntimeSource = appSource.slice(appSource.indexOf("function renderPromptDraftAvailability"), appSource.indexOf("function setAtmosphere"))
const promptUseSource = appSource.slice(appSource.indexOf("function useSelectedPrompt"), appSource.indexOf("function resetPromptCards"))
const messageSubmitSource = appSource.slice(appSource.indexOf('$("#message-form").addEventListener("submit"'), appSource.indexOf('$("#message-input").addEventListener("keydown"'))
const promptCssSource = cssSource.slice(cssSource.indexOf('section[data-screen="conversation"] #prompt-control'), cssSource.indexOf('section[data-screen="conversation"] .voice-privacy'))

const expectedCatalog = [
  ["start-1", "start", "What’s something you’ve been thinking about lately?"],
  ["start-2", "start", "What kind of day are you having so far?"],
  ["start-3", "start", "What’s something you could talk about for hours?"],
  ["start-4", "start", "What’s one small thing that made your day better recently?"],
  ["continue-1", "continue", "What makes you say that?"],
  ["continue-2", "continue", "How did that change things for you?"],
  ["continue-3", "continue", "What part of that matters most to you?"],
  ["continue-4", "continue", "If you could change one thing about it, what would you change?"],
  ["recover-1", "recover", "Want to switch topics — what’s been on your mind lately?"],
  ["recover-2", "recover", "Random question: what’s something you’re looking forward to?"],
  ["recover-3", "recover", "Let’s reset — tell me something about you I wouldn’t guess."],
  ["recover-4", "recover", "New topic? What’s something you’ve enjoyed recently?"]
]

test("1J catalog is exactly the approved bounded Start, Continue, and Recover copy", () => {
  assert.deepEqual(PROMPT_CATEGORIES.map(({id, label}) => [id, label]), [
    ["start", "Start"], ["continue", "Continue"], ["recover", "Recover"]
  ])
  assert.deepEqual(PROMPT_CATALOG.map(({id, categoryId, text}) => [id, categoryId, text]), expectedCatalog)
  assert.equal(PROMPT_CATALOG.length, 12)
  assert.equal(new Set(PROMPT_CATALOG.map(({id}) => id)).size, 12)
  for (const category of PROMPT_CATEGORIES) assert.equal(promptsForCategory(category.id).length, 4)
})

test("1J approved identities reject unknown categories and prompts", () => {
  assert.equal(approvedPromptCategory("start")?.label, "Start")
  assert.equal(approvedPrompt("recover-4")?.text, expectedCatalog.at(-1)[2])
  assert.equal(approvedPromptCategory("stalled"), null)
  assert.equal(approvedPrompt("https://example.test/generated"), null)
  assert.deepEqual(promptsForCategory("unknown"), [])
})

test("1J local controller proves OPEN, CLOSE, SELECT, RESET, NO_OP, and invalid fallback", () => {
  const initial = initialPromptCardState()
  const opened = transitionPromptCards(initial, {type: "open"})
  assert.deepEqual(opened, {status: "opened", state: {...initial, open: true}})
  assert.equal(transitionPromptCards(opened.state, {type: "open"}).status, "no_op")

  const category = transitionPromptCards(opened.state, {type: "select_category", categoryId: "recover"})
  assert.deepEqual(category, {status: "selected", state: {open: true, categoryId: "recover", promptId: "recover-1"}})
  const selected = transitionPromptCards(category.state, {type: "select_prompt", promptId: "recover-3"})
  assert.equal(selected.status, "selected")
  assert.equal(transitionPromptCards(selected.state, {type: "select_prompt", promptId: "recover-3"}).status, "no_op")
  assert.deepEqual(transitionPromptCards(selected.state, {type: "select_prompt", promptId: "made-up"}), {status: "invalid", state: selected.state})
  assert.equal(transitionPromptCards(selected.state, {type: "close"}).status, "closed")
  assert.deepEqual(transitionPromptCards(selected.state, {type: "reset"}).state, initial)
})

test("1J inserts approved text into an empty editable draft without sending", () => {
  assert.deepEqual(insertPromptDraft("", "continue-2"), {
    status: "inserted",
    draft: "How did that change things for you?"
  })
  assert.doesNotMatch(promptRuntimeSource, /requestSubmit|dispatchEvent|message:send|push\(|fetch\(/)
  assert.match(promptUseSource, /input\.value = insertion\.draft/)
  assert.match(promptUseSource, /input\.focus\(\)/)
})

test("1J never overwrites a non-empty participant draft, including whitespace", () => {
  assert.deepEqual(insertPromptDraft("my own draft", "start-1"), {status: "blocked_non_empty", draft: "my own draft"})
  assert.deepEqual(insertPromptDraft(" ", "start-1"), {status: "blocked_non_empty", draft: " "})
  assert.deepEqual(insertPromptDraft("my own draft", "unknown"), {status: "invalid", draft: "my own draft"})
  assert.match(appSource, /const hasDraft = input\.value\.length > 0/)
  assert.match(appSource, /useButton\.disabled = hasDraft/)
})

test("1J tab state is independent and reset returns the closed Start default", () => {
  const tabA = transitionPromptCards(initialPromptCardState(), {type: "select_category", categoryId: "recover"}).state
  const tabB = transitionPromptCards(initialPromptCardState(), {type: "select_category", categoryId: "continue"}).state
  assert.equal(tabA.categoryId, "recover")
  assert.equal(tabB.categoryId, "continue")
  assert.deepEqual(transitionPromptCards(tabA, {type: "reset"}).state, initialPromptCardState())
  assert.equal(tabB.categoryId, "continue")
})

test("1J lifecycle resets on end, replacement, epoch, and terminal join failure but not reconnect success", () => {
  assert.match(appSource, /promptCards:\s*initialPromptCardState\(\)/)
  assert.match(appSource, /app\.currentEpochId !== epoch_id\) \{[\s\S]*?resetPromptCards\(\)/)
  assert.match(appSource, /conversation:ended[\s\S]*?resetAtmosphere\(\)[\s\S]*?resetPromptCards\(\)/)
  assert.match(appSource, /receive\("error"[\s\S]*?resetAtmosphere\(\)[\s\S]*?resetPromptCards\(\)/)
  assert.match(appSource, /handleMatchedConversation[\s\S]*?if \(!conversationId\) return[\s\S]*?resetPromptCards\(\)/)
  const joinStart = appSource.indexOf("app.conversation.join()")
  const reconnectSuccess = appSource.slice(joinStart, appSource.indexOf('.receive("error"', joinStart))
  assert.doesNotMatch(reconnectSuccess, /resetPromptCards/)
})

test("1J Prompt helper is local-only with zero persistence, synchronization, provider, or diagnostics", () => {
  for (const source of [promptModuleSource, promptRuntimeSource]) {
    assert.doesNotMatch(source, /localStorage|sessionStorage|indexedDB|putRecord|BroadcastChannel/)
    assert.doesNotMatch(source, /fetch\(|push\(|WebSocket|phx_|sync:reconcile|analytics|telemetry|console\./)
    assert.doesNotMatch(source, /OpenAI|LLM|provider|recommendation|message analysis/i)
  }
  assert.doesNotMatch(promptRuntimeSource, /participantId|conversationId|diagnostic|history/)
})

test("1J normal Send remains the sole ordinary message boundary with Reply preserved and zero Prompt metadata", () => {
  assert.doesNotMatch(promptUseSource, /cancelReplyStaging|replyState|requestSubmit|dispatchEvent|push\(/)
  assert.match(messageSubmitSource, /const replyContext = app\.replyState/)
  assert.match(messageSubmitSource, /client_message_id/)
  assert.match(messageSubmitSource, /message_id/)
  assert.match(messageSubmitSource, /content/)
  assert.match(messageSubmitSource, /reply_to_client_message_id/)
  assert.doesNotMatch(messageSubmitSource, /promptId|prompt_id|promptCategory|prompt_category|prompt_metadata/)
})

test("1J markup provides keyboard-native, screen-reader meaningful controls with no implicit submit", () => {
  assert.match(htmlSource, /id="prompt-control" type="button"[^>]*aria-expanded="false"[^>]*aria-controls="prompt-helper"/)
  assert.match(htmlSource, /id="prompt-helper"[^>]*role="dialog"[^>]*aria-labelledby="prompt-title"[^>]*hidden/)
  assert.match(htmlSource, /role="group" aria-label="Prompt categories"/)
  assert.match(htmlSource, /data-prompt-category="start"[^>]*aria-pressed="true"/)
  assert.match(htmlSource, /id="prompt-options"[^>]*aria-label="Available Conversation prompts"/)
  assert.match(htmlSource, /id="prompt-use" type="button"/)
  assert.match(htmlSource, /id="prompt-close" type="button"/)
  assert.match(promptRuntimeSource, /option\.type = "button"/)
  assert.match(appSource, /event\.key === "Escape"[\s\S]*?closePromptCards\(\)/)
})

test("1J helper stays readable and operable across themes, responsive, reduced-motion, and forced colors", () => {
  assert.equal(ATMOSPHERES.length, 5)
  for (const {id} of ATMOSPHERES) assert.match(cssSource, new RegExp(`data-atmosphere=["']${id}["']`))
  for (const token of ["--atmosphere-head", "--bubble-peer-border", "--mood-light"]) assert.ok(promptCssSource.includes(token))
  assert.match(promptCssSource, /#prompt-control[\s\S]*?min-height:\s*2\.75rem/)
  assert.match(cssSource, /@media \(max-width: 40rem\)[\s\S]*?\.prompt-options/)
  assert.match(cssSource, /@media \(forced-colors: active\)[\s\S]*?\.prompt-helper[\s\S]*?\.prompt-option/)
  assert.match(cssSource, /prefers-reduced-motion: reduce/)
  assert.doesNotMatch(promptCssSource, /animation|@keyframes/)
})

test("1J leaves canonical presence, delivery, Quiet, Atmosphere, and Ambient owners independent", () => {
  for (const owner of ["message:new", "delivery:progress", "conversation:presence", "sync:reconcile", "setQuietMode", "setAtmosphere", "AmbientAudioController"]) {
    assert.ok(appSource.includes(owner), `${owner} owner remains present`)
  }
  for (const snippet of appSource.matchAll(/(?:message:new|delivery:progress|conversation:presence|sync:reconcile)[\s\S]{0,500}/g)) {
    assert.doesNotMatch(snippet[0], /promptCards|promptId|promptCategory/)
  }
})
