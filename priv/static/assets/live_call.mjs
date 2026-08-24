/**
 * Live Communication Suite (Feature 1Q)
 * Authoritative WebRTC Live Call Coordinator
 * Relay-Only, Single call_attempt_id, Zero-Persistence Architecture
 * 
 * V1 Delta Corrections:
 * 1. 1Q-RTV-01: Return to Voice Privacy Floor (Immediate Document-RAM Local Visual Floor & Resurrection Guards)
 * 2. 1Q-DELIGHT-01: Ephemeral Reactions (First-Party Whitelist, In-RAM Dedupe & Rate Gates)
 * 3. 1Q-DELIGHT-02: StrangerTalks Ring (Derived Presentation, Transient Local/Remote Energy, Zero Server State)
 */

export const CALL_STATUS = {
  IDLE: "IDLE",
  PENDING_OUTGOING: "PENDING_OUTGOING",
  PENDING_INCOMING: "PENDING_INCOMING",
  CONNECTING: "CONNECTING",
  ACTIVE: "ACTIVE",
  TERMINAL: "TERMINAL"
}

export const REACTION_WHITELIST = ["heart", "wave", "sparkle", "smile", "fire"]

export const REACTION_LABELS = {
  heart: "Heart (Love)",
  wave: "Wave (Hello)",
  sparkle: "Sparkles (Delight)",
  smile: "Smile (Happy)",
  fire: "Fire (Excited)"
}

export const REACTION_EMOJIS = {
  heart: "❤️",
  wave: "👋",
  sparkle: "✨",
  smile: "😊",
  fire: "🔥"
}

export function stopMediaTracks(stream) {
  if (!stream || !stream.getTracks) return
  for (const track of stream.getTracks()) {
    try {
      track.stop()
    } catch {
      // Ignore errors on teardown
    }
  }
}

export function attachMediaStream(element, stream, coordinator = null) {
  if (!element || !stream) return

  // Before canonical Accept / during ringing: remote playback cannot activate
  if (coordinator) {
    const isPlaybackAllowed = coordinator.status === CALL_STATUS.ACTIVE
    if (!isPlaybackAllowed || !coordinator.callAttemptId) {
      if (element.srcObject) {
        element.srcObject = null
        try { element.pause() } catch {}
      }
      return
    }
  }

  if (element.srcObject !== stream) {
    element.srcObject = stream
  }

  if (coordinator) {
    coordinator.remoteElement = element
    const currentAttemptId = coordinator.callAttemptId
    const currentGen = ++coordinator.playbackAttemptGeneration

    if (element.play) {
      const playPromise = element.play()
      if (playPromise && playPromise.then) {
        playPromise
          .then(() => {
            // Late playback promise resolution: must revalidate current attempt and active authority
            if (
              coordinator.callAttemptId === currentAttemptId &&
              coordinator.playbackAttemptGeneration === currentGen &&
              coordinator.status === CALL_STATUS.ACTIVE
            ) {
              coordinator.mediaReady = true
              coordinator.playbackBlocked = false
              coordinator.notifyStateChange()
            } else {
              // Dead call stays dead / state changed during async resolution
              try { element.pause() } catch {}
              element.srcObject = null
            }
          })
          .catch((_err) => {
            // play() rejects / AudioContext suspended / autoplay blocked -> bounded recoverable state
            if (
              coordinator.callAttemptId === currentAttemptId &&
              coordinator.playbackAttemptGeneration === currentGen
            ) {
              coordinator.mediaReady = false
              coordinator.playbackBlocked = true
              coordinator.notifyStateChange()
            }
          })
      } else {
        coordinator.mediaReady = true
        coordinator.playbackBlocked = false
        coordinator.notifyStateChange()
      }
    }
  } else {
    const playPromise = element["play"] ? element["play"]() : null
    if (playPromise && playPromise.catch) playPromise.catch(() => {})
  }
}

export class LiveCallCoordinator {
  constructor(options = {}) {
    this.channel = options.channel || null
    this.participantId = options.participantId || null
    this.conversationId = options.conversationId || null
    this.onStateChange = options.onStateChange || (() => {})
    this.onRemoteStream = options.onRemoteStream || (() => {})
    this.onLocalStream = options.onLocalStream || (() => {})
    this.onError = options.onError || (() => {})
    this.onMediaUpdated = options.onMediaUpdated || (() => {})
    this.onReaction = options.onReaction || (() => {})
    this.onReturnToVoice = options.onReturnToVoice || (() => {})

    this.callAttemptId = null
    this.role = null // "caller" | "callee"
    this.status = CALL_STATUS.IDLE
    this.callType = "voice" // "voice" | "video"
    this.mediaGeneration = 1
    this.selfMuted = false
    this.peerMuted = false
    this.selfVideo = false
    this.peerVideo = false
    this.screenSharing = false
    this.activeAt = null

    // Return to Voice & Local Visual Privacy Floor (Document-RAM only)
    this.localVisualFloorClosed = false
    this.returnToVoiceGeneration = 0
    this.cameraAcquisitionGeneration = 0
    this.pendingVideoConsentFresh = false
    this.localCameraStream = null
    this.rawCameraTrack = null
    this.localVideoElement = null
    this.remoteVideoElement = null

    // Ephemeral Reactions In-RAM Deduplication
    this.presentedReactions = new Set()

    // Playback Authority & Media Readiness
    this.mediaReady = false
    this.playbackBlocked = false
    this.playbackAttemptGeneration = 0
    this.remoteElement = null

    // Voice Expression V1 (Preserved)
    this.voiceEffectPreset = "plain"
    this.voiceEffectActive = false
    this.peerVoiceEffectActive = false
    this.rawAudioTrack = null
    this.processedAudioTrack = null
    this.audioContext = null
    this.effectSourceNode = null
    this.effectDestinationNode = null

    // Reveal Together State (request-scoped, document-RAM only)
    this.revealState = {
      mediaRequestId: null,
      mode: "STANDARD_VIDEO",
      localReady: false,
      peerReady: false,
      revealed: false
    }

    this.localStream = null
    this.localScreenStream = null
    this.remoteStream = new (globalThis.MediaStream || Object)()
    this.peerConnection = null
    this.pendingCandidates = []
    this.credentials = null
    this.connectingTimer = null
    this.transportAudioTransceiver = null
    this.transportVideoTransceiver = null
    this.activeMediaAcquisitionGeneration = 0
  }

