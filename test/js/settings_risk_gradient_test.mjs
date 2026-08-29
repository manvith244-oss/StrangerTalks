import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

const index = readFileSync("priv/static/index.html", "utf8")
const css = readFileSync("priv/static/assets/app.css", "utf8")
const secondaryFlow = readFileSync("priv/static/assets/secondary_flow.mjs", "utf8")
const app = readFileSync("priv/static/assets/app.js", "utf8")

const settings = index.slice(
  index.indexOf('<section data-screen="settings"'),
  index.indexOf('<section data-screen="memories"')
)

const LOCKED_SECTIONS = [
  ["content-destinations", "Content destinations"],
  ["preferences", "Preferences"],
  ["privacy-local-data", "Privacy & local data"],
  ["continuity-sync", "Continuity & sync"],
  ["sessions-connection", "Sessions & connection"],
  ["danger-zone", "Danger zone"]
]

test("Settings exposes the six locked risk-gradient sections in exact order", () => {
  const positions = LOCKED_SECTIONS.map(([key, heading]) => {
    const marker = `data-settings-section="${key}"`
    const position = settings.indexOf(marker)
    assert.notEqual(position, -1, `${heading} section exists`)
    assert.match(settings.slice(position), new RegExp(`<h2[^>]*>${heading.replace("&", "&amp;")}<\\/h2>`))
    return position
  })

  assert.deepEqual(positions, [...positions].sort((a, b) => a - b), "sections follow routine-to-irreversible order")
})

test("Settings destinations are declarative cards and existing controls retain stable identifiers", () => {
  assert.match(settings, /class="settings-destination-card"[^>]*data-go="memories"/)
  assert.match(settings, /class="settings-destination-card"[^>]*data-go="reflections"/)

  for (const id of [
    "account-continuity", "account-guest", "account-connected", "account-disabled",
    "account-link", "account-login", "auto-sync", "sync-now", "sync-restore",
    "sync-delete", "account-logout", "account-logout-all", "account-disconnect",
    "reduced-motion", "view-data", "export-data", "import-data", "delete-all", "local-data-list"
  ]) {
    assert.equal((settings.match(new RegExp(`id="${id}"`, "g")) || []).length, 1, `${id} is preserved exactly once`)
  }
})

test("danger actions are isolated from routine local-data actions", () => {
  const privacyStart = settings.indexOf('data-settings-section="privacy-local-data"')
  const continuityStart = settings.indexOf('data-settings-section="continuity-sync"')
  const dangerStart = settings.indexOf('data-settings-section="danger-zone"')
  const privacy = settings.slice(privacyStart, continuityStart)
  const danger = settings.slice(dangerStart)

  assert.match(privacy, /id="view-data"/)
  assert.match(privacy, /id="export-data"/)
  assert.match(privacy, /id="import-data"/)
  assert.doesNotMatch(privacy, /id="delete-all"|id="sync-delete"/)
  assert.match(danger, /id="delete-all"/)
  assert.match(danger, /id="sync-delete"/)
})

test("local deletion confirmation states its consequence and recoverability", () => {
  assert.match(app, /Delete all local StrangerTalks data from this browser\? This cannot be undone without an exported backup\./)
})

test("Settings styling is neutral and danger treatment uses semantic tokens", () => {
  assert.match(css, /section\[data-screen="settings"\]/)
  assert.match(css, /\.settings-danger-zone/)
  assert.match(css, /var\(--st-danger\)/)
  assert.doesNotMatch(css, /#continuity-suggestion\s*\{[^}]*var\(--st-deep-talk\)/s)
})

test("declarative Reflections entry leaves the compatibility helper as a no-op", () => {
  assert.match(settings, /data-go="reflections"/)
  assert.doesNotMatch(secondaryFlow, /createElement\("button"\)/)
  assert.doesNotMatch(secondaryFlow, /insertAdjacentElement/)
})
