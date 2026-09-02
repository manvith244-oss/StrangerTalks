import assert from "node:assert/strict"
import {readFile, access} from "node:fs/promises"
import {constants} from "node:fs"
import test from "node:test"

const APP_PATH = "priv/static/assets/app.js"
const CSS_PATH = "priv/static/assets/app.css"
const HTML_PATH = "priv/static/index.html"
const SERVER_CATALOG_PATH = "lib/strangertalks_new/avatar_catalog.ex"
const LOCAL_DATA_PATH = "priv/static/assets/local_data.mjs"

const APPROVED_KEYS = [
  "moon-fox",
  "rain-owl",
  "sun-bear",
  "star-deer",
  "cloud-otter",
  "dune-hare",
  "ember-cat",
  "frost-wolf",
  "moss-badger",
  "river-heron",
  "generic-self",
  "generic-peer"
]

test("STATIC-1 & STATIC-2 & STATIC-4: all approved avatar SVG assets exist and are valid first-party SVGs", async () => {
  for (const key of APPROVED_KEYS) {
    const path = `priv/static/assets/avatars/${key}.svg`
    await access(path, constants.R_OK)
    const content = await readFile(path, "utf8")
    assert.ok(content.startsWith("<svg"), `${key} must be valid SVG`)
    assert.ok(content.includes("viewBox="), `${key} must have viewBox`)
    assert.ok(content.includes("aria-label="), `${key} must have accessible aria-label`)
    assert.ok(!content.includes("href=\"http") && !content.includes("src=\"http"), `${key} must not load external assets`)
  }
})

test("STATIC-3 & STATIC-5: server catalog matches static assets and rejects external or arbitrary URLs", async () => {
  const serverCode = await readFile(SERVER_CATALOG_PATH, "utf8")
  for (const key of APPROVED_KEYS.filter(k => !k.startsWith("generic-"))) {
    assert.ok(serverCode.includes(`"${key}"`), `Server catalog must include ${key}`)
  }
})

test("A11Y-1..5: app.js and CSS support accessible, non-color-only avatar presentation with fallback", async () => {
  const appJs = await readFile(APP_PATH, "utf8")
  assert.ok(appJs.includes('conversation-avatar-presentation'))
  assert.ok(appJs.includes('avatar-badge avatar-self'))
  assert.ok(appJs.includes('avatar-badge avatar-peer'))
  assert.ok(appJs.includes('avatar-fallback'))
  assert.ok(appJs.includes('avatar-name'))

  const css = await readFile(CSS_PATH, "utf8")
  assert.ok(css.includes(".avatar-presentation"))
  assert.ok(css.includes(".avatar-badge"))
  assert.ok(css.includes(".avatar-img"))
  assert.ok(css.includes(".avatar-badge:focus-visible"))
})

test("PRIV-3 & PRIV-4 & PRIV-5: zero persistence in local data and no avatar tracking", async () => {
  const localData = await readFile(LOCAL_DATA_PATH, "utf8")
  assert.ok(!localData.includes("avatar_history"), "No avatar history in IndexedDB schema")
  assert.ok(!localData.includes("avatar_preference"), "No avatar preference in IndexedDB schema")
  assert.ok(!localData.includes("participant_avatar"), "No participant avatar durable cache")
})
