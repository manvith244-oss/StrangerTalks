import assert from "node:assert/strict"
import test from "node:test"
import {chromium} from "playwright"

const BASE_URL = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://localhost:4002"

const HOSTILE_STRINGS = [
  "<script>alert(1)</script>",
  "<img src=x onerror=alert(1)>",
  "\"><svg onload=alert(1)>",
  "javascript:alert(1)",
  "data:text/html,<script>alert(1)</script>",
  "x".repeat(20_000),
  "🫂👩🏽‍💻 مرحبا नमस्ते שלום \u202Etxt\u202C e\u0301"
]

test("floating reaction renderer keeps hostile network-derived emoji and labels inert", {timeout: 60_000}, async () => {
  const browser = await chromium.launch({headless: true})
  const page = await browser.newPage()

  try {
    await page.goto(BASE_URL, {waitUntil: "domcontentloaded"})

    const result = await page.evaluate(async (hostileStrings) => {
      const source = await fetch("/assets/app.js").then((response) => response.text())
      const match = source.match(/function displayReaction\(payload\) \{([\s\S]*?)\n\}/)
      if (!match) throw new Error("displayReaction renderer not found")

      const sandbox = document.createElement("section")
      sandbox.id = "team10-floating-reaction-sandbox"
      const container = document.createElement("div")
      container.id = "live-call-reaction-display"
      sandbox.append(container)
      document.body.append(sandbox)

      const cleanups = []
      const lookup = (selector) => sandbox.querySelector(selector)
      const renderer = new Function(
        "$",
        "document",
        "getStrangerRing",
        "setTimeout",
        `${match[0]}; return displayReaction`
      )(
        lookup,
        document,
        () => null,
        (callback) => {
          cleanups.push(callback)
          return cleanups.length
        }
      )

      const payloads = hostileStrings.flatMap((value) => [
        {emoji: value, label: `label:${value}`},
        {emoji: `emoji:${value}`, label: value}
      ])
      payloads.push(null, {}, {emoji: null, label: null}, {emoji: 0, label: false})

      const observations = []
      for (const payload of payloads) {
        renderer(payload)
        const item = container.lastElementChild
        observations.push({
          payload,
          exists: Boolean(item),
          elementChildren: item ? [...item.children].map((node) => node.tagName) : [],
          attackerNodes: item ? item.querySelectorAll("script,img,svg,iframe,object,embed").length : -1,
          eventHandlerAttributes: item ? [...item.querySelectorAll("*")].flatMap((node) => [...node.attributes]).filter((attribute) => /^on/i.test(attribute.name)).length : -1,
          firstText: item?.children?.[0]?.textContent ?? null,
          labelText: item?.children?.[1]?.textContent ?? null,
          labelClass: item?.children?.[1]?.className ?? null
        })
      }

      const beforeCleanup = container.childElementCount
      for (const cleanup of cleanups) cleanup()
      const afterCleanup = container.childElementCount
      sandbox.remove()

      return {observations, beforeCleanup, afterCleanup}
    }, HOSTILE_STRINGS)

    assert.equal(result.beforeCleanup, HOSTILE_STRINGS.length * 2 + 4)
    assert.equal(result.afterCleanup, 0, "every floating reaction timer removes its own DOM node")

    for (const observation of result.observations) {
      assert.equal(observation.exists, true)
      assert.deepEqual(observation.elementChildren, ["SPAN", "SPAN"])
      assert.equal(observation.attackerNodes, 0, "hostile text must not create attacker-controlled elements")
      assert.equal(observation.eventHandlerAttributes, 0, "hostile text must not create event-handler attributes")
      assert.equal(observation.labelClass, "sr-only")
    }

    for (let index = 0; index < HOSTILE_STRINGS.length; index += 1) {
      const hostile = HOSTILE_STRINGS[index]
      const emojiObservation = result.observations[index * 2]
      const labelObservation = result.observations[index * 2 + 1]
      assert.equal(emojiObservation.firstText, hostile)
      assert.equal(emojiObservation.labelText, `label:${hostile}`)
      assert.equal(labelObservation.firstText, `emoji:${hostile}`)
      assert.equal(labelObservation.labelText, hostile)
    }

    const malformed = result.observations.slice(HOSTILE_STRINGS.length * 2)
    assert.deepEqual(malformed.map((entry) => entry.firstText), ["❤️", "❤️", "❤️", "❤️"])
    assert.deepEqual(malformed.map((entry) => entry.labelText), ["Reaction", "Reaction", "Reaction", "Reaction"])
  } finally {
    await page.close().catch(() => {})
    await browser.close().catch(() => {})
  }
})