  setChannel(channel) {
    this.channel = channel
  }

  setParticipantId(id) {
    this.participantId = id
  }

  setConversationId(id) {
    this.conversationId = id
  }

  setVideoElements(localEl, remoteEl) {
    this.localVideoElement = localEl
    this.remoteVideoElement = remoteEl
  }

  getState() {
    return {
      callAttemptId: this.callAttemptId,
      status: this.status,
      role: this.role,
      callType: this.callType,
      mediaGeneration: this.mediaGeneration,
      selfMuted: this.selfMuted,
      peerMuted: this.peerMuted,
      selfVideo: this.selfVideo,
      peerVideo: this.peerVideo,
      screenSharing: this.screenSharing,
      localVisualFloorClosed: this.localVisualFloorClosed,
      returnToVoiceGeneration: this.returnToVoiceGeneration,
      voiceEffectPreset: this.voiceEffectPreset,
      voiceEffectActive: this.voiceEffectActive,
      peerVoiceEffectActive: this.peerVoiceEffectActive,
      revealState: { ...this.revealState },
      mediaReady: this.mediaReady,
      playbackBlocked: this.playbackBlocked,
      activeAt: this.activeAt,
      hasActiveCall: [CALL_STATUS.PENDING_OUTGOING, CALL_STATUS.PENDING_INCOMING, CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status)
    }
  }

notifyStateChange() {
  this.onStateChange(this.getState())
}

canTransmitOutgoingAudio() {
  return Boolean(
    this.callAttemptId &&
    this.status === CALL_STATUS.ACTIVE &&
    !this.selfMuted
  )
}

applyOutgoingAudioGate() {
  const enabled = this.canTransmitOutgoingAudio()
  if (this.rawAudioTrack) this.rawAudioTrack.enabled = enabled
  if (this.processedAudioTrack) this.processedAudioTrack.enabled = enabled
  if (this.localStream?.getAudioTracks) {
    for (const track of this.localStream.getAudioTracks()) track.enabled = enabled
  }
}

mediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection = this.peerConnection) {
  return Boolean(
    callAttemptId &&
    this.callAttemptId === callAttemptId &&
    this.mediaGeneration === mediaGeneration &&
    [CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status) &&
    (!peerConnection || this.peerConnection === peerConnection)
  )
}

activeMediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection = this.peerConnection) {
  return Boolean(
    callAttemptId &&
    this.callAttemptId === callAttemptId &&
    this.mediaGeneration === mediaGeneration &&
    this.status === CALL_STATUS.ACTIVE &&
    (!peerConnection || this.peerConnection === peerConnection)
  )
}

  // --- Channel Event Handlers ---

  handleIncomingCall({ call_attempt_id, caller_id, call_type }) {
    if (this.status !== CALL_STATUS.IDLE && this.status !== CALL_STATUS.TERMINAL) {
      // Busy or active attempt in progress
      return
    }
    this.callAttemptId = call_attempt_id
    this.role = "callee"
    this.callType = call_type || "voice"
    this.status = CALL_STATUS.PENDING_INCOMING
    this.mediaGeneration = 1
    this.localVisualFloorClosed = false
    this.returnToVoiceGeneration = 0
    this.presentedReactions.clear()
    this.notifyStateChange()
  }

async handleCallAccepted({ call_attempt_id, callee_session_id, active_at }) {
  if (this.callAttemptId !== call_attempt_id) return
  this.activeAt = active_at || Math.floor(Date.now() / 1000)
  this.status = CALL_STATUS.CONNECTING
  this.applyOutgoingAudioGate()
  this.notifyStateChange()

  if (this.role === "caller") await this.initializeWebRTC(true)
  else if (this.role === "callee") await this.initializeWebRTC(false)
}

  handleCallEnded({ call_attempt_id, reason }) {
    if (this.callAttemptId && this.callAttemptId !== call_attempt_id) return
    this.teardown(reason || "ended")
  }

handleMuteChanged({ call_attempt_id, participant_id, is_muted }) {
  if (this.callAttemptId !== call_attempt_id) return
  if (participant_id === this.participantId) {
    this.selfMuted = is_muted
    this.applyOutgoingAudioGate()
  } else {
    this.peerMuted = is_muted
  }
  this.notifyStateChange()
}

  handleEffectChanged({ call_attempt_id, participant_id, effect_active }) {
    if (this.callAttemptId !== call_attempt_id) return
    if (participant_id !== this.participantId) {
      this.peerVoiceEffectActive = Boolean(effect_active)
      this.notifyStateChange()
    }
  }

