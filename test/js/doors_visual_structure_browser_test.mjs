import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4000"
const VIEWPORTS = [
  {width: 390, height: 844},
  {width: 512, height: 844},
  {width: 992, height: 900},
  {width: 1440, height: 900}
]

async function openDoors(browser, viewport = {width: 390, height: 844}) {
  const context = await browser.newContext({viewport})
  const page = await context.newPage()
  const response = await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})
  assert.ok(response?.ok(), "root page loads")
  await page.locator('section[data-screen="doors"].active').waitFor({state: "visible"})
  await page.locator("button.door").first().waitFor({state: "visible"})
  assert.equal(await page.locator("button.door").count(), 4, "all four Doors render")
  return {context, page}
}

function columnCount(template) {
  return template.trim().split(/\s+/).filter(Boolean).length
}

async function doorVisualState(door) {
  return door.evaluate(element => {
    const style = getComputedStyle(element)
    const accent = getComputedStyle(element, "::after")
    const mark = element.querySelector(".door-mark")
    const markStyle = mark ? getComputedStyle(mark) : null
    const strong = element.querySelector("strong")
    const copy = element.querySelector("span")
    return {
      height: style.height,
      minHeight: style.minHeight,
      paddingTop: style.paddingTop,
      paddingRight: style.paddingRight,
      paddingBottom: style.paddingBottom,
      paddingLeft: style.paddingLeft,
      borderRadius: style.borderRadius,
      headingFontSize: strong ? getComputedStyle(strong).fontSize : null,
      copyFontSize: copy ? getComputedStyle(copy).fontSize : null,
      backgroundColor: style.backgroundColor,
      borderColor: style.borderColor,
      boxShadow: style.boxShadow,
      outlineColor: style.outlineColor,
      outlineStyle: style.outlineStyle,
      outlineWidth: style.outlineWidth,
      accentOpacity: Number.parseFloat(accent.opacity),
      accentColor: accent.backgroundColor,
      markOpacity: markStyle ? Number.parseFloat(markStyle.opacity) : null,
      markColor: markStyle?.backgroundColor || null
    }
  })
}

async function tabUntil(page, predicate, label, maxTabs = 24) {
  for (let attempt = 0; attempt < maxTabs; attempt += 1) {
    await page.keyboard.press("Tab")
    const matched = await page.evaluate(predicate)
    if (matched) return
  }
  assert.fail(`keyboard focus never reached ${label}`)
}

test("Doors grid never exceeds two columns at the locked viewport matrix", {timeout: 45_000}, async () => {
  const browser = await chromium.launch({headless: true})
  try {
    for (const viewport of VIEWPORTS) {
      const app = await openDoors(browser, viewport)
      try {
        const template = await app.page.locator("#doors").evaluate(element => getComputedStyle(element).gridTemplateColumns)
        const columns = columnCount(template)
        assert.ok(columns <= 2, `${viewport.width}px uses ${columns} column(s), never more than two`)
        if (viewport.width === 390) assert.equal(columns, 1, "390px remains single-column")
      } finally {
        await app.context.close()
      }
    }
  } finally {
    await browser.close()
  }
})

