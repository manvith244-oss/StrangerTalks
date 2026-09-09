import assert from "node:assert/strict"
import {mkdir} from "node:fs/promises"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const OUTPUT_DIR = "tmp/brand-identity-proof"

async function proveBrand(browser, name, viewport) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), `${name}: StrangerTalks root must load`)

    const lockup = page.locator('.site-header .brand img[src="/images/strangertalks-lockup-reversed.svg"]')
    await lockup.waitFor({state: "visible"})

    const identity = await lockup.evaluate(image => ({
      alt: image.getAttribute("alt"),
      widthAttribute: image.getAttribute("width"),
      heightAttribute: image.getAttribute("height"),
      naturalWidth: image.naturalWidth,
      naturalHeight: image.naturalHeight,
      complete: image.complete
    }))

    assert.equal(identity.alt, "StrangerTalks", `${name}: lockup must expose the brand name`)
    assert.equal(identity.widthAttribute, "110", `${name}: explicit width prevents header layout shift`)
    assert.equal(identity.heightAttribute, "28", `${name}: explicit height prevents header layout shift`)
    assert.equal(identity.complete, true, `${name}: lockup image must complete loading`)
    assert.ok(identity.naturalWidth > 0 && identity.naturalHeight > 0, `${name}: lockup SVG must decode`)

    const box = await lockup.boundingBox()
    assert.ok(box, `${name}: lockup must have a rendered box`)
    assert.ok(box.width > 0 && box.height > 0, `${name}: lockup must render at non-zero size`)
    assert.ok(box.x >= 0 && box.x + box.width <= viewport.width, `${name}: lockup must not clip horizontally`)

    const faviconHref = await page.locator('link[rel="icon"][type="image/svg+xml"]').getAttribute("href")
    assert.equal(faviconHref, "/images/favicon.svg", `${name}: SVG favicon must be active`)

    const faviconStatus = await page.evaluate(async () => {
      const response = await fetch("/images/favicon.svg", {cache: "no-store"})
      return response.status
    })
    assert.equal(faviconStatus, 200, `${name}: favicon asset must resolve`)

    const overflow = await page.evaluate(() => ({
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth
    }))
    assert.ok(
      overflow.scrollWidth <= overflow.clientWidth,
      `${name}: brand integration must not introduce horizontal page overflow`
    )

    await page.screenshot({path: `${OUTPUT_DIR}/${name}.png`, fullPage: true})
  } finally {
    await context.close()
  }
}

test("brand identity: desktop and mobile app shell render the canonical lockup", async () => {
  await mkdir(OUTPUT_DIR, {recursive: true})
  const browser = await chromium.launch({headless: true})

  try {
    await proveBrand(browser, "desktop-1440x1000", {width: 1440, height: 1000})
    await proveBrand(browser, "mobile-390x844", {width: 390, height: 844})
  } finally {
    await browser.close()
  }
})