async handleSignal({ call_attempt_id, media_generation, signal, sender_id }) {
  if (this.callAttemptId !== call_attempt_id) return
  if (sender_id === this.participantId) return
  if (media_generation !== this.mediaGeneration) return
  if (![CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status)) return

  const stillCurrent = () => this.mediaAttemptIsCurrent(call_attempt_id, media_generation)
  if (!this.peerConnection) {
    this.pendingCandidates.push(signal)
    return
  }

  try {
    if (signal.type === "offer") {
      await this.peerConnection.setRemoteDescription(new RTCSessionDescription(signal))
      if (!stillCurrent()) return
      await this.flushPendingCandidates()
      if (!stillCurrent()) return
      const answer = await this.peerConnection.createAnswer()
      if (!stillCurrent()) return
      await this.peerConnection.setLocalDescription(answer)
      if (!stillCurrent()) return
      this.sendSignal(this.peerConnection.localDescription)
    } else if (signal.type === "answer") {
      await this.peerConnection.setRemoteDescription(new RTCSessionDescription(signal))
      if (!stillCurrent()) return
      await this.flushPendingCandidates()
    } else if (signal.candidate) {
      if (this.peerConnection.remoteDescription) {
        await this.peerConnection.addIceCandidate(new RTCIceCandidate(signal))
      } else {
        this.pendingCandidates.push(signal)
      }
    }
  } catch (error) {
    if (stillCurrent()) this.onError(error)
  }
}

  handleMediaRequested({ call_attempt_id, media_request_id, request_type, proposal, requester_id }) {
    if (this.callAttemptId !== call_attempt_id || this.status !== CALL_STATUS.ACTIVE) return
    const mode = proposal?.mode === "REVEAL_TOGETHER" ? "REVEAL_TOGETHER" : "STANDARD_VIDEO"
    this.revealState = {
      mediaRequestId: media_request_id,
      mode,
      localReady: false,
      peerReady: false,
      revealed: false
    }

    this.onMediaUpdated({
      type: "requested",
      mediaRequestId: media_request_id,
      requestType: request_type,
      proposal,
      requesterId: requester_id,
      incoming: requester_id !== this.participantId
    })
  }

  handleMediaUpdated({ call_attempt_id, media_generation, active_media, return_to_voice, actor_id }) {
    if (this.callAttemptId !== call_attempt_id || this.status !== CALL_STATUS.ACTIVE) return
    this.mediaGeneration = media_generation

    const hasVideo = active_media?.video && Object.keys(active_media.video).length > 0 && Object.values(active_media.video).some(Boolean)

    if (return_to_voice || !hasVideo) {
      // Enforce Return-to-Voice: Close local camera and peer video rendering immediately
      this.localVisualFloorClosed = true
      this.returnToVoiceGeneration = media_generation
      this.cameraAcquisitionGeneration++
      this.pendingVideoConsentFresh = false
      this.selfVideo = false
      this.peerVideo = false

      if (this.localCameraStream) {
        stopMediaTracks(this.localCameraStream)
        this.localCameraStream = null
      }
      if (this.rawCameraTrack) {
        try { this.rawCameraTrack.stop() } catch {}
        this.rawCameraTrack = null
      }
      if (this.localVideoElement) {
        this.localVideoElement.srcObject = null
        this.localVideoElement.hidden = true
      }
      if (this.remoteVideoElement) {
        try { this.remoteVideoElement.pause() } catch {}
        this.remoteVideoElement.srcObject = null
        this.remoteVideoElement.hidden = true
      }

      if (this.peerConnection) {
        const senders = this.peerConnection.getSenders ? this.peerConnection.getSenders() : []
        for (const sender of senders) {
          if (sender.track && sender.track.kind === "video") {
            try { sender.replaceTrack(null) } catch {}
          }
        }
      }
    } else if (active_media?.video) {
      if (this.localVisualFloorClosed) {
        // Re-entry permitted only through fresh video consent cycle after return to voice
        if (media_generation > this.returnToVoiceGeneration && this.pendingVideoConsentFresh) {
          this.localVisualFloorClosed = false
          this.selfVideo = Boolean(active_media.video[this.participantId])
          const otherKey = Object.keys(active_media.video).find((k) => k !== this.participantId)
          this.peerVideo = otherKey ? Boolean(active_media.video[otherKey]) : false
        } else {
          // Local visual floor remains closed: Video stays closed
          this.selfVideo = false
          this.peerVideo = false
        }
      } else {
        this.selfVideo = Boolean(active_media.video[this.participantId])
        const otherKey = Object.keys(active_media.video).find((k) => k !== this.participantId)
        this.peerVideo = otherKey ? Boolean(active_media.video[otherKey]) : false
      }
    }

    if (active_media?.screen_share) {
      this.screenSharing = active_media.screen_share.requester_id === this.participantId
    }

    this.notifyStateChange()
  }

  handleMediaDeclined({ call_attempt_id, media_request_id, reason }) {
    if (this.callAttemptId !== call_attempt_id) return
    this.pendingVideoConsentFresh = false
    this.onMediaUpdated({
      type: "declined",
      mediaRequestId: media_request_id,
      reason
    })
  }

  handleReaction({ call_attempt_id, reaction_event_id, reaction, sender_id, timestamp }) {
    if (this.callAttemptId !== call_attempt_id) return
    if (this.status !== CALL_STATUS.ACTIVE) return
    if (!REACTION_WHITELIST.includes(reaction)) return

    // In-RAM Deduplication
    if (this.presentedReactions.has(reaction_event_id)) return
    this.presentedReactions.add(reaction_event_id)

    // Bounded RAM set (prune when exceeding 100 entries)
    if (this.presentedReactions.size > 100) {
      const items = Array.from(this.presentedReactions)
      this.presentedReactions = new Set(items.slice(50))
      this.presentedReactions.add(reaction_event_id)
    }

    this.onReaction({
      reaction_event_id,
      reaction,
      sender_id,
      isSelf: sender_id === this.participantId,
      label: REACTION_LABELS[reaction] || reaction,
      emoji: REACTION_EMOJIS[reaction] || reaction,
      timestamp: timestamp || Date.now()
    })
  }

  handleRevealReady({ call_attempt_id, media_request_id, participant_id, ready }) {
    if (this.callAttemptId !== call_attempt_id || this.status !== CALL_STATUS.ACTIVE) return
    if (this.revealState.mediaRequestId && this.revealState.mediaRequestId !== media_request_id) return
    if (participant_id !== this.participantId) {
      this.revealState.peerReady = Boolean(ready)
      this.notifyStateChange()
    }
  }

  handleRevealCommitted({ call_attempt_id, media_request_id }) {
    if (this.callAttemptId !== call_attempt_id || this.status !== CALL_STATUS.ACTIVE) return
    if (this.revealState.mediaRequestId && this.revealState.mediaRequestId !== media_request_id) return
    if (!this.revealState.localReady || this.localVisualFloorClosed || this.revealState.mode !== "REVEAL_TOGETHER") {
      // Not Ready local privacy floor or stale/withdrawn ready: camera stays closed
      return
    }

    this.revealState.revealed = true
    this.selfVideo = true
    this.peerVideo = true
    this.notifyStateChange()
  }

  // --- Outgoing Actions ---

  async initiate(callType = "voice") {
    if (this.status !== CALL_STATUS.IDLE && this.status !== CALL_STATUS.TERMINAL) {
      throw new Error("Call already in progress")
    }

    this.role = "caller"
    this.callType = callType
    this.status = CALL_STATUS.PENDING_OUTGOING
    this.mediaGeneration = 1
    this.localVisualFloorClosed = false
    this.returnToVoiceGeneration = 0
    this.presentedReactions.clear()
    this.voiceEffectPreset = "plain"
    this.voiceEffectActive = false
    this.peerVoiceEffectActive = false
    this.notifyStateChange()

    return new Promise((resolve, reject) => {
      if (!this.channel) return reject(new Error("Channel unavailable"))
      this.channel.push("call:initiate", { call_type: callType })
        .receive("ok", (res) => {
          this.callAttemptId = res.call_attempt_id
          this.notifyStateChange()
          resolve(res)
        })
        .receive("error", (err) => {
          this.teardown("initiate_failed")
          reject(err)
        })
    })
  }

  async accept() {
    if (this.status !== CALL_STATUS.PENDING_INCOMING || !this.callAttemptId) {
      throw new Error("No pending incoming call")
    }

    return new Promise((resolve, reject) => {
      if (!this.channel) return reject(new Error("Channel unavailable"))
      this.channel.push("call:accept", { call_attempt_id: this.callAttemptId })
        .receive("ok", (res) => {
          this.status = CALL_STATUS.CONNECTING
          this.notifyStateChange()
          resolve(res)
        })
        .receive("error", (err) => {
          this.teardown("accept_failed")
          reject(err)
        })
    })
  }

  async decline() {
    if (!this.callAttemptId) return
    const attemptId = this.callAttemptId
    this.teardown("declined")

    if (this.channel) {
      this.channel.push("call:decline", { call_attempt_id: attemptId })
    }
  }

  async cancel() {
    if (!this.callAttemptId) return
    const attemptId = this.callAttemptId
    this.teardown("canceled")

    if (this.channel) {
      this.channel.push("call:cancel", { call_attempt_id: attemptId })
    }
  }

  async end() {
    if (!this.callAttemptId) return
    const attemptId = this.callAttemptId
    this.teardown("ended_by_user")

    if (this.channel) {
      this.channel.push("call:end", { call_attempt_id: attemptId })
    }
  }

