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

test("brand identity: static shell uses the canonical StrangerTalks lockup and SVG favicon", async () => {
  const html = await readFile(HTML_PATH, "utf8")

  assert.ok(html.includes('href="/images/favicon.svg"'), "shell must reference the SVG favicon")
  assert.ok(
    html.includes('src="/images/strangertalks-lockup-reversed.svg"'),
    "header must reference the canonical reversed lockup"
  )
  assert.ok(html.includes('alt="StrangerTalks"'), "visible lockup must have the StrangerTalks accessible name")
  assert.ok(!html.includes('<span aria-hidden="true">S</span>'), "legacy placeholder S mark must be removed")
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
