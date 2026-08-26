import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const indexPath = new URL("../../priv/static/index.html", import.meta.url)

let preferenceModule = null
try {
  preferenceModule = await import("../../priv/static/assets/preference_saves.mjs")
} catch (error) {
  if (error?.code !== "ERR_MODULE_NOT_FOUND") throw error
}

test("F-06 You surface exposes the existing Private Reflections screen", async () => {
  const html = await readFile(indexPath, "utf8")
  const settings = html.match(/<section data-screen="settings"[\s\S]*?<\/section>/)?.[0]

  assert.ok(settings, "You/settings screen exists")
  assert.match(settings, /data-go="memories"/, "Memory Space remains reachable from You")
  assert.match(settings, /data-go="reflections"/, "Private Reflections must be deliberately reachable from You")
})

test("F-06 preference writes serialize rapid intent so stale completion cannot win", async () => {
  assert.equal(typeof preferenceModule?.createPreferenceSaveQueue, "function", "preference save queue exists")
  const queue = preferenceModule.createPreferenceSaveQueue()
  const persisted = []
  let releaseFirst
  const firstGate = new Promise(resolve => { releaseFirst = resolve })

  const first = queue.save("reduced-motion", async () => {
    await firstGate
    persisted.push(false)
  })
  const second = queue.save("reduced-motion", async () => {
    persisted.push(true)
  })

  await Promise.resolve()
  assert.deepEqual(persisted, [], "newer persistence waits behind the older write instead of racing it")
  releaseFirst()

  assert.equal((await first).status, "superseded")
  assert.equal((await second).status, "saved")
  assert.deepEqual(persisted, [false, true], "final persisted value follows newest user intent")
})

test("F-06 latest failed preference save is distinguishable from an obsolete failure", async () => {
  assert.equal(typeof preferenceModule?.createPreferenceSaveQueue, "function", "preference save queue exists")
  const queue = preferenceModule.createPreferenceSaveQueue()
  let releaseFirst
  const firstGate = new Promise(resolve => { releaseFirst = resolve })

  const first = queue.save("auto-sync", async () => {
    await firstGate
    throw new Error("older write failed")
  })
  const second = queue.save("auto-sync", async () => {})
  releaseFirst()

  const firstResult = await first
  const secondResult = await second
  assert.equal(firstResult.status, "superseded_failed", "obsolete failure must not roll back newer intent")
  assert.equal(secondResult.status, "saved")

  const latestFailure = await queue.save("auto-sync", async () => {
    throw new Error("latest write failed")
  })
  assert.equal(latestFailure.status, "failed", "latest failure must be exposed for canonical UI reconciliation")
  assert.match(latestFailure.error.message, /latest write failed/)
})