async toggleMute() {
  if (this.status !== CALL_STATUS.ACTIVE && this.status !== CALL_STATUS.CONNECTING) return
  const targetMute = !this.selfMuted
  this.selfMuted = targetMute
  this.applyOutgoingAudioGate()
  this.notifyStateChange()

  if (this.channel && this.callAttemptId) {
    this.channel.push("call:mute", {
      call_attempt_id: this.callAttemptId,
      muted: targetMute
    })
  }
}

  // --- Return to Voice (Defect 1: 1Q-RTV-01) ---

  async returnToVoice() {
    if (this.status !== CALL_STATUS.ACTIVE) return
    if (!this.callAttemptId) return

    // 1. Immediately establish document-RAM local visual privacy floor
    this.localVisualFloorClosed = true
    this.returnToVoiceGeneration = this.mediaGeneration + 1
    this.cameraAcquisitionGeneration++
    this.pendingVideoConsentFresh = false
    this.selfVideo = false
    this.peerVideo = false

    // Close own camera immediately
    if (this.localCameraStream) {
      stopMediaTracks(this.localCameraStream)
      this.localCameraStream = null
    }
    if (this.rawCameraTrack) {
      try { this.rawCameraTrack.stop() } catch {}
      this.rawCameraTrack = null
    }
    if (this.localVideoElement) {
      this.localVideoElement.srcObject = null
      this.localVideoElement.hidden = true
    }

    // Stop rendering peer Video immediately
    if (this.remoteVideoElement) {
      try { this.remoteVideoElement.pause() } catch {}
      this.remoteVideoElement.srcObject = null
      this.remoteVideoElement.hidden = true
    }

    // Close video sender track on peerConnection
    if (this.peerConnection) {
      const senders = this.peerConnection.getSenders ? this.peerConnection.getSenders() : []
      for (const sender of senders) {
        if (sender.track && sender.track.kind === "video") {
          try { sender.replaceTrack(null) } catch {}
        }
      }
    }

    // Voice, text, timer, Mute remain completely active
    this.notifyStateChange()
    this.onReturnToVoice()

    // 2. Dispatch to server without blocking local privacy
    if (this.channel) {
      return new Promise((resolve) => {
        this.channel.push("call:return_to_voice", { call_attempt_id: this.callAttemptId })
          .receive("ok", (res) => {
            this.mediaGeneration = res.media_generation || this.returnToVoiceGeneration
            resolve(res)
          })
          .receive("error", (err) => resolve({ error: err }))
          .receive("timeout", () => resolve({ timeout: true }))
      })
    }
  }

  async acquireCameraStream() {
    if (this.localVisualFloorClosed || this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return null
    const currentGen = ++this.cameraAcquisitionGeneration

    if (!navigator.mediaDevices?.getUserMedia) return null

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true })
      // Revalidate: if Return to Voice occurred during acquisition, fail closed immediately
      if (
        this.localVisualFloorClosed ||
        this.cameraAcquisitionGeneration !== currentGen ||
        ![CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status)
      ) {
        stopMediaTracks(stream)
        return null
      }

      this.localCameraStream = stream
      const tracks = stream.getVideoTracks ? stream.getVideoTracks() : []
      if (tracks.length > 0) {
        this.rawCameraTrack = tracks[0]
      }
      return stream
    } catch {
      return null
    }
  }

  // --- Ephemeral Reactions (Defect 2: 1Q-DELIGHT-01) ---

  async sendReaction(reaction) {
    if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
    if (!REACTION_WHITELIST.includes(reaction)) {
      throw new Error("Invalid reaction: not in whitelist")
    }

    const reaction_event_id = "rx_" + Math.random().toString(36).slice(2, 9) + "_" + Date.now()

    // Local loopback for immediate feedback with deduplication
    this.handleReaction({
      call_attempt_id: this.callAttemptId,
      reaction_event_id,
      reaction,
      sender_id: this.participantId,
      timestamp: Date.now()
    })

    if (this.channel) {
      this.channel.push("call:reaction", {
        call_attempt_id: this.callAttemptId,
        reaction_event_id,
        reaction
      })
    }

    return { reaction_event_id, reaction }
  }

  // --- Media Upgrades ---

