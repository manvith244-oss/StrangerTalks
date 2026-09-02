import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const UUID = "123e4567-e89b-42d3-a456-426614174000"
const idle = {canonical_state: "IDLE"}
const queued = {canonical_state: "QUEUED", queue: {queue_attempt_id: "attempt-1"}}
const active = {canonical_state: "CONVERSATION", conversation: {conversation_id: UUID}}

const navigationLoad = await import("../../priv/static/assets/navigation_history.mjs")
  .then((module) => ({module, error: null}))
  .catch((error) => ({module: null, error}))

const navigation = navigationLoad.module

function runtimeTest(name, fn) {
  test(name, {skip: Boolean(navigationLoad.error)}, fn)
}

function fakeBrowser(initialPath = "/", initialState = null) {
  const location = {pathname: initialPath}
  const entries = [{path: initialPath, state: initialState}]
  let index = 0

  const history = {
    get state() { return entries[index]?.state ?? null },
    pushState(state, _title, path) {
      entries.splice(index + 1)
      entries.push({path, state})
      index += 1
      location.pathname = path
    },
    replaceState(state, _title, path) {
      entries[index] = {path, state}
      location.pathname = path
    }
  }

  return {
    location,
    history,
    entries,
    index: () => index,
    back() {
      if (index > 0) index -= 1
      location.pathname = entries[index].path
      return entries[index]
    },
    forward() {
      if (index < entries.length - 1) index += 1
      location.pathname = entries[index].path
      return entries[index]
    }
  }
}

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return {promise, resolve}
}

function createHarness({path = "/", state = null, snapshots = []} = {}) {
  const browser = fakeBrowser(path, state)
  const applied = []
  let snapshotReads = 0
  const pendingSnapshots = [...snapshots]
  const runtime = navigation.createNavigationHistory({
    history: browser.history,
    location: browser.location,
    getCanonicalSnapshot: async () => {
      snapshotReads += 1
      const next = pendingSnapshots.shift()
      return next?.promise ? next.promise : (next ?? idle)
    },
    applyRoute: (decision) => applied.push({...decision})
  })

  return {browser, applied, runtime, snapshotReads: () => snapshotReads}
}

test("F-03 navigation history runtime exists before behavior tests execute", () => {
  assert.equal(
    navigationLoad.error,
    null,
    `navigation_history.mjs must exist: ${navigationLoad.error?.message || "missing module"}`
  )
})

runtimeTest("F03-J01: / -> /you pushes one entry and Back restores Talk", async () => {
  const {browser, runtime} = createHarness()
  await runtime.initialize({snapshot: idle})
  await runtime.navigate("/you")

  assert.equal(browser.location.pathname, "/you")
  assert.deepEqual(browser.entries.map(({path}) => path), ["/", "/you"])

  browser.back()
  await runtime.popstate({snapshot: idle})
  assert.equal(browser.location.pathname, "/")
})

runtimeTest("F03-J02: Talk -> Chats -> Bonds -> You preserves Back/Forward order", async () => {
  const {browser, runtime} = createHarness()
  await runtime.initialize({snapshot: idle})
  await runtime.navigate("/chats")
  await runtime.navigate("/bonds")
  await runtime.navigate("/you")

  assert.deepEqual(browser.entries.map(({path}) => path), ["/", "/chats", "/bonds", "/you"])

  browser.back(); await runtime.popstate({snapshot: idle}); assert.equal(browser.location.pathname, "/bonds")
  browser.back(); await runtime.popstate({snapshot: idle}); assert.equal(browser.location.pathname, "/chats")
  browser.forward(); await runtime.popstate({snapshot: idle}); assert.equal(browser.location.pathname, "/bonds")
  browser.forward(); await runtime.popstate({snapshot: idle}); assert.equal(browser.location.pathname, "/you")
})

