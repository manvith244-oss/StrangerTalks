import assert from "node:assert/strict"
import {existsSync, readFileSync} from "node:fs"
import test from "node:test"
import {fileURLToPath} from "node:url"

const indexPath = fileURLToPath(new URL("../../priv/static/index.html", import.meta.url))
const flowModuleUrl = new URL("../../priv/static/assets/flow_loading.mjs", import.meta.url)
const flowModulePath = fileURLToPath(flowModuleUrl)
const runtimePath = fileURLToPath(new URL("../../priv/static/assets/flow_loading_runtime.mjs", import.meta.url))
const index = readFileSync(indexPath, "utf8")

test("cold boot hides product surfaces until participant authority is reconciled", () => {
  assert.match(index, /<body class="flow-booting">/)
  assert.match(index, /id="boot-bridge"/)
  assert.match(index, /\.flow-booting \[data-screen\]/)
  assert.match(index, /\.flow-booting #bottom-nav/)
})

test("matchmaking admission is not presented as canonically waiting", () => {
  assert.match(index, /id="queue-title">Starting matchmaking…<\/h1>/)
  assert.match(index, /id="queue-lede">Confirming your place in the queue\.<\/p>/)
  assert.match(index, /id="leave-queue"[^>]*disabled/)
  assert.match(index, /id="queue-phase-status"[^>]*role="status"/)
})

test("F-07 loading taxonomy distinguishes unresolved authority from confirmed state", async () => {
  assert.equal(existsSync(flowModulePath), true, "flow_loading.mjs must exist")

  const {FLOW_PHASE, createOperationGuard, loadingPresentation} = await import(flowModuleUrl.href)

  assert.deepEqual(loadingPresentation(FLOW_PHASE.APP_BOOT), {
    title: "Opening StrangerTalks…",
    detail: "Checking your current session…",
    interaction: "blocked"
  })

  assert.deepEqual(loadingPresentation(FLOW_PHASE.MATCHMAKING_ADMISSION, {door: "Something Real"}), {
    title: "Starting matchmaking…",
    detail: "Confirming your place in the queue.",
    interaction: "blocked",
    leaveEnabled: false
  })

  assert.deepEqual(loadingPresentation(FLOW_PHASE.MATCHMAKING_WAITING, {door: "Something Real"}), {
    title: "Finding someone…",
    detail: "Looking for someone who chose Something Real too.",
    interaction: "queue",
    leaveEnabled: true
  })

  assert.deepEqual(loadingPresentation(FLOW_PHASE.MATCHMAKING_CANCELLING), {
    title: "Leaving queue…",
    detail: "Confirming you left matchmaking.",
    interaction: "blocked",
    leaveEnabled: false
  })

  assert.deepEqual(loadingPresentation(FLOW_PHASE.MATCHMAKING_CANCELLED), {
    title: "You left matchmaking.",
    detail: "Matchmaking is no longer active.",
    interaction: "blocked",
    leaveEnabled: false
  })

  assert.deepEqual(loadingPresentation(FLOW_PHASE.ENTERING_CONVERSATION), {
    title: "Found someone.",
    detail: "Opening your temporary conversation…",
    interaction: "blocked",
    leaveEnabled: false
  })

  const guard = createOperationGuard()
  const first = guard.begin("queue-admission")
  const second = guard.begin("queue-admission")
  assert.equal(guard.current(first), false, "superseded admission completion must be stale")
  assert.equal(guard.current(second), true)
  guard.invalidate()
  assert.equal(guard.current(second), false, "invalidated work must not restore obsolete loading state")
})

test("F-07 runtime owns the browser transition bridge before the existing app entry", () => {
  assert.equal(existsSync(runtimePath), true, "flow_loading_runtime.mjs must exist")
  assert.match(index, /src="\/assets\/flow_loading_runtime\.mjs\?v=20260826_f07_v1"/)
  assert.doesNotMatch(index, /src="\/assets\/expression_runtime\.mjs\?v=20260824_v2"/)
})

test("cold boot has a bounded early-failure handoff even before participant channel creation", () => {
  const runtime = readFileSync(runtimePath, "utf8")
  assert.match(runtime, /BOOT_WATCHDOG_MS/)
  assert.match(runtime, /MutationObserver/)
  assert.match(runtime, /StrangerTalks could not start/)
  assert.match(runtime, /renderBootFailure/)
})

test("canonical queue leave reply exits cancelling instead of waiting forever for a broadcast", () => {
  const runtime = readFileSync(runtimePath, "utf8")
  assert.match(runtime, /MATCHMAKING_CANCELLED/)
  assert.match(runtime, /result\?\.status === "left"/)
})