async requestMediaUpgrade(requestType = "video_upgrade", proposal = {}) {
  if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
  if (requestType !== "video_upgrade") throw new Error("Unsupported media upgrade")
  this.pendingVideoConsentFresh = true

  return new Promise((resolve, reject) => {
    if (!this.channel) return reject(new Error("Channel unavailable"))
    this.channel.push("call:media_request", {
      call_attempt_id: this.callAttemptId,
      request_type: "video_upgrade",
      proposal
    })
      .receive("ok", resolve)
      .receive("error", reject)
  })
}

  async respondMediaUpgrade(mediaRequestId, decision = "accept") {
    if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
    if (decision === "accept") {
      this.pendingVideoConsentFresh = true
    }

    return new Promise((resolve, reject) => {
      if (!this.channel) return reject(new Error("Channel unavailable"))
      this.channel.push("call:media_response", {
        call_attempt_id: this.callAttemptId,
        media_request_id: mediaRequestId,
        decision
      })
        .receive("ok", resolve)
        .receive("error", reject)
    })
  }

  // --- Reveal Together (Gap 1) ---

  async setRevealReady(mediaRequestId, ready = true) {
    if (!this.callAttemptId || this.status !== CALL_STATUS.ACTIVE) return
    if (this.revealState.mediaRequestId && this.revealState.mediaRequestId !== mediaRequestId) return
    if (!this.revealState.mediaRequestId) {
      this.revealState.mediaRequestId = mediaRequestId
    }

    this.revealState.localReady = Boolean(ready)

    if (!ready) {
      // Not Ready is an immediate LOCAL camera-transmission privacy floor
      this.cameraAcquisitionGeneration++
      this.selfVideo = false
      if (this.localCameraStream) {
        stopMediaTracks(this.localCameraStream)
        this.localCameraStream = null
      }
      if (this.rawCameraTrack) {
        try { this.rawCameraTrack.stop() } catch {}
        this.rawCameraTrack = null
      }
      if (this.localVideoElement) {
        this.localVideoElement.srcObject = null
        this.localVideoElement.hidden = true
      }
      if (this.peerConnection) {
        const senders = this.peerConnection.getSenders ? this.peerConnection.getSenders() : []
        for (const s of senders) {
          if (s.track?.kind === "video") {
            try { s.replaceTrack(null) } catch {}
          }
        }
      }
    }

    this.notifyStateChange()

    if (this.channel) {
      this.channel.push("call:reveal_ready", {
        call_attempt_id: this.callAttemptId,
        media_request_id: mediaRequestId,
        ready: Boolean(ready)
      })
    }
  }

  // --- Voice Expression V1 ---

  async setVoiceExpression(preset = "plain") {
    if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
    if (!["plain", "warm_radio", "space_echo"].includes(preset)) preset = "plain"
    if (this.voiceEffectPreset === preset) return
    this.voiceEffectPreset = preset

    if (preset === "plain") {
      this.cleanupEffectGraph()
      if (this.rawAudioTrack) {
        this.rawAudioTrack.enabled = this.canTransmitOutgoingAudio()
        if (this.peerConnection) {
          const senders = this.peerConnection.getSenders ? this.peerConnection.getSenders() : []
          const audioSender = senders.find((s) => s.track && s.track.kind === "audio")
          if (audioSender && audioSender.replaceTrack) {
            await audioSender.replaceTrack(this.rawAudioTrack).catch(() => {})
          }
        }
      }
      this.voiceEffectActive = false
      this.notifyStateChange()
      if (this.channel && this.callAttemptId) {
        this.channel.push("call:effect", {
          call_attempt_id: this.callAttemptId,
          effect_active: false
        })
      }
      return
    }

    if (this.rawAudioTrack) {
      this.rawAudioTrack.enabled = false
    }

    try {
      const AudioCtx = globalThis.AudioContext || globalThis.webkitAudioContext
      if (!AudioCtx || !this.rawAudioTrack) {
        this.voiceEffectActive = true
        this.notifyStateChange()
        return
      }

      this.cleanupEffectGraph()
      this.audioContext = new AudioCtx()
      if (this.audioContext.state === "suspended") {
        await this.audioContext.resume()
      }

      const mediaStream = new (globalThis.MediaStream || Object)([this.rawAudioTrack])
      this.effectSourceNode = this.audioContext.createMediaStreamSource(mediaStream)
      this.effectDestinationNode = this.audioContext.createMediaStreamDestination()

      if (preset === "warm_radio") {
        const highpass = this.audioContext.createBiquadFilter()
        highpass.type = "highpass"
        highpass.frequency.value = 300

        const lowpass = this.audioContext.createBiquadFilter()
        lowpass.type = "lowpass"
        lowpass.frequency.value = 3400

        const bandBoost = this.audioContext.createBiquadFilter()
        bandBoost.type = "peaking"
        bandBoost.frequency.value = 1000
        bandBoost.gain.value = 4

        this.effectSourceNode.connect(highpass)
        highpass.connect(lowpass)
        lowpass.connect(bandBoost)
        bandBoost.connect(this.effectDestinationNode)
      } else if (preset === "space_echo") {
        const delay = this.audioContext.createDelay(1.0)
        delay.delayTime.value = 0.22

        const feedback = this.audioContext.createGain()
        feedback.gain.value = 0.35

        const wetGain = this.audioContext.createGain()
        wetGain.gain.value = 0.4

        const filter = this.audioContext.createBiquadFilter()
        filter.type = "lowpass"
        filter.frequency.value = 2200

        this.effectSourceNode.connect(this.effectDestinationNode)
        this.effectSourceNode.connect(delay)
        delay.connect(filter)
        filter.connect(feedback)
        feedback.connect(delay)
        filter.connect(wetGain)
        wetGain.connect(this.effectDestinationNode)
      }

      this.processedAudioTrack = this.effectDestinationNode.stream.getAudioTracks()[0]
      if (this.processedAudioTrack) {
        this.processedAudioTrack.enabled = this.canTransmitOutgoingAudio()
        if (this.peerConnection) {
          const senders = this.peerConnection.getSenders ? this.peerConnection.getSenders() : []
          const audioSender = senders.find((s) => s.track && s.track.kind === "audio")
          if (audioSender && audioSender.replaceTrack) {
            await audioSender.replaceTrack(this.processedAudioTrack).catch(() => {})
          }
        }
      }

      this.voiceEffectActive = true
      this.notifyStateChange()

      if (this.channel && this.callAttemptId) {
        this.channel.push("call:effect", {
          call_attempt_id: this.callAttemptId,
          effect_active: true
        })
      }
    } catch {
      if (this.rawAudioTrack) this.rawAudioTrack.enabled = false
      this.voiceEffectActive = true
      this.notifyStateChange()
    }
  }

  cleanupEffectGraph() {
    if (this.processedAudioTrack) {
      try { this.processedAudioTrack.stop() } catch {}
      this.processedAudioTrack = null
    }
    if (this.audioContext) {
      try { this.audioContext.close() } catch {}
      this.audioContext = null
    }
    this.effectSourceNode = null
    this.effectDestinationNode = null
  }

  // --- WebRTC Relay Transport Engine ---

  async fetchCredentials() {
    return new Promise((resolve, reject) => {
      if (!this.channel) return reject(new Error("Channel unavailable"))
      this.channel.push("call:request_credentials", { call_attempt_id: this.callAttemptId })
        .receive("ok", (creds) => {
          this.credentials = creds
          resolve(creds)
        })
        .receive("error", reject)
    })
  }