runtimeTest("F03-J03: /you/memories Back restores previous /you route", async () => {
  const {browser, runtime} = createHarness()
  await runtime.initialize({snapshot: idle})
  await runtime.navigate("/you")
  await runtime.navigate("/you/memories")
  browser.back()
  await runtime.popstate({snapshot: idle})
  assert.equal(browser.location.pathname, "/you")
})

runtimeTest("F03-J04: saved Conversation Back restores Chats context", async () => {
  const {browser, runtime} = createHarness()
  await runtime.initialize({snapshot: idle})
  await runtime.navigate("/chats")
  await runtime.navigate(`/chats/${UUID}`)
  browser.back()
  await runtime.popstate({snapshot: idle})
  assert.equal(browser.location.pathname, "/chats")
})

runtimeTest("F03-J05: QUEUED + navigate /you preserves activity away and performs no canonical read", async () => {
  const {browser, runtime, snapshotReads} = createHarness({path: "/matchmaking"})
  await runtime.initialize({snapshot: queued})
  await runtime.navigate("/you")

  assert.equal(browser.location.pathname, "/you")
  assert.equal(snapshotReads(), 0)
})

runtimeTest("F03-J06: QUEUED Back/Forward validates /matchmaking without replacing queue activity", async () => {
  const {browser, runtime} = createHarness({path: "/matchmaking"})
  await runtime.initialize({snapshot: queued})
  await runtime.navigate("/you")

  browser.back()
  await runtime.popstate({snapshot: queued})
  assert.equal(browser.location.pathname, "/matchmaking")

  browser.forward()
  await runtime.popstate({snapshot: queued})
  assert.equal(browser.location.pathname, "/you")
})

runtimeTest("F03-J07: ACTIVE Conversation may navigate away without route forcing", async () => {
  const {browser, runtime} = createHarness({path: "/conversation"})
  await runtime.initialize({snapshot: active})
  await runtime.navigate("/you")
  assert.equal(browser.location.pathname, "/you")

  browser.back()
  await runtime.popstate({snapshot: active})
  assert.equal(browser.location.pathname, "/conversation")
})

runtimeTest("F03-J08: match_found replaces /matchmaking with /conversation and creates no Match stop", async () => {
  const {browser, runtime} = createHarness({path: "/matchmaking"})
  await runtime.initialize({snapshot: queued})
  const beforeLength = browser.entries.length
  await runtime.activityEvent("match_found")

  assert.equal(browser.location.pathname, "/conversation")
  assert.equal(browser.entries.length, beforeLength)
  assert.equal(browser.entries.some(({path}) => path === "/match-found"), false)
})

runtimeTest("F03-J09: terminalization replaces active Conversation history and stale location cannot become ACTIVE", async () => {
  const {browser, runtime} = createHarness()
  await runtime.initialize({snapshot: idle})
  await runtime.navigate("/conversation", {snapshot: active})
  await runtime.activityEvent("conversation_ended")

  assert.deepEqual(browser.entries.map(({path}) => path), ["/", "/conversation/ended"])

  browser.back(); await runtime.popstate({snapshot: idle}); assert.equal(browser.location.pathname, "/")
  browser.forward(); await runtime.popstate({snapshot: idle}); assert.equal(browser.location.pathname, "/conversation/ended")

  browser.history.replaceState(browser.history.state, "", "/conversation")
  await runtime.popstate({snapshot: idle})
  assert.equal(browser.location.pathname, "/conversation/unavailable")
})

runtimeTest("F03-J10: unavailable current Conversation canonicalizes with replace", async () => {
  const {browser, runtime} = createHarness({path: "/conversation"})
  await runtime.initialize({snapshot: idle})
  assert.equal(browser.location.pathname, "/conversation/unavailable")
  assert.equal(browser.entries.length, 1)
})

