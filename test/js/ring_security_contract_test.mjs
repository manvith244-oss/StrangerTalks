import assert from "node:assert/strict"
import {readdirSync, readFileSync, statSync} from "node:fs"
import {join} from "node:path"
import test from "node:test"
import {CALL_STATUS, StrangerTalksRing} from "../../priv/static/assets/live_call.mjs"

function createMockStyle() {
  const values = new Map()
  return {
    setProperty(name, value) { values.set(name, value) },
    getPropertyValue(name) { return values.get(name) || "" }
  }
}

function createMockElement() {
  const classes = new Set()
  return {
    className: "",
    style: createMockStyle(),
    classList: {
      add(value) { classes.add(value) },
      remove(value) { classes.delete(value) },
      contains(value) { return classes.has(value) }
    }
  }
}

function walkFiles(root) {
  const output = []
  for (const name of readdirSync(root)) {
    const path = join(root, name)
    const stat = statSync(path)
    if (stat.isDirectory()) output.push(...walkFiles(path))
    else if (/\.(mjs|js)$/.test(name)) output.push(path)
  }
  return output
}

test("Ring accepts only authoritative call state and exposes no amplitude input surface", () => {
  const element = createMockElement()
  const ring = new StrangerTalksRing(element)

  ring.update(
    {status: CALL_STATUS.ACTIVE, selfMuted: false, peerMuted: false},
    {localEnergy: 1, peerEnergy: 1, reconnecting: true}
  )

  assert.equal(element.className, "stranger-call-ring ring-state-active")
  assert.equal(element.style.getPropertyValue("--ring-local-energy"), "")
  assert.equal(element.style.getPropertyValue("--ring-peer-energy"), "")

  const publicMethods = Object.getOwnPropertyNames(StrangerTalksRing.prototype).sort()
  assert.deepEqual(publicMethods, ["constructor", "destroy", "pulseReaction", "setA11yText", "update"])
})

test("production browser assets contain no audio-analysis capability that can infer speaking amplitude", () => {
  const assetsRoot = new URL("../../priv/static/assets/", import.meta.url)
  const files = walkFiles(assetsRoot.pathname)
  const forbiddenCapabilities = [
    "createAnalyser(",
    "AnalyserNode",
    "getByteFrequencyData(",
    "getByteTimeDomainData(",
    "getFloatFrequencyData(",
    "getFloatTimeDomainData("
  ]

  for (const path of files) {
    const source = readFileSync(path, "utf8")
    for (const capability of forbiddenCapabilities) {
      assert.equal(
        source.includes(capability),
        false,
        `${path} introduced audio-analysis capability without Ring privacy review: ${capability}`
      )
    }
  }
})

test("Ring implementation contains no dormant speaking-energy contract", () => {
  const source = readFileSync(new URL("../../priv/static/assets/live_call.mjs", import.meta.url), "utf8")
  for (const forbidden of [
    "localEnergy",
    "peerEnergy",
    "ring-state-self-speaking",
    "ring-state-peer-speaking",
    "--ring-local-energy",
    "--ring-peer-energy"
  ]) {
    assert.equal(source.includes(forbidden), false, `dormant Ring energy seam remains: ${forbidden}`)
  }
})
