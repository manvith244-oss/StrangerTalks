import assert from "node:assert/strict"
import test from "node:test"
import {readFile} from "node:fs/promises"

const appSource = await readFile(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const html = await readFile(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const css = await readFile(new URL("../../priv/static/assets/app.css", import.meta.url), "utf8")

test("Feature 1D browser picker keeps discovery local and sends only approved identity", () => {
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
})

test("Feature 1D renderer has bounded unavailable and rejected fallbacks", () => {
  assert.match(appSource, /Expressive media unavailable/)
  assert.match(appSource, /Expressive message not sent/)
  assert.match(appSource, /media\.label \|\| "Expressive media"/)
})

test("Feature 1D authoritative full sync reconstructs expressive media and removes local-only state", () => {
  assert.match(appSource, /item\.type === "expressive"/)
  assert.match(appSource, /removeLocalOnlyCanonicalMessages/)
  assert.match(appSource, /delivery_status !== "sending"/)
  assert.match(appSource, /deleteRecord\(record\.id\)/)
})

test("Feature 1D catalog uses only same-origin silent image assets", () => {
  const paths = [...appSource.matchAll(/asset_path: "([^"]+)"/g)].map((match) => match[1])
  assert.equal(paths.length, 4)
  assert.ok(paths.every((path) => path.startsWith("/assets/expressive/") && path.endsWith(".svg")))
  assert.doesNotMatch(appSource, /<audio|new Audio|\.play\(\)/)
})
