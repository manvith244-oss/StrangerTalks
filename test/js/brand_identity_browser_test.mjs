import assert from "node:assert/strict"
import {mkdir} from "node:fs/promises"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const OUTPUT_DIR = "tmp/brand-identity-proof"
const BRAND_COLORS = ["#5b3df6", "#ff6b6b", "#14b8a6", "#f4b942"]

async function proveBrand(browser, name, viewport) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()

  try {
    const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
    assert.ok(response?.ok(), `${name}: StrangerTalks root must load`)

    const brand = page.locator(".site-header .brand")
    const mark = brand.locator('svg[data-brand-mark="strangertalks"]')
    await mark.waitFor({state: "visible"})

    assert.equal((await brand.innerText()).trim(), "StrangerTalks", `${name}: visible wordmark must be exact`)
    assert.equal(await page.locator("img").count(), 0, `${name}: app shell must preserve the no-img invariant`)

    const identity = await mark.evaluate(svg => ({
      widthAttribute: svg.getAttribute("width"),
      heightAttribute: svg.getAttribute("height"),
      viewBox: svg.getAttribute("viewBox"),
      ariaHidden: svg.getAttribute("aria-hidden"),
      markup: svg.outerHTML.toLowerCase()
    }))

    assert.equal(identity.widthAttribute, "28", `${name}: explicit width prevents header layout shift`)
    assert.equal(identity.heightAttribute, "28", `${name}: explicit height prevents header layout shift`)
    assert.equal(identity.viewBox, "0 0 96 96", `${name}: mark must retain canonical geometry coordinates`)
    assert.equal(identity.ariaHidden, "true", `${name}: symbol is decorative beside the visible wordmark`)
    for (const color of BRAND_COLORS) {
      assert.ok(identity.markup.includes(color), `${name}: inline mark must include ${color}`)
    }

    const box = await brand.boundingBox()
    assert.ok(box, `${name}: brand lockup must have a rendered box`)
    assert.ok(box.width > 0 && box.height > 0, `${name}: brand lockup must render at non-zero size`)
    assert.ok(box.x >= 0 && box.x + box.width <= viewport.width, `${name}: brand lockup must not clip horizontally`)

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

test("brand identity: desktop and mobile app shell render the canonical inline mark", async () => {
  await mkdir(OUTPUT_DIR, {recursive: true})
  const browser = await chromium.launch({headless: true})

  try {
    await proveBrand(browser, "desktop-1440x1000", {width: 1440, height: 1000})
    await proveBrand(browser, "mobile-390x844", {width: 390, height: 844})
  } finally {
    await browser.close()
  }
})
