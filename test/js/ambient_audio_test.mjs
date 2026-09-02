import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import {AMBIENCES, AmbientAudioController, approvedAmbience} from "../../priv/static/assets/ambient_audio.mjs"

const ROOT = path.resolve(import.meta.dirname, "../..")

class MockAudio {
  constructor({deferred = false, fail = false} = {}) {
    this.deferred = deferred
    this.fail = fail
    this.loop = false
    this.preload = ""
    this.paused = true
    this.src = ""
    this.playCalls = 0
    this.pauseCalls = 0
    this.pending = []
    this.listeners = new Map()
  }

  addEventListener(name, handler) { this.listeners.set(name, handler) }
  pause() { this.pauseCalls += 1; this.paused = true }
  load() {}
  removeAttribute(name) { if (name === "src") this.src = "" }
  play() {
    this.playCalls += 1
    if (this.fail) return Promise.reject(new Error("blocked"))
    if (!this.deferred) { this.paused = false; return Promise.resolve() }
    return new Promise((resolve) => this.pending.push(() => { this.paused = false; resolve() }))
  }
}

function controller(options = {}) {
  const audio = new MockAudio(options)
  return {audio, ambient: new AmbientAudioController({createAudio: () => audio})}
}

async function playable(ambient, themeId = "rain-window") {
  await ambient.setTheme(themeId)
  await ambient.setConversationActive(true)
  await ambient.setVisible(true)
}

test("1I catalog maps exactly all five approved 1H themes to bounded same-origin audio", () => {
  assert.deepEqual(AMBIENCES.map(({themeId}) => themeId), ["rain-window", "late-night-library", "train-journey", "coffee-shop", "night-observatory"])
  for (const ambience of AMBIENCES) {
    assert.match(ambience.src, /^\/assets\/ambient\/[a-z-]+\.wav$/)
    assert.equal(new URL(ambience.src, "http://localhost:4000").origin, "http://localhost:4000")
  }
  assert.equal(approvedAmbience("forged"), null)
  assert.equal(approvedAmbience("https://example.com/audio.mp3"), null)
})

test("1I defaults OFF and page/theme initialization never attempts playback", async () => {
  const {audio, ambient} = controller()
  await ambient.setTheme("rain-window")
  await ambient.setConversationActive(true)
  assert.equal(ambient.snapshot().enabled, false)
  assert.equal(audio.playCalls, 0)
  assert.equal(audio.src, "")
})

test("1I explicit enable starts current ambience and explicit disable silences it", async () => {
  const {audio, ambient} = controller()
  await playable(ambient)
  assert.equal((await ambient.setEnabled(true)).status, "playing")
  assert.equal(audio.src, "/assets/ambient/rain-window.wav")
  assert.equal(audio.paused, false)
  assert.equal((await ambient.setEnabled(false)).status, "disabled")
  assert.equal(audio.paused, true)
})

test("1I ON to ON and OFF to OFF are local no-ops", async () => {
  const {audio, ambient} = controller()
  assert.equal((await ambient.setEnabled(false)).status, "no_op")
  await playable(ambient)
  await ambient.setEnabled(true)
  const calls = audio.playCalls
  assert.equal((await ambient.setEnabled(true)).status, "no_op")
  assert.equal(audio.playCalls, calls)
})

test("1I theme switch stops Rain before making Train current", async () => {
  const {audio, ambient} = controller()
  await playable(ambient)
  await ambient.setEnabled(true)
  const pauses = audio.pauseCalls
  await ambient.setTheme("train-journey")
  assert.ok(audio.pauseCalls > pauses)
  assert.equal(ambient.snapshot().loadedSource, "/assets/ambient/train-journey.wav")
  assert.equal(audio.src, "/assets/ambient/train-journey.wav")
})

test("1I stale Rain play resolution cannot replace current Train playback", async () => {
  const {audio, ambient} = controller({deferred: true})
  await playable(ambient)
  const rainAttempt = ambient.setEnabled(true)
  const trainAttempt = ambient.setTheme("train-journey")
  audio.pending[0]()
  assert.equal((await rainAttempt).status, "stale")
  assert.equal(audio.src, "/assets/ambient/train-journey.wav")
  audio.pending[1]()
  assert.equal((await trainAttempt).status, "playing")
  assert.equal(ambient.snapshot().loadedSource, "/assets/ambient/train-journey.wav")
})

test("1I delayed play resolution after disable ends in silence", async () => {
  const {audio, ambient} = controller({deferred: true})
  await playable(ambient)
  const attempt = ambient.setEnabled(true)
  await ambient.setEnabled(false)
  audio.pending[0]()
  assert.equal((await attempt).status, "stale")
  assert.equal(audio.paused, true)
  assert.equal(ambient.snapshot().enabled, false)
})

test("1I Quiet Mode suppresses playback without clearing preference and permits resume", async () => {
  const {audio, ambient} = controller()
  await playable(ambient)
  await ambient.setEnabled(true)
  await ambient.setQuiet(true)
  assert.equal(audio.paused, true)
  assert.equal(ambient.snapshot().enabled, true)
  await ambient.setQuiet(false)
  assert.equal(audio.paused, false)
})

test("1I visibility pauses and conditionally resumes without owning presence", async () => {
  const {audio, ambient} = controller()
  await playable(ambient)
  await ambient.setEnabled(true)
  await ambient.setVisible(false)
  assert.equal(audio.paused, true)
  await ambient.setVisible(true)
  assert.equal(audio.paused, false)
  assert.equal(Object.hasOwn(ambient.snapshot(), "presence"), false)
})

