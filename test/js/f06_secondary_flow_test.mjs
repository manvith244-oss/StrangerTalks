import assert from "node:assert/strict"
import test from "node:test"
import {createPreferenceSaveQueue, saveBooleanPreference} from "../../priv/static/assets/preference_saves.mjs"
import {ensureSecondaryEntries} from "../../priv/static/assets/secondary_flow.mjs"

function secondarySurfaceFixture() {
  let reflectionsEntry = null
  const memoryEntry = {
    insertAdjacentElement(position, element) {
      assert.equal(position, "afterend")
      reflectionsEntry = element
    }
  }
  const settings = {
    querySelector(selector) {
      if (selector === '[data-go="reflections"]') return reflectionsEntry
      if (selector === '[data-go="memories"]') return memoryEntry
      return null
    }
  }
  const documentRef = {
    querySelector(selector) {
      return selector === 'section[data-screen="settings"]' ? settings : null
    },
    createElement(tagName) {
      return {
        tagName: tagName.toUpperCase(),
        dataset: {},
        attributes: {},
        textContent: "",
        type: "",
        setAttribute(name, value) { this.attributes[name] = value }
      }
    }
  }
  return {documentRef, currentEntry: () => reflectionsEntry}
}

test("F-06 You surface deliberately exposes the existing Private Reflections screen", () => {
  const fixture = secondarySurfaceFixture()
  const entry = ensureSecondaryEntries(fixture.documentRef)

  assert.equal(entry, fixture.currentEntry())
  assert.equal(entry.tagName, "BUTTON")
  assert.equal(entry.type, "button")
  assert.equal(entry.dataset.go, "reflections")
  assert.equal(entry.textContent, "Open Private Reflections")
  assert.equal(ensureSecondaryEntries(fixture.documentRef), entry, "entry is idempotent")
})

test("F-06 preference writes serialize rapid intent so stale completion cannot win", async () => {
  const queue = createPreferenceSaveQueue()
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

test("F-06 obsolete failed preference save cannot roll back newer intent", async () => {
  const queue = createPreferenceSaveQueue()
  let releaseFirst
  const firstGate = new Promise(resolve => { releaseFirst = resolve })

  const first = queue.save("auto-sync", async () => {
    await firstGate
    throw new Error("older write failed")
  })
  const second = queue.save("auto-sync", async () => {})
  releaseFirst()

  assert.equal((await first).status, "superseded_failed")
  assert.equal((await second).status, "saved")
})

test("F-06 latest failed preference save reconciles to persisted canonical truth", async () => {
  const queue = createPreferenceSaveQueue()
  const writes = []
  const result = await saveBooleanPreference({
    queue,
    key: "reduced-motion",
    recordId: "settings:privacy",
    valueKey: "reduced_motion",
    desired: true,
    putRecord: async record => {
      writes.push(record)
      throw new Error("forced persistence failure")
    },
    getRecord: async id => ({id, type: "settings", value: {reduced_motion: false}}),
    now: () => "2026-08-26T18:30:00.000Z"
  })

  assert.equal(writes.length, 1)
  assert.equal(writes[0].value.reduced_motion, true)
  assert.equal(result.status, "failed")
  assert.equal(result.canonical, false, "latest failure returns persisted canonical value for UI rollback")
})

test("F-06 failed save never fabricates canonical truth when reconciliation also fails", async () => {
  const result = await saveBooleanPreference({
    queue: createPreferenceSaveQueue(),
    key: "auto-sync",
    recordId: "settings:auto-sync",
    valueKey: "enabled",
    desired: true,
    putRecord: async () => { throw new Error("write failed") },
    getRecord: async () => { throw new Error("read failed") }
  })

  assert.equal(result.status, "failed")
  assert.equal(result.canonical, null)
  assert.match(result.reconcileError.message, /read failed/)
})
