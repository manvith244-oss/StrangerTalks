export const AMBIENCES = Object.freeze([
  Object.freeze({themeId: "rain-window", label: "Rain ambience", src: "/assets/ambient/rain-window.wav"}),
  Object.freeze({themeId: "late-night-library", label: "Library ambience", src: "/assets/ambient/late-night-library.wav"}),
  Object.freeze({themeId: "train-journey", label: "Train ambience", src: "/assets/ambient/train-journey.wav"}),
  Object.freeze({themeId: "coffee-shop", label: "Coffee shop ambience", src: "/assets/ambient/coffee-shop.wav"}),
  Object.freeze({themeId: "night-observatory", label: "Night ambience", src: "/assets/ambient/night-observatory.wav"})
])

const AMBIENCE_BY_THEME = new Map(AMBIENCES.map((ambience) => [ambience.themeId, ambience]))

export function approvedAmbience(themeId) {
  return typeof themeId === "string" ? AMBIENCE_BY_THEME.get(themeId) || null : null
}

export class AmbientAudioController {
  constructor({createAudio, onStateChange = () => {}} = {}) {
    if (typeof createAudio !== "function") throw new TypeError("createAudio is required")
    this.audio = createAudio()
    this.audio.loop = true
    this.audio.preload = "none"
    this.onStateChange = onStateChange
    this.enabled = false
    this.themeId = null
    this.quiet = false
    this.visible = true
    this.conversationActive = false
    this.explicitAudioConflict = false
    this.generation = 0
    this.loadedSource = null
    this.status = "off"
    this.audio.addEventListener?.("error", () => {
      this.generation += 1
      this.audio.pause()
      this.status = "unavailable"
      this.notify()
    })
  }

  snapshot() {
    return {
      enabled: this.enabled,
      themeId: this.themeId,
      quiet: this.quiet,
      visible: this.visible,
      conversationActive: this.conversationActive,
      explicitAudioConflict: this.explicitAudioConflict,
      loadedSource: this.loadedSource,
      status: this.status
    }
  }

  notify() {
    this.onStateChange(this.snapshot())
  }

  canPlay() {
    return Boolean(
      this.enabled &&
      approvedAmbience(this.themeId) &&
      !this.quiet &&
      this.visible &&
      this.conversationActive &&
      !this.explicitAudioConflict
    )
  }

  setTheme(themeId) {
    const nextTheme = approvedAmbience(themeId)?.themeId || null
    if (this.themeId === nextTheme) return Promise.resolve({status: "no_op"})
    this.themeId = nextTheme
    this.stopPlayback({clearSource: true})
    return this.reconcile()
  }

  setEnabled(enabled) {
    const next = Boolean(enabled)
    if (this.enabled === next) return Promise.resolve({status: "no_op"})
    this.enabled = next
    if (!next) {
      this.stopPlayback()
      this.status = "off"
      this.notify()
      return Promise.resolve({status: "disabled"})
    }
    this.status = "paused"
    this.notify()
    return this.reconcile()
  }

  setQuiet(quiet) {
    this.quiet = Boolean(quiet)
    return this.reconcile()
  }

  setVisible(visible) {
    this.visible = Boolean(visible)
    return this.reconcile()
  }

  setConversationActive(active) {
    this.conversationActive = Boolean(active)
    return this.reconcile()
  }

  setExplicitAudioConflict(active) {
    this.explicitAudioConflict = Boolean(active)
    return this.reconcile()
  }

  reset() {
    this.enabled = false
    this.themeId = null
    this.quiet = false
    this.conversationActive = false
    this.explicitAudioConflict = false
    this.stopPlayback({clearSource: true})
    this.status = "off"
    this.notify()
  }

  stopPlayback({clearSource = false} = {}) {
    this.generation += 1
    this.audio.pause()
    if (clearSource && this.loadedSource) {
      this.audio.removeAttribute?.("src")
      this.loadedSource = null
      this.audio.load?.()
    }
    if (this.enabled) this.status = "paused"
    this.notify()
  }

  async reconcile() {
    const request = ++this.generation
    if (!this.canPlay()) {
      this.audio.pause()
      this.status = this.enabled ? "paused" : "off"
      this.notify()
      return {status: this.status}
    }

    const ambience = approvedAmbience(this.themeId)
    if (this.loadedSource !== ambience.src) {
      this.audio.pause()
      this.audio.src = ambience.src
      this.loadedSource = ambience.src
    }

    this.status = "starting"
    this.notify()
    try {
      await this.audio.play()
    } catch (_error) {
      if (request !== this.generation) return {status: "stale"}
      this.audio.pause()
      this.status = "blocked"
      this.notify()
      return {status: "blocked"}
    }

    if (request !== this.generation || !this.canPlay() || approvedAmbience(this.themeId)?.src !== ambience.src) {
      if (this.loadedSource === ambience.src && !this.canPlay()) this.audio.pause()
      return {status: "stale"}
    }

    this.status = "playing"
    this.notify()
    return {status: "playing"}
  }
}