async initializeWebRTC(isOfferSide = false) {
  const setupAttemptId = this.callAttemptId
  const setupGeneration = this.mediaGeneration
  if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, null)) return

  let peerConnection = null
  try {
    const creds = await this.fetchCredentials()
    if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, null)) return

    const config = {
      iceServers: creds.ice_servers || [],
      iceTransportPolicy: "relay",
      bundlePolicy: "max-bundle",
      rtcpMuxPolicy: "require"
    }
    const RTCPC = globalThis.RTCPeerConnection || globalThis.webkitRTCPeerConnection
    if (!RTCPC) throw new Error("WebRTC RTCPeerConnection not supported")

    peerConnection = new RTCPC(config)
    this.peerConnection = peerConnection

    // CONNECTING establishes transport only. Hardware capture stays closed until ACTIVE.
    if (!peerConnection.addTransceiver) {
      throw new Error("WebRTC transceiver support is required for fail-closed media authority")
    }
    this.transportAudioTransceiver = peerConnection.addTransceiver("audio", {direction: "sendrecv"})
    this.transportVideoTransceiver = peerConnection.addTransceiver("video", {direction: "sendrecv"})

    peerConnection.onicecandidate = (event) => {
      if (event.candidate && this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) {
        this.sendSignal(event.candidate)
      }
    }

    peerConnection.ontrack = (event) => {
      if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
      if (event.streams && event.streams[0]) {
        this.remoteStream = event.streams[0]
      } else if (this.remoteStream && this.remoteStream.addTrack) {
        this.remoteStream.addTrack(event.track)
      }
      // Playback itself is ACTIVE-gated by attachMediaStream. Re-emit on ACTIVE below.
      if (this.status === CALL_STATUS.ACTIVE) this.onRemoteStream(this.remoteStream)
    }

    peerConnection.oniceconnectionstatechange = () => {
      const state = peerConnection.iceConnectionState
      if (state === "connected" || state === "completed") {
        if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
        this.status = CALL_STATUS.ACTIVE
        this.applyOutgoingAudioGate()
        this.notifyStateChange()
        if (this.remoteStream) this.onRemoteStream(this.remoteStream)
        void this.activateLocalMedia(setupAttemptId, setupGeneration, peerConnection)
      } else if (state === "failed" && this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) {
        this.handleIceFailure()
      }
    }

    if (isOfferSide) {
      const offer = await peerConnection.createOffer()
      if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
      await peerConnection.setLocalDescription(offer)
      if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
      this.sendSignal(peerConnection.localDescription)
    }

    if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
    await this.flushPendingCandidates()
  } catch (error) {
    if (this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) {
      this.onError(error)
      this.teardown("connection_error")
    }
  }
}