test("1I explicit voice conflict pauses ambience and ending it permits resume", async () => {
  const {audio, ambient} = controller()
  await playable(ambient)
  await ambient.setEnabled(true)
  await ambient.setExplicitAudioConflict(true)
  assert.equal(audio.paused, true)
  assert.equal(ambient.snapshot().enabled, true)
  await ambient.setExplicitAudioConflict(false)
  assert.equal(audio.paused, false)
})

test("1I playback rejection is local, silent, bounded, and retry-loop free", async () => {
  const {audio, ambient} = controller({fail: true})
  await playable(ambient)
  assert.equal((await ambient.setEnabled(true)).status, "blocked")
  assert.equal(audio.paused, true)
  assert.equal(audio.playCalls, 1)
})

test("1I lifecycle preserves reconnect preference but resets end, replacement, epoch, refresh and new tab", async () => {
  const first = controller()
  await playable(first.ambient)
  await first.ambient.setEnabled(true)
  await first.ambient.setConversationActive(true)
  assert.equal(first.ambient.snapshot().enabled, true, "same-page reconnect preserves")
  first.ambient.reset()
  assert.deepEqual({enabled: first.ambient.snapshot().enabled, themeId: first.ambient.snapshot().themeId, active: first.ambient.snapshot().conversationActive}, {enabled: false, themeId: null, active: false})
  assert.equal(controller().ambient.snapshot().enabled, false, "refresh/new tab starts a new RAM owner OFF")
})

test("1I multi-tab controllers remain independent", async () => {
  const tabA = controller(); const tabB = controller()
  await playable(tabA.ambient); await playable(tabB.ambient)
  await tabA.ambient.setEnabled(true)
  assert.equal(tabA.ambient.snapshot().enabled, true)
  assert.equal(tabB.ambient.snapshot().enabled, false)
})

test("1I static assets are valid bounded PCM WAV files and are not eagerly preloaded", () => {
  for (const {src} of AMBIENCES) {
    const bytes = fs.readFileSync(path.join(ROOT, "priv/static", src))
    assert.equal(bytes.subarray(0, 4).toString(), "RIFF")
    assert.equal(bytes.subarray(8, 12).toString(), "WAVE")
    assert.ok(bytes.length > 1_000 && bytes.length < 100_000)
  }
  const html = fs.readFileSync(path.join(ROOT, "priv/static/index.html"), "utf8")
  assert.match(html, /id="ambient-audio"[^>]*preload="none"/)
  assert.doesNotMatch(html, /<source[^>]+ambient/)
})

test("1I source audit proves zero server, peer, persistence, diagnostic, or arbitrary URL authority", () => {
  const source = fs.readFileSync(path.join(ROOT, "priv/static/assets/ambient_audio.mjs"), "utf8")
  const appSource = fs.readFileSync(path.join(ROOT, "priv/static/assets/app.js"), "utf8")
  const localData = fs.readFileSync(path.join(ROOT, "priv/static/assets/local_data.mjs"), "utf8")
  assert.doesNotMatch(source, /fetch\(|WebSocket|Channel|localStorage|indexedDB|BroadcastChannel|telemetry|diagnostic|participant_id|conversation_id|epoch_id/)
  assert.doesNotMatch(localData, /ambientEnabled|ambient_enabled|ambient_audio/)
  const toggleBody = appSource.match(/function toggleAmbientAudio\(\) \{[\s\S]*?\n\}/)?.[0] || ""
  assert.doesNotMatch(toggleBody, /push\(|fetch\(|putRecord\(/)
  assert.doesNotMatch(source, /https?:\/\//)
})

test("1I app wiring resets only at frozen lifecycle boundaries and reconnect does not enable audio", () => {
  const appSource = fs.readFileSync(path.join(ROOT, "priv/static/assets/app.js"), "utf8")
  assert.match(appSource, /onCurrent\("conversation:ended"[\s\S]*?resetAmbientAudio\(\)/)
  assert.match(appSource, /currentEpochId !== epoch_id\) \{\s*resetAmbientAudio\(\)/)
  assert.match(appSource, /async function handleMatchedConversation[\s\S]*?resetAmbientAudio\(\)/)
  assert.match(appSource, /\.receive\("ok"[\s\S]*?setConversationActive\(true\)/)
  const socketCallbacks = sourceSlice(appSource, "app.socket.onError", "app.participant =")
  assert.doesNotMatch(socketCallbacks, /setEnabled\(true\)|resetAmbientAudio\(\)/)
})

test("1I control is native, explicit, readable, and independent of reduced motion", () => {
  const html = fs.readFileSync(path.join(ROOT, "priv/static/index.html"), "utf8")
  const css = fs.readFileSync(path.join(ROOT, "priv/static/assets/app.css"), "utf8")
  const appSource = fs.readFileSync(path.join(ROOT, "priv/static/assets/app.js"), "utf8")
  assert.match(html, /<button id="ambient-audio-control"[^>]*aria-pressed="false"[^>]*aria-label="Ambient Audio, off"/)
  assert.match(css, /\.ambient-audio-control/)
  assert.match(appSource, /Ambient Audio: \$\{enabled \? "On" : "Off"\}/)
  assert.doesNotMatch(sourceSlice(appSource, "function initializeAmbientAudio", "function renderAmbientAudioUI"), /reduce-motion|prefers-reduced-motion/)
})

function sourceSlice(source, start, end) {
  return source.slice(source.indexOf(start), source.indexOf(end))
}
