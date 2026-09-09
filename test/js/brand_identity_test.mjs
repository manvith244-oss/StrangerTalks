import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const HTML_PATH = "priv/static/index.html"
const IMAGE_ROOT = "priv/static/images"
const VECTOR_ASSETS = [
  "strangertalks-mark.svg",
  "strangertalks-mark-reversed.svg",
  "strangertalks-lockup.svg",
  "strangertalks-lockup-reversed.svg",
  "favicon.svg"
]
const BRAND_COLORS = ["#5b3df6", "#ff6b6b", "#14b8a6", "#f4b942"]

test("brand identity: static shell uses the inline StrangerTalks mark and SVG favicon", async () => {
  const html = await readFile(HTML_PATH, "utf8")
  const normalized = html.toLowerCase()

  assert.ok(html.includes('href="/images/favicon.svg"'), "shell must reference the SVG favicon")
  assert.ok(
    html.includes('data-brand-mark="strangertalks"'),
    "header must contain the canonical inline StrangerTalks mark"
  )
  assert.ok(html.includes(">StrangerTalks</strong>"), "header must expose the visible StrangerTalks wordmark")
  assert.ok(!normalized.includes("<img"), "brand integration must preserve the app shell no-img invariant")
  assert.ok(!html.includes('<span aria-hidden="true">S</span>'), "legacy placeholder S mark must be removed")

  for (const color of BRAND_COLORS) {
    assert.ok(normalized.includes(color), `inline header mark must include canonical brand color ${color}`)
  }
})

test("brand identity: canonical assets stay self-contained vector files", async () => {
  for (const name of VECTOR_ASSETS) {
    const svg = await readFile(`${IMAGE_ROOT}/${name}`, "utf8")

    assert.ok(svg.includes("<svg"), `${name} must be SVG`)
    assert.ok(svg.includes("viewBox="), `${name} must define a viewBox`)
    assert.ok(!svg.includes("<script"), `${name} must not contain scripts`)
    assert.ok(!svg.includes("<foreignObject"), `${name} must not contain foreignObject content`)
    assert.ok(!svg.includes("data:image/"), `${name} must not embed raster data`)
    assert.ok(!/\b(?:href|src)=["']https?:/i.test(svg), `${name} must not load external assets`)
  }
})

test("brand identity: canonical mark is intentionally colorful, not a monochrome placeholder", async () => {
  for (const name of VECTOR_ASSETS) {
    const svg = (await readFile(`${IMAGE_ROOT}/${name}`, "utf8")).toLowerCase()

    assert.ok(svg.includes("lineargradient"), `${name} must use the canonical color gradient`)
    for (const color of BRAND_COLORS) {
      assert.ok(svg.includes(color), `${name} must include canonical brand color ${color}`)
    }
  }
})