async activateLocalMedia(callAttemptId, mediaGeneration, peerConnection) {
  if (!this.activeMediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection)) return
  if (!navigator.mediaDevices?.getUserMedia) return

  const acquisitionGeneration = ++this.activeMediaAcquisitionGeneration
  const needVideo = this.callType === "video" && !this.localVisualFloorClosed
  let stream
  try {
    stream = await navigator.mediaDevices.getUserMedia({audio: true, video: needVideo})
  } catch (error) {
    if (this.activeMediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection)) {
      this.onError(error)
      this.teardown("media_permission_failed")
    }
    return
  }

  if (
    this.activeMediaAcquisitionGeneration !== acquisitionGeneration ||
    !this.activeMediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection)
  ) {
    stopMediaTracks(stream)
    return
  }

  this.localStream = stream
  const audioTrack = stream.getAudioTracks?.()[0] || null
  const videoTrack = stream.getVideoTracks?.()[0] || null
  this.rawAudioTrack = audioTrack
  this.rawCameraTrack = videoTrack
  this.applyOutgoingAudioGate()

  if (audioTrack && this.transportAudioTransceiver?.sender?.replaceTrack) {
    await this.transportAudioTransceiver.sender.replaceTrack(audioTrack)
  }
  if (!this.activeMediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection)) {
    stopMediaTracks(stream)
    return
  }

  if (videoTrack && this.transportVideoTransceiver?.sender?.replaceTrack) {
    await this.transportVideoTransceiver.sender.replaceTrack(videoTrack)
  }
  if (!this.activeMediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection)) {
    stopMediaTracks(stream)
    return
  }

  this.selfVideo = Boolean(videoTrack)
  this.onLocalStream(stream)
  this.notifyStateChange()
}

sendSignal(signal) {
  if (!this.channel || !this.callAttemptId) return
  if (![CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status)) return
  this.channel.push("call:signal", {
    call_attempt_id: this.callAttemptId,
    media_generation: this.mediaGeneration,
    signal: JSON.parse(JSON.stringify(signal))
  })
}

  async flushPendingCandidates() {
    if (!this.peerConnection || !this.peerConnection.remoteDescription) return
    while (this.pendingCandidates.length > 0) {
      const cand = this.pendingCandidates.shift()
      try {
        if (cand.candidate) {
          await this.peerConnection.addIceCandidate(new RTCIceCandidate(cand))
        }
      } catch {
        // Ignore candidate addition errors
      }
    }
  }