runtimeTest("F03-J11: rapid A -> B -> C rejects late async A/B navigation completions", async () => {
  const a = deferred()
  const b = deferred()
  const {browser, runtime, applied} = createHarness({snapshots: [a, b]})
  await runtime.initialize({snapshot: idle})

  const navigationA = runtime.navigate("/conversation")
  const navigationB = runtime.navigate("/matchmaking")
  await runtime.navigate("/you")

  a.resolve(active)
  b.resolve(queued)
  const [resultA, resultB] = await Promise.all([navigationA, navigationB])

  assert.equal(resultA.stale, true)
  assert.equal(resultB.stale, true)
  assert.equal(browser.location.pathname, "/you")
  assert.equal(applied.at(-1).path, "/you")
})

runtimeTest("F03-J12: direct child deep link seeds canonical parent so browser Back stays coherent", async () => {
  const memories = createHarness({path: "/you/memories"})
  await memories.runtime.initialize({snapshot: idle})
  assert.deepEqual(memories.browser.entries.map(({path}) => path), ["/you", "/you/memories"])
  memories.browser.back()
  await memories.runtime.popstate({snapshot: idle})
  assert.equal(memories.browser.location.pathname, "/you")

  const chat = createHarness({path: `/chats/${UUID}`})
  await chat.runtime.initialize({snapshot: idle})
  assert.deepEqual(chat.browser.entries.map(({path}) => path), ["/chats", `/chats/${UUID}`])
})

runtimeTest("F03-J13: refresh/history initialization does not duplicate an existing F-03 entry", async () => {
  const first = createHarness({path: "/chats"})
  await first.runtime.initialize({snapshot: idle})
  const initialLength = first.browser.entries.length
  const existingState = first.browser.history.state

  const secondRuntime = navigation.createNavigationHistory({
    history: first.browser.history,
    location: first.browser.location,
    getCanonicalSnapshot: async () => idle,
    applyRoute: () => {}
  })
  await secondRuntime.initialize({snapshot: idle})

  assert.equal(first.browser.entries.length, initialLength)
  assert.equal(first.browser.history.state[navigation.NAVIGATION_STATE_KEY], true)
  assert.deepEqual(first.browser.history.state, existingState)
})

runtimeTest("F03-J14: canonical route correction uses replace instead of polluting history", async () => {
  const {browser, runtime} = createHarness({path: "/matchmaking"})
  await runtime.initialize({snapshot: idle})
  assert.deepEqual(browser.entries.map(({path}) => path), ["/"])
})

runtimeTest("F03-J15: F-03 history authority contains zero destructive lifecycle actions", async () => {
  const source = await readFile(new URL("../../priv/static/assets/navigation_history.mjs", import.meta.url), "utf8")
  for (const forbidden of ["queue:leave", "conversation:end", "conversation:block", "conversation:report", "report:submit"]) {
    assert.equal(source.includes(forbidden), false, forbidden)
  }
  assert.equal(source.includes("/vendor/phoenix.mjs"), false)
})

runtimeTest("active primary destination is derived from the canonical route, never persisted", () => {
  assert.equal(navigation.primaryDestinationForPath("/"), "talk")
  assert.equal(navigation.primaryDestinationForPath("/chats"), "chats")
  assert.equal(navigation.primaryDestinationForPath(`/chats/${UUID}`), "chats")
  assert.equal(navigation.primaryDestinationForPath("/bonds"), "bonds")
  assert.equal(navigation.primaryDestinationForPath("/you"), "you")
  assert.equal(navigation.primaryDestinationForPath("/you/memories"), "you")
  assert.equal(navigation.primaryDestinationForPath("/you/reflections"), "you")
  assert.equal(navigation.primaryDestinationForPath("/matchmaking"), null)
  assert.equal(navigation.primaryDestinationForPath("/conversation"), null)
})

runtimeTest("same canonical destination is a history no-op", async () => {
  const {browser, runtime} = createHarness()
  await runtime.initialize({snapshot: idle})
  await runtime.navigate("/")
  assert.equal(browser.entries.length, 1)
})
