import assert from "node:assert/strict"
import test from "node:test"
import {readFile} from "node:fs/promises"
import "./team10_expression_surface_test.mjs"

const appSource = await readFile(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const html = await readFile(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const css = await readFile(new URL("../../priv/static/assets/app.css", import.meta.url), "utf8")
const runtimeSource = await readFile(new URL("../../priv/static/assets/expression_runtime.mjs", import.meta.url), "utf8")
const expressionCss = await readFile(new URL("../../priv/static/assets/expression_surface.css", import.meta.url), "utf8")
const pageController = await readFile(new URL("../../lib/strangertalks_new_web/controllers/page_controller.ex", import.meta.url), "utf8")

test("Feature 1D browser picker keeps sticker discovery local and sends only approved identity", () => {
  assert.match(appSource, /filteredExpressiveItems/)
  assert.match(appSource, /expressive_id: expressiveId/)
  assert.doesNotMatch(appSource, /expressive_id: expressiveId[^}]*asset_path/s)
  assert.match(html, /id="expressive-search"/)
})

test("Feature 1D keyboard, focus, touch, accessibility, and reduced motion contracts exist", () => {
  assert.match(appSource, /event\.key === "Escape"/)
  assert.match(appSource, /ArrowRight.*ArrowDown.*ArrowLeft.*ArrowUp/)
  assert.match(appSource, /setAttribute\("aria-label", media\.label\)/)
  assert.match(css, /touch-action: pan-y/)
  assert.match(css, /prefers-reduced-motion: reduce[^}]*\.expressive-loop/s)
  assert.match(expressionCss, /prefers-reduced-motion:reduce/)
})

test("Feature 1D renderer has bounded unavailable and rejected fallbacks", () => {
  assert.match(appSource, /Expressive media unavailable/)
  assert.match(appSource, /Expressive message not sent/)
  assert.match(appSource, /media\.label \|\| "Expressive media"/)
  assert.match(runtimeSource, /GIF unavailable/)
})

test("Feature 1D authoritative full sync reconstructs expressive media and removes local-only state", () => {
  assert.match(appSource, /item\.type === "expressive"/)
  assert.match(appSource, /removeLocalOnlyCanonicalMessages/)
  assert.match(appSource, /delivery_status !== "sending"/)
  assert.match(appSource, /deleteRecord\(record\.id\)/)
})

test("Feature 1D bundled catalog remains same-origin and is presented as stickers, not fake GIFs", () => {
  const paths = [...appSource.matchAll(/asset_path: "([^"]+)"/g)].map((match) => match[1])
  assert.equal(paths.length, 4)
  assert.ok(paths.every((path) => path.startsWith("/assets/expressive/") && path.endsWith(".svg")))
  assert.doesNotMatch(appSource, /<audio|new Audio|\.play\(\)/)
  assert.match(runtimeSource, /stickerTrigger\.textContent = "Stickers"/)
  assert.match(runtimeSource, /gifButton\.textContent = "GIFs"/)
  assert.match(runtimeSource, /emojiButton\.textContent = "Emoji"/)
})

test("Team 10 canonical entry exposes composer emoji and provider-controlled GIF seam", () => {
  assert.equal((html.match(/expression_runtime\.mjs/g) || []).length, 1)
  assert.equal((html.match(/<script[^>]+\/assets\/app\.js/g) || []).length, 0)
  assert.match(html, /expression_surface\.css/)
  assert.match(pageController, /send_file/)
  assert.doesNotMatch(pageController, /String\.replace|expression_runtime|expression_surface/)
  assert.match(runtimeSource, /emoji_picker\/index\.js/)
  assert.match(runtimeSource, /insertEmojiIntoDraft/)
  assert.match(runtimeSource, /\/api\/gifs\/status/)
  assert.match(runtimeSource, /gifSearchPath\(query\)/)
  assert.match(runtimeSource, /GIFs unavailable\. Stickers, emoji, and normal messages still work\./)
  assert.doesNotMatch(runtimeSource, /Conversation transcript|participant_id|Safety state|Memory data/)
})

test("Team 10 stale authority, terminal invalidation and same-identity retry are wired", () => {
  assert.match(runtimeSource, /gifSearchGuard\.invalidate\(\)/)
  assert.match(runtimeSource, /#block/)
  assert.match(runtimeSource, /#end-confirm/)
  assert.match(runtimeSource, /terminateExpressionAuthority/)
  assert.match(runtimeSource, /sendWithSameIdentityRetry/)
  assert.match(runtimeSource, /client_message_id: clientMessageId/)
  assert.match(runtimeSource, /message_id: clientMessageId/)
  assert.match(runtimeSource, /delivery_status === "sending"/)
  assert.match(runtimeSource, /expressive_id: record\.value\.expressive\.id/)
})

test("Team 10 preserves reply and draft semantics and rejects accidental double sends", () => {
  assert.match(runtimeSource, /replyIsActive\(\)/)
  assert.match(runtimeSource, /Send or cancel the text reply before sending a sticker\./)
  assert.match(runtimeSource, /Send or cancel the text reply before sending a GIF\./)
  assert.match(runtimeSource, /EXPRESSIVE_DOUBLE_TAP_MS = 600/)
  assert.doesNotMatch(runtimeSource, /message-input[^\n]*value\s*=\s*""/)
})