test("all four Doors have identical computed geometry regardless of data-door", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openDoors(browser, {width: 1440, height: 900})
    const states = await Promise.all(await app.page.locator("button.door").all().then(doors => doors.map(door => doorVisualState(door))))
    const geometry = states.map(({height, minHeight, paddingTop, paddingRight, paddingBottom, paddingLeft, borderRadius, headingFontSize, copyFontSize}) => ({
      height,
      minHeight,
      paddingTop,
      paddingRight,
      paddingBottom,
      paddingLeft,
      borderRadius,
      headingFontSize,
      copyFontSize
    }))
    for (const current of geometry.slice(1)) assert.deepEqual(current, geometry[0])
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("Doors follow intent-first DOM order and Temporary Conversation is secondary", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openDoors(browser)
    const order = await app.page.locator('section[data-screen="doors"]').evaluate(section => {
      const children = [...section.children]
      const index = element => children.indexOf(element)
      const lede = section.querySelector(".lede")
      const doors = section.querySelector("#doors")
      const language = section.querySelector("#conversation-language")
      const languageLabel = section.querySelector('label[for="conversation-language"]')
      const temporary = section.querySelector(".temporary-entry")
      return {
        lede: index(lede),
        doors: index(doors),
        languageLabel: index(languageLabel),
        language: index(language),
        temporary: index(temporary)
      }
    })

    assert.ok(order.lede < order.doors, "subcopy precedes Doors")
    assert.ok(order.doors < order.languageLabel, "Doors precede language label")
    assert.ok(order.languageLabel < order.language, "language label remains paired before select")
    assert.ok(order.language < order.temporary, "Temporary Conversation disclosure sits below the language control")
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("unselected Doors are neutral, hover/focus preview is restrained, and selected state remains distinct", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openDoors(browser)
    const doors = await app.page.locator("button.door").all()
    const defaults = []
    for (const door of doors) defaults.push(await doorVisualState(door))

    for (const state of defaults) {
      assert.ok(state.accentOpacity <= 0.01, `default accent stripe is neutral/hidden, got opacity ${state.accentOpacity}`)
    }
    assert.equal(new Set(defaults.map(state => state.markColor)).size, 1, "default Door marks use one neutral color")

    const firstDoor = doors[0]
    const resting = defaults[0]
    await firstDoor.hover()
    const hovered = await doorVisualState(firstDoor)
    assert.ok(hovered.accentOpacity >= 0.03 && hovered.accentOpacity <= 0.05, `hover preview stays within 3–5%, got ${hovered.accentOpacity}`)
    assert.notEqual(hovered.backgroundColor, resting.backgroundColor, "hover reveals a subtle Door tint")

    await app.page.mouse.move(0, 0)
    await tabUntil(app.page, () => document.activeElement?.matches("button.door") === true, "a Door")
    const focusedDoor = app.page.locator("button.door").filter({has: app.page.locator(":focus")})
    const focused = await doorVisualState(focusedDoor)
    assert.ok(focused.accentOpacity >= 0.03 && focused.accentOpacity <= 0.05, `focus preview stays within 3–5%, got ${focused.accentOpacity}`)
    assert.notEqual(focused.backgroundColor, resting.backgroundColor, "keyboard focus reveals a subtle Door tint")

    await firstDoor.evaluate(element => element.setAttribute("aria-pressed", "true"))
    const selected = await doorVisualState(firstDoor)
    assert.notEqual(selected.borderColor, resting.borderColor, "selected Door keeps a distinct border signal")
    assert.notEqual(selected.boxShadow, resting.boxShadow, "selected Door keeps the existing selected-state emphasis")
    assert.ok(selected.accentOpacity > hovered.accentOpacity, "selected accent remains stronger than hover preview")
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})

test("keyboard-only focus indicator is visible and fixed across all Doors and language", {timeout: 30_000}, async () => {
  const browser = await chromium.launch({headless: true})
  let app
  try {
    app = await openDoors(browser)
    const indicators = []

    for (let index = 0; index < 4; index += 1) {
      await tabUntil(app.page, expectedIndex => {
        const active = document.activeElement
        const doors = [...document.querySelectorAll("button.door")]
        return doors.indexOf(active) === expectedIndex
      }, `Door ${index + 1}`, 12)
      const state = await doorVisualState(app.page.locator("button.door").nth(index))
      assert.notEqual(state.outlineStyle, "none", `Door ${index + 1} has a visible focus outline`)
      assert.ok(Number.parseFloat(state.outlineWidth) >= 3, `Door ${index + 1} focus outline is at least 3px`)
      indicators.push({color: state.outlineColor, style: state.outlineStyle, width: state.outlineWidth})
    }

    await tabUntil(app.page, () => document.activeElement?.id === "conversation-language", "Conversation Language", 8)
    const languageIndicator = await app.page.locator("#conversation-language").evaluate(element => {
      const style = getComputedStyle(element)
      return {color: style.outlineColor, style: style.outlineStyle, width: style.outlineWidth, minHeight: style.minHeight, height: style.height}
    })
    assert.notEqual(languageIndicator.style, "none", "language control has a visible focus outline")
    assert.ok(Number.parseFloat(languageIndicator.width) >= 3, "language focus outline is at least 3px")
    assert.ok(Number.parseFloat(languageIndicator.height) >= 44, "language control preserves an adequate touch target")

    for (const indicator of indicators) assert.deepEqual(indicator, indicators[0], "Door focus indicators never vary by Door")
    assert.deepEqual(
      {color: languageIndicator.color, style: languageIndicator.style, width: languageIndicator.width},
      indicators[0],
      "language and Door controls use the same fixed focus indicator"
    )
  } finally {
    await app?.context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
