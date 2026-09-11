import assert from "node:assert/strict"
import {readdirSync, readFileSync, statSync} from "node:fs"
import {join} from "node:path"
import test from "node:test"
import {CALL_STATUS, StrangerTalksRing} from "../../priv/static/assets/live_call.mjs"

const forbiddenCapabilities = [
  "createAnalyser(",
  "AnalyserNode",
  "getByteFrequencyData(",
  "getByteTimeDomainData(",
  "getFloatFrequencyData(",
  "getFloatTimeDomainData(",
  "audioLevel",
  "totalAudioEnergy",
  "AudioWorklet",
  "audioWorklet",
  "createScriptProcessor(",
  "onaudioprocess"
]

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

function sourceHasAmplitudeCapability(source) {
  return forbiddenCapabilities.some((capability) => source.includes(capability))
}

test("Ring accepts only authoritative call state and exposes no amplitude input surface", () => {
  const element = createMockElement()
  const ring = new StrangerTalksRing(element)

  ring.update(
    {status: CALL_STATUS.ACTIVE, selfMuted: false, peerMuted: false},
    {localEnergy: 1, peerEnergy: 1, reconnecting: true, hasReactionPulse: true}
  )

  assert.equal(element.className, "stranger-call-ring ring-state-active")
  assert.equal(element.style.getPropertyValue("--ring-local-energy"), "")
  assert.equal(element.style.getPropertyValue("--ring-peer-energy"), "")

  const publicMethods = Object.getOwnPropertyNames(StrangerTalksRing.prototype).sort()
  assert.deepEqual(publicMethods, ["constructor", "destroy", "pulseReaction", "setA11yText", "update"])
})

test("Ring state reads are restricted to the explicit lifecycle and mute capability surface", () => {
  const element = createMockElement()
  const ring = new StrangerTalksRing(element)
  const allowed = new Set(["status", "selfMuted", "peerMuted"])

  const state = new Proxy(
    {status: CALL_STATUS.ACTIVE, selfMuted: false, peerMuted: true},
    {
      get(target, property, receiver) {
        assert.equal(
          allowed.has(property),
          true,
          `Ring attempted to read non-authoritative state capability: ${String(property)}`
        )
        return Reflect.get(target, property, receiver)
      }
    }
  )

  ring.update(state)
  assert.equal(element.className, "stranger-call-ring ring-state-active ring-state-peer-muted")
})

test("amplitude capability detector rejects computed-property aliases", () => {
  const bypasses = [
    'const analyser = ctx["create" + "Analyser"]()',
    'node["getByte" + "TimeDomainData"](buffer)',
    'const field = "total" + "AudioEnergy"; report[field]'
  ]

  for (const source of bypasses) {
    assert.equal(
      sourceHasAmplitudeCapability(source),
      true,
      `computed capability alias escaped Ring privacy detection: ${source}`
    )
  }
})

test("production browser assets contain no amplitude-inference capability", () => {
  const assetsRoot = new URL("../../priv/static/assets/", import.meta.url)
  const files = walkFiles(assetsRoot.pathname)

  for (const path of files) {
    const source = readFileSync(path, "utf8")
    assert.equal(
      sourceHasAmplitudeCapability(source),
      false,
      `${path} introduced speaking-amplitude inference without Ring privacy review`
    )
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

test("production Ring wiring passes only coordinator state", () => {
  const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
  assert.match(source, /ring\?\.update\(state\)/)
  assert.doesNotMatch(source, /ring\?\.update\(state\s*,/)
})

test("Ring authority gate cannot be bypassed by introducing a new production path", () => {
  const workflow = readFileSync(new URL("../../.github/workflows/ring-authority-security.yml", import.meta.url), "utf8")
  assert.match(workflow, /pull_request:\s*\n\s*branches:\s*\n\s*- main/)
  assert.doesNotMatch(workflow, /^\s*paths:/m)
  assert.match(workflow, /ring_security_contract_test\.mjs/)
})
