import assert from "node:assert/strict"
import {spawnSync} from "node:child_process"
import test from "node:test"

const runtimeUrl = new URL("../../priv/static/assets/normal_media_runtime.mjs", import.meta.url).href
const viewOnceUrl = new URL("../../priv/static/assets/view_once.mjs", import.meta.url).href

function runModuleScript(source) {
  return spawnSync(process.execPath, ["--input-type=module", "--eval", source], {
    encoding: "utf8",
    timeout: 5_000
  })
}

function assertChildSuccess(result, label) {
  assert.equal(
    result.status,
    0,
    `${label}\nstdout:\n${result.stdout || ""}\nstderr:\n${result.stderr || ""}`
  )
}

test("T6-XT9-001: importing normal media runtime without browser globals is safe and inert", () => {
  const result = runModuleScript(`
    if (Object.prototype.hasOwnProperty.call(globalThis, "document")) throw new Error("unexpected document")
    if (Object.prototype.hasOwnProperty.call(globalThis, "window")) throw new Error("unexpected window")

    let intervalCalls = 0
    const originalSetInterval = globalThis.setInterval
    globalThis.setInterval = (...args) => {
      intervalCalls += 1
      return originalSetInterval(...args)
    }

    await import(${JSON.stringify(runtimeUrl)})

    if (Object.prototype.hasOwnProperty.call(globalThis, "document")) throw new Error("import created document")
    if (Object.prototype.hasOwnProperty.call(globalThis, "window")) throw new Error("import created window")
    if (intervalCalls !== 0) throw new Error("Node import started polling")
  `)

  assertChildSuccess(result, "normal_media_runtime.mjs must import safely without a DOM")
})

test("T6-XT9-001: importing View Once in Node remains safe through the normal-media dependency", () => {
  const result = runModuleScript(`
    if (Object.prototype.hasOwnProperty.call(globalThis, "document")) throw new Error("unexpected document")
    if (Object.prototype.hasOwnProperty.call(globalThis, "window")) throw new Error("unexpected window")
    await import(${JSON.stringify(viewOnceUrl)})
  `)

  assertChildSuccess(result, "view_once.mjs must remain importable in maintained Node regressions")
})

test("browser environment still schedules normal-media initialization at DOMContentLoaded", () => {
  const result = runModuleScript(`
    const listeners = []
    let intervalCalls = 0

    globalThis.document = {
      readyState: "loading",
      addEventListener(type, listener, options) {
        listeners.push({type, listenerType: typeof listener, once: options?.once === true})
      }
    }
    globalThis.window = {
      addEventListener() {
        throw new Error("beforeunload must not register before DOM initialization runs")
      }
    }
    globalThis.setInterval = () => {
      intervalCalls += 1
      return 1
    }

    await import(${JSON.stringify(runtimeUrl)})

    if (listeners.length !== 1) throw new Error("expected one guarded DOMContentLoaded registration")
    if (listeners[0].type !== "DOMContentLoaded") throw new Error("wrong browser boot event")
    if (listeners[0].listenerType !== "function") throw new Error("browser boot listener missing")
    if (!listeners[0].once) throw new Error("browser boot listener must be once-only")
    if (intervalCalls !== 0) throw new Error("polling started before DOM initialization")
  `)

  assertChildSuccess(result, "browser auto-boot must remain scheduled when a DOM exists")
})