async handleIceFailure() {
  const attemptId = this.callAttemptId
  const generation = this.mediaGeneration
  const peerConnection = this.peerConnection
  if (!this.mediaAttemptIsCurrent(attemptId, generation, peerConnection)) return

  try {
    const creds = await this.fetchCredentials()
    if (!this.mediaAttemptIsCurrent(attemptId, generation, peerConnection)) return
    if (peerConnection?.setConfiguration && creds?.ice_servers) {
      peerConnection.setConfiguration({iceServers: creds.ice_servers, iceTransportPolicy: "relay"})
      if (peerConnection.restartIce) peerConnection.restartIce()
    }
  } catch {
    if (this.mediaAttemptIsCurrent(attemptId, generation, peerConnection)) this.teardown("ice_failed")
  }
}

  async retryPlayback() {
    if (!this.remoteElement || !this.remoteStream) return
    if (this.status !== CALL_STATUS.ACTIVE) return
    attachMediaStream(this.remoteElement, this.remoteStream, this)
  }

  teardown(reason = "normal") {
    if (this.connectingTimer) {
      clearTimeout(this.connectingTimer)
      this.connectingTimer = null
    }

    this.cleanupEffectGraph()

    // Stop remote playback immediately on teardown
    if (this.remoteElement) {
      try { this.remoteElement.pause() } catch {}
      this.remoteElement.srcObject = null
      this.remoteElement = null
    }
    this.mediaReady = false
    this.playbackBlocked = false
    this.playbackAttemptGeneration++

    // Stop local media immediately
    stopMediaTracks(this.localStream)
    stopMediaTracks(this.localCameraStream)
    stopMediaTracks(this.localScreenStream)
    this.localStream = null
    this.localCameraStream = null
    this.localScreenStream = null
    this.rawAudioTrack = null
    this.rawCameraTrack = null
    this.processedAudioTrack = null

    if (this.localVideoElement) {
      this.localVideoElement.srcObject = null
      this.localVideoElement.hidden = true
    }
    if (this.remoteVideoElement) {
      try { this.remoteVideoElement.pause() } catch {}
      this.remoteVideoElement.srcObject = null
      this.remoteVideoElement.hidden = true
    }

    if (this.peerConnection) {
      try {
        this.peerConnection.close()
      } catch {}
      this.peerConnection = null
    }

    this.pendingCandidates = []
    this.transportAudioTransceiver = null
    this.transportVideoTransceiver = null
    this.activeMediaAcquisitionGeneration++
    this.presentedReactions.clear()
    this.callAttemptId = null
    this.role = null
    this.status = CALL_STATUS.TERMINAL
    this.selfMuted = false
    this.peerMuted = false
    this.selfVideo = false
    this.peerVideo = false
    this.screenSharing = false
    this.localVisualFloorClosed = false
    this.returnToVoiceGeneration = 0
    this.cameraAcquisitionGeneration++
    this.pendingVideoConsentFresh = false
    this.voiceEffectPreset = "plain"
    this.voiceEffectActive = false
    this.peerVoiceEffectActive = false
    this.activeAt = null

    this.notifyStateChange()

    setTimeout(() => {
      if (this.status === CALL_STATUS.TERMINAL) {
        this.status = CALL_STATUS.IDLE
        this.notifyStateChange()
      }
    }, 100)
  }
}

// --- StrangerTalks Ring Live Presence Component (Defect 3: 1Q-DELIGHT-02) ---

export class StrangerTalksRing {
  constructor(element, a11yStatusElement = null) {
    this.element = element
    this.a11yStatus = a11yStatusElement
    this.reactionPulseTimer = null
    this.localEnergy = 0.0
    this.peerEnergy = 0.0
    this.state = "idle"
  }

  update(callState, options = {}) {
    if (!this.element) return

    const { status, selfMuted, peerMuted } = callState
    const isTerminal = status === CALL_STATUS.TERMINAL || status === CALL_STATUS.IDLE
    const isConnecting = status === CALL_STATUS.CONNECTING || status === CALL_STATUS.PENDING_OUTGOING
    const isActive = status === CALL_STATUS.ACTIVE
    const isReconnecting = options.reconnecting || false

    // Precedence: Terminal state always wins
    if (isTerminal) {
      this.state = "idle"
      this.element.className = "stranger-call-ring ring-state-idle"
      if (this.reactionPulseTimer) {
        clearTimeout(this.reactionPulseTimer)
        this.reactionPulseTimer = null
      }
      this.setA11yText("Call ended")
      return
    }

    if (isReconnecting) {
      this.state = "reconnecting"
      this.element.className = "stranger-call-ring ring-state-reconnecting"
      this.setA11yText("Call Reconnecting")
      return
    }

    if (isConnecting) {
      this.state = "calling"
      this.element.className = "stranger-call-ring ring-state-calling"
      this.setA11yText("Connecting live call")
      return
    }

    if (isActive) {
      let ringClasses = ["stranger-call-ring", "ring-state-active"]
      let a11yMessage = "Call Active"

      if (selfMuted) {
        ringClasses.push("ring-state-muted")
        a11yMessage += ", Microphone Muted"
      }

      if (peerMuted) {
        ringClasses.push("ring-state-peer-muted")
      }

      // Audio Energy derivation: If human selfMuted = true, local energy cannot imply peer hears speech
      const effectiveLocalEnergy = selfMuted ? 0.0 : (options.localEnergy || 0.0)
      const peerEnergy = options.peerEnergy || 0.0

      if (effectiveLocalEnergy > 0.2) {
        ringClasses.push("ring-state-self-speaking")
      }
      if (peerEnergy > 0.2) {
        ringClasses.push("ring-state-peer-speaking")
      }

      if (options.hasReactionPulse) {
        ringClasses.push("ring-reaction-pulse")
      }

      this.element.className = ringClasses.join(" ")
      this.element.style.setProperty("--ring-local-energy", effectiveLocalEnergy.toFixed(2))
      this.element.style.setProperty("--ring-peer-energy", peerEnergy.toFixed(2))

      this.setA11yText(a11yMessage)
    }
  }

  pulseReaction() {
    if (!this.element) return
    this.element.classList.add("ring-reaction-pulse")
    if (this.reactionPulseTimer) clearTimeout(this.reactionPulseTimer)
    this.reactionPulseTimer = setTimeout(() => {
      if (this.element) {
        this.element.classList.remove("ring-reaction-pulse")
      }
      this.reactionPulseTimer = null
    }, 800)
  }

  setA11yText(text) {
    if (this.a11yStatus && this.a11yStatus.textContent !== text) {
      this.a11yStatus.textContent = text
    }
  }

  destroy() {
    if (this.reactionPulseTimer) {
      clearTimeout(this.reactionPulseTimer)
      this.reactionPulseTimer = null
    }
    if (this.element) {
      this.element.className = "stranger-call-ring ring-state-idle"
    }
  }
}
