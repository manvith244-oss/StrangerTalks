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

test("Settings HTML button rejects broad deletion and requires bounded record wording", () => {
  const dangerStart = settings.indexOf('data-settings-section="danger-zone"')
  const danger = settings.slice(dangerStart)
  assert.doesNotMatch(danger, /<button[^>]*id="delete-all"[^>]*>\s*Delete all local data\s*<\/button>/i)
  assert.match(danger, /<button[^>]*id="delete-all"[^>]*>\s*Delete local StrangerTalks records\s*<\/button>/i)
  assert.match(danger, /<button[^>]*id="sync-delete"[^>]*>\s*Delete Google sync data\s*<\/button>/i)
})

test("local deletion confirmation discloses continuity boundaries and rejects stale irreversibility", () => {
  assert.doesNotMatch(app, /This cannot be undone without an exported backup/i)
  assert.doesNotMatch(app, /Delete all local StrangerTalks data from this browser/i)
  assert.match(app, /Delete saved StrangerTalks records from this browser and create a new anonymous identity\?/i)
  assert.match(app, /does not delete encrypted Google sync/i)
  assert.match(app, /(?:your\s+)?private account\/session/i)
  assert.match(app, /this browser[’']s encrypted continuity key/i)
  assert.match(app, /Eligible synced data can still be restored with the same private account/i)
  assert.match(app, /use [“"]Delete Google sync data[”"] separately/i)
})

test("local deletion completion announces records cleared and continuity preserved", () => {
  assert.doesNotMatch(app, /All prior local data was deleted/i)
  assert.match(app, /Local StrangerTalks records were deleted and a new anonymous identity was created/i)
  assert.match(app, /Encrypted Google sync, your private account\/session, and this browser[’']s continuity key were not deleted/i)
  assert.match(app, /Eligible synced data can still be restored with [“"]Restore from Google\.[”"]/i)
})

test("privacy disclosure rejects stale export-only recovery claim and clarifies continuity", () => {
  const privacyStart = settings.indexOf('data-settings-section="privacy-local-data"')
  const continuityStart = settings.indexOf('data-settings-section="continuity-sync"')
  const privacy = settings.slice(privacyStart, continuityStart)

  assert.doesNotMatch(privacy, /StrangerTalks cannot recover a lost passphrase or deleted local data without an exported backup/i)
  assert.match(privacy, /Encrypted backup files still require their passphrase/i)
  assert.match(privacy, /Deleting local StrangerTalks records does not delete encrypted Google sync or this browser[’']s continuity key/i)
  assert.match(privacy, /If eligible synced data exists, the same private account may restore it/i)
})

test("continuity section explicitly distinguishes local records from Google sync file", () => {
  const continuityStart = settings.indexOf('data-settings-section="continuity-sync"')
  const sessionsStart = settings.indexOf('data-settings-section="sessions-connection"')
  const continuity = settings.slice(continuityStart, sessionsStart)

  assert.match(continuity, /Encrypted Google sync is separate from this browser[’']s local record store/i)
  assert.match(continuity, /Deleting local StrangerTalks records does not delete the Google sync file;\s*use [“"]Delete Google sync data[”"] to remove it/i)
})

test("Delete-All execution handler preserves continuity key and remote sync boundaries", () => {
  const deleteAllMatch = app.match(/\$\("#delete-all"\)\.addEventListener\("click",\s*async\s*\(\)\s*=>\s*\{([\s\S]*?)\}\)/)
  assert.ok(deleteAllMatch, "delete-all click listener is registered")
  const handler = deleteAllMatch[1]
  assert.match(handler, /clearRecords\(\)/)
  assert.match(handler, /createIdentity\(false\)/)
  assert.doesNotMatch(handler, /\/api\/account\/sync/)
  assert.doesNotMatch(handler, /deleteSyncKey|clearSyncKey|storeSyncKey|loadSyncKey/)
  assert.doesNotMatch(handler, /deleteDatabase/)
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
