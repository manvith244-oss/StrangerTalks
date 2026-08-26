import assert from "node:assert/strict"
import test from "node:test"
import {readFile} from "node:fs/promises"
import {
  createGifSearchGuard,
  gifSearchPath,
  insertEmojiIntoDraft,
  sanitizeGifResults,
  sendWithSameIdentityRetry,
  validGifResult
} from "../../priv/static/assets/expression_surface_core.mjs"

const indexHtml = await readFile(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const runtimeSource = await readFile(new URL("../../priv/static/assets/expression_runtime.mjs", import.meta.url), "utf8")
const appSource = await readFile(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const pageController = await readFile(new URL("../../lib/strangertalks_new_web/controllers/page_controller.ex", import.meta.url), "utf8")

test("Team 10 has one formatting-independent canonical loader and no PageController surgery", () => {
  assert.equal((indexHtml.match(/expression_runtime\.mjs/g) || []).length, 1)
  assert.equal((indexHtml.match(/<script[^>]+\/assets\/app\.js/g) || []).length, 0)
  assert.equal((runtimeSource.match(/await import\(APP_ENTRY\)/g) || []).length, 1)
  assert.match(runtimeSource, /const APP_ENTRY = "\/assets\/app\.js\?v=20260807_v2"/)
  assert.doesNotMatch(pageController, /String\.replace|@app_script|@expression_script/)
  assert.match(pageController, /send_file/)
})

test("floating live reactions render network-derived emoji and labels as text, never HTML", () => {
  const match = appSource.match(/function displayReaction\(payload\) \{([\s\S]*?)\n\}/)
  assert.ok(match, "displayReaction renderer must exist")
  const renderer = match[1]
  assert.doesNotMatch(renderer, /innerHTML\s*=/)
  assert.match(renderer, /textContent\s*=/)
  assert.match(renderer, /replaceChildren|append/)
})

test("emoji insertion behaves like text editing at start, middle, end and selection", () => {
  assert.deepEqual(insertEmojiIntoDraft("hello", 0, 0, "❤️"), {value: "❤️hello", caret: 2})
  assert.deepEqual(insertEmojiIntoDraft("hello world", 5, 5, "❤️"), {value: "hello❤️ world", caret: 7})
  assert.deepEqual(insertEmojiIntoDraft("hello", 5, 5, "❤️"), {value: "hello❤️", caret: 7})
  assert.deepEqual(insertEmojiIntoDraft("hello world", 6, 11, "❤️"), {value: "hello ❤️", caret: 8})
})

test("emoji insertion preserves multiline text and ordinary unicode", () => {
  const draft = "one\ntwo\nthree"
  const result = insertEmojiIntoDraft(draft, 7, 7, "👀")
  assert.equal(result.value, "one\ntwo👀\nthree")
  assert.equal(result.caret, 9)
  assert.equal(insertEmojiIntoDraft("native 😊 input", 15, 15, "👍").value, "native 😊 input👍")
})

test("GIF search request contains only explicit query plus current Conversation authority", () => {
  const path = gifSearchPath(" happy dance ", "conversation-123")
  const url = new URL(path, "https://strangertalks.local")
  assert.deepEqual([...url.searchParams.keys()].sort(), ["conversation_id", "q"])
  assert.equal(url.searchParams.get("q"), "happy dance")
  assert.equal(url.searchParams.get("conversation_id"), "conversation-123")
  assert.doesNotMatch(path, /participant|safety|memory|door|language|token/i)
})

test("GIF request guard rejects stale query and Conversation A to B responses", () => {
  const guard = createGifSearchGuard()
  const cat = guard.begin("conversation-a", "cat")
  const dog = guard.begin("conversation-a", "dog")
  assert.equal(guard.isCurrent(cat, "conversation-a"), false)
  assert.equal(guard.isCurrent(dog, "conversation-a"), true)
  assert.equal(guard.isCurrent(dog, "conversation-b"), false)
  guard.invalidate()
  assert.equal(guard.isCurrent(dog, "conversation-a"), false)
})

test("GIF result validation rejects unsigned, dangerous and malformed provider payloads", () => {
  const valid = {
    id: "1",
    provider: "fake",
    reference: "signed-server-reference",
    media_url: "https://media.example.test/a.gif",
    label: "Happy dance",
    width: 320,
    height: 240
  }
  assert.equal(validGifResult(valid), true)
  assert.equal(validGifResult({...valid, reference: ""}), false)
  assert.equal(validGifResult({...valid, provider: ""}), false)
  assert.equal(validGifResult({...valid, media_url: "javascript:alert(1)"}), false)
  assert.equal(validGifResult({...valid, media_url: "data:text/html,hi"}), false)
  assert.equal(validGifResult({...valid, width: 0}), false)
  assert.equal(validGifResult({...valid, height: 5000}), false)
  assert.equal(validGifResult({...valid, label: "x".repeat(161)}), false)
  assert.deepEqual(sanitizeGifResults([valid, {...valid, id: "2", media_url: "file:///etc/passwd"}]), [valid])
})

test("same-identity retry retries timeout once without mutating payload identity", async () => {
  const payload = {client_message_id: "same-id", message_id: "same-id", expressive_id: "warm-wave"}
  const seen = []
  const reply = await sendWithSameIdentityRetry(async (attemptPayload) => {
    seen.push({...attemptPayload})
    if (seen.length === 1) throw {reason: "timeout"}
    return {status: "sent"}
  }, payload)

  assert.deepEqual(reply, {status: "sent"})
  assert.deepEqual(seen, [payload, payload])
})

test("same-identity retry does not retry non-timeout failures", async () => {
  let attempts = 0
  await assert.rejects(
    sendWithSameIdentityRetry(async () => {
      attempts += 1
      throw {reason: "invalid_payload"}
    }, {client_message_id: "same-id"})
  )
  assert.equal(attempts, 1)
})
