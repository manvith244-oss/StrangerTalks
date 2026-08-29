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
const loadingRuntimeSource = await readFile(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url), "utf8")
const runtimeSource = await readFile(new URL("../../priv/static/assets/expression_runtime.mjs", import.meta.url), "utf8")
const pageController = await readFile(new URL("../../lib/strangertalks_new_web/controllers/page_controller.ex", import.meta.url), "utf8")

test("Team 10 follows the canonical browser boot chain without direct expression or app injection", () => {
  assert.equal((indexHtml.match(/flow_loading_runtime\.mjs/g) || []).length, 1)
  assert.equal((indexHtml.match(/expression_runtime\.mjs/g) || []).length, 0)
  assert.equal((indexHtml.match(/<script[^>]+\/assets\/app\.js/g) || []).length, 0)
  assert.match(loadingRuntimeSource, /const APP_ENTRY = "\/assets\/expression_runtime\.mjs\?v=[^"]+"/)
  assert.equal((loadingRuntimeSource.match(/await import\(APP_ENTRY\)/g) || []).length, 1)
  assert.match(runtimeSource, /const APP_ENTRY = "\/assets\/app\.js\?v=[^"]+"/)
  assert.equal((runtimeSource.match(/await import\(APP_ENTRY\)/g) || []).length, 1)

  assert.match(pageController, /Application\.app_dir\(:strangertalks_new, "priv\/static\/index\.html"\)/)
  assert.match(pageController, /\|> File\.read!\(\)/)
  assert.match(pageController, /@route_runtime_tag <> "\\n    " <> @mobile_runtime_tag <> "\\n    " <> @app_bootstrap_tag/)
  assert.match(pageController, /send_resp\(200, body\)/)
  assert.doesNotMatch(pageController, /expression_runtime|\/assets\/app\.js/)
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
