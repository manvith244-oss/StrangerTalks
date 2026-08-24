from pathlib import Path
from textwrap import dedent


def D(value: str) -> str:
    return dedent(value).strip("\n")


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"{label}: start marker not found: {start!r}")
    b = text.find(end, a + len(start))
    if b < 0:
        raise RuntimeError(f"{label}: end marker not found: {end!r}")
    return text[:a] + replacement.rstrip() + "\n\n" + text[b:]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# T6-001: CONNECTING is a real media privacy boundary.
# ---------------------------------------------------------------------------
live_path = Path("priv/static/assets/live_call.mjs")
live = live_path.read_text()

if "canTransmitOutgoingAudio()" not in live:
    old = D('''
      notifyStateChange() {
        this.onStateChange(this.getState())
      }
    ''')
    new = D('''
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
    ''')
    live = replace_once(live, old, new, "insert media authority helpers")

live = replace_between(
    live,
    '  async handleCallAccepted({ call_attempt_id, callee_session_id, active_at }) {',
    '  handleCallEnded({ call_attempt_id, reason }) {',
    D('''
      async handleCallAccepted({ call_attempt_id, callee_session_id, active_at }) {
        if (this.callAttemptId !== call_attempt_id) return
        this.activeAt = active_at || Math.floor(Date.now() / 1000)
        this.status = CALL_STATUS.CONNECTING
        this.applyOutgoingAudioGate()
        this.notifyStateChange()

        if (this.role === "caller") await this.initializeWebRTC(true)
        else if (this.role === "callee") await this.initializeWebRTC(false)
      }
    '''),
    "handleCallAccepted"
)

live = replace_between(
    live,
    '  handleMuteChanged({ call_attempt_id, participant_id, is_muted }) {',
    '  handleEffectChanged({ call_attempt_id, participant_id, effect_active }) {',
    D('''
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
    '''),
    "handleMuteChanged"
)

live = replace_between(
    live,
    '  async handleSignal({ call_attempt_id, media_generation, signal, sender_id }) {',
    '  handleMediaRequested({ call_attempt_id, media_request_id, request_type, proposal, requester_id }) {',
    D('''
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
    '''),
    "handleSignal"
)

live = replace_between(
    live,
    '  async toggleMute() {',
    '  // --- Return to Voice',
    D('''
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
    '''),
    "toggleMute"
)

# Preserve the existing effect graph, but replace every transmission-opening write with the central gate.
live = replace_once(
    live,
    D('''
          this.rawAudioTrack.enabled = !this.selfMuted
          if (this.peerConnection) {
    '''),
    D('''
          this.applyOutgoingAudioGate()
          if (this.peerConnection) {
    '''),
    "plain voice expression gate"
)
live = replace_once(
    live,
    D('''
        if (!AudioCtx || !this.rawAudioTrack) {
          this.voiceEffectActive = true
          this.notifyStateChange()
    '''),
    D('''
        if (!AudioCtx || !this.rawAudioTrack) {
          this.voiceEffectActive = true
          this.applyOutgoingAudioGate()
          this.notifyStateChange()
    '''),
    "effect fallback gate"
)
live = replace_once(
    live,
    D('''
        this.processedAudioTrack.enabled = !this.selfMuted
        if (this.peerConnection) {
    '''),
    D('''
        this.applyOutgoingAudioGate()
        if (this.peerConnection) {
    '''),
    "processed voice expression gate"
)

live = replace_between(
    live,
    '  async initializeWebRTC(isOfferSide = false) {',
    '  sendSignal(signal) {',
    D('''
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

          peerConnection.onicecandidate = (event) => {
            if (event.candidate && this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) {
              this.sendSignal(event.candidate)
            }
          }

          peerConnection.ontrack = (event) => {
            if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
            if (event.streams && event.streams[0]) this.onRemoteStream(event.streams[0])
            else if (this.remoteStream && this.remoteStream.addTrack) {
              this.remoteStream.addTrack(event.track)
              this.onRemoteStream(this.remoteStream)
            }
          }

          peerConnection.oniceconnectionstatechange = () => {
            const state = peerConnection.iceConnectionState
            if (state === "connected" || state === "completed") {
              if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) return
              this.status = CALL_STATUS.ACTIVE
              if (this.callType === "video" && !this.localVisualFloorClosed) {
                this.selfVideo = true
                this.peerVideo = true
              }
              this.applyOutgoingAudioGate()
              this.notifyStateChange()
            } else if (state === "failed" && this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) {
              this.handleIceFailure()
            }
          }

          const needVideo = this.callType === "video" && !this.localVisualFloorClosed
          if (navigator.mediaDevices?.getUserMedia) {
            const acquiredStream = await navigator.mediaDevices.getUserMedia({audio: true, video: needVideo})
            if (!this.mediaAttemptIsCurrent(setupAttemptId, setupGeneration, peerConnection)) {
              stopMediaTracks(acquiredStream)
              return
            }

            this.localStream = acquiredStream
            const audioTracks = acquiredStream.getAudioTracks ? acquiredStream.getAudioTracks() : []
            if (audioTracks.length > 0) this.rawAudioTrack = audioTracks[0]
            this.applyOutgoingAudioGate()
            this.onLocalStream(acquiredStream)
            for (const track of acquiredStream.getTracks()) peerConnection.addTrack(track, acquiredStream)
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
    '''),
    "initializeWebRTC"
)

live = replace_between(
    live,
    '  sendSignal(signal) {',
    '  async flushPendingCandidates() {',
    D('''
      sendSignal(signal) {
        if (!this.channel || !this.callAttemptId) return
        if (![CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status)) return
        this.channel.push("call:signal", {
          call_attempt_id: this.callAttemptId,
          media_generation: this.mediaGeneration,
          signal: JSON.parse(JSON.stringify(signal))
        })
      }
    '''),
    "sendSignal"
)

live = replace_between(
    live,
    '  async handleIceFailure() {',
    '  async retryPlayback() {',
    D('''
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
    '''),
    "handleIceFailure"
)

# Screen Share is frozen OUT OF V1. Only Video upgrade is accepted by the public client method.
live = replace_once(
    live,
    D('''
      async requestMediaUpgrade(requestType = "video_upgrade", proposal = {}) {
        if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
        if (requestType === "video_upgrade") {
          this.pendingVideoConsentFresh = true
        }
    '''),
    D('''
      async requestMediaUpgrade(requestType = "video_upgrade", proposal = {}) {
        if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
        if (requestType !== "video_upgrade") throw new Error("Unsupported media upgrade")
        this.pendingVideoConsentFresh = true
    '''),
    "defer screen share client surface"
)
live_path.write_text(live)


# ---------------------------------------------------------------------------
# T6-004: late Voice Note permission must fail closed.
# ---------------------------------------------------------------------------
voice_path = Path("priv/static/assets/voice_notes.mjs")
voice = voice_path.read_text()
if "voiceCaptureStillAuthorized" not in voice:
    voice += D('''

      export function voiceCaptureStillAuthorized({
        requestId, currentRequestId, conversationId, currentConversationId,
        epochId, currentEpochId, conversationAvailable
      }) {
        return Boolean(
          conversationAvailable &&
          requestId === currentRequestId &&
          conversationId && conversationId === currentConversationId &&
          epochId && epochId === currentEpochId
        )
      }
    ''') + "\n"
voice_path.write_text(voice)

app_path = Path("priv/static/assets/app.js")
app = app_path.read_text()
app = replace_once(
    app,
    "  voiceDraftMatchesRuntime,\n  warningAcknowledged",
    "  voiceDraftMatchesRuntime, voiceCaptureStillAuthorized,\n  warningAcknowledged",
    "voice capture helper import"
)
app = replace_once(
    app,
    "originConversationId: null, originEpochId: null},",
    "originConversationId: null, originEpochId: null, captureRequestId: 0},",
    "voice capture request generation"
)
app = replace_between(
    app,
    'async function startVoiceRecording() {',
    'function updateVoiceTimer() {',
    D('''
      async function startVoiceRecording() {
        $("#voice-warning").hidden = true; clearVoicePreview(); $("#voice-preview-status").textContent = ""
        if (!app.voice.mediaType || !navigator.mediaDevices?.getUserMedia) { announce("Voice recording is unavailable in this browser. Text messaging still works."); return }

        const captureRequestId = ++app.voice.captureRequestId
        const captureConversationId = app.conversationId
        const captureEpochId = app.currentEpochId

        try {
          const stream = await navigator.mediaDevices.getUserMedia({audio: true})
          if (!voiceCaptureStillAuthorized({
            requestId: captureRequestId,
            currentRequestId: app.voice.captureRequestId,
            conversationId: captureConversationId,
            currentConversationId: app.conversationId,
            epochId: captureEpochId,
            currentEpochId: app.currentEpochId,
            conversationAvailable: Boolean(app.conversation)
          })) {
            stopMediaTracks(stream)
            return
          }

          const recorder = new MediaRecorder(stream, {mimeType: app.voice.mediaType, audioBitsPerSecond: 64_000})
          Object.assign(app.voice, {stream, recorder, chunks: [], startedAt: Date.now(), discard: false, originConversationId: app.conversationId, originEpochId: app.currentEpochId})
          recorder.addEventListener("dataavailable", ({data}) => { if (data.size) app.voice.chunks.push(data) })
          recorder.addEventListener("stop", finishVoiceRecording, {once: true})
          recorder.start(); $("#voice-recording").hidden = false; $("#voice-recording-waveform")?.classList.add("active"); updateVoiceTimer()
          app.voice.timer = setInterval(updateVoiceTimer, 250)
          app.voice.stopTimer = setTimeout(() => { if (recorder.state === "recording") recorder.stop() }, MAX_VOICE_DURATION_MS)
        } catch {
          if (app.voice.captureRequestId === captureRequestId) {
            closeVoiceStream(); announce("Microphone access was not granted. Text messaging is still available.")
          }
        }
      }
    '''),
    "startVoiceRecording"
)
app = replace_between(
    app,
    'function cancelRecording() {',
    'async function sendVoicePreview() {',
    D('''
      function cancelRecording() {
        app.voice.captureRequestId++
        app.voice.discard = true
        if (app.voice.recorder?.state === "recording") app.voice.recorder.stop()
        else { closeVoiceStream(); clearVoicePreview() }
      }
    '''),
    "cancelRecording"
)
app = replace_once(
    app,
    '$("#block").addEventListener("click", async () => { if (confirm("Block this person from future matches? Reporting is separate.")) { await push(app.conversation, "conversation:block"); announce("This person is blocked from future matching.") } })',
    '$("#block").addEventListener("click", async () => { if (confirm("Block this person from future matches? Reporting is separate.")) { app.liveCall?.teardown("blocked_by_user"); cancelRecording(); await push(app.conversation, "conversation:block"); announce("This person is blocked from future matching.") } })',
    "Block local media dominance"
)
app_path.write_text(app)


# ---------------------------------------------------------------------------
# T6-002: one authoritative endpoint owns live media controls.
# ---------------------------------------------------------------------------
server_path = Path("lib/strangertalks_new/conversation_lifecycle/conversation_server.ex")
server = server_path.read_text()
get_call_marker = '  def handle_call({:get_call_state, participant_id}, _from, state) do\n'
if "{:authorized_media_action" not in server:
    gate = D('''
      def handle_call(
            {:authorized_media_action, participant_id, channel_pid, session_id, call_attempt_id,
             message},
            from,
            state
          ) do
        case state.call_state do
          %{call_attempt_id: ^call_attempt_id} = call ->
            cond do
              not member?(state, participant_id) ->
                handle_call(message, from, state)

              authoritative_media_endpoint?(call, participant_id, channel_pid, session_id) ->
                handle_call(message, from, state)

              true ->
                {:reply, {:error, :not_media_endpoint}, state}
            end

          _ ->
            handle_call(message, from, state)
        end
      end

    ''')
    server = replace_once(server, get_call_marker, gate + get_call_marker, "authoritative media handle gate")

admitted_marker = '  defp admitted_call(conversation_id, message, mailbox_limit, pressure_error) do\n'
if "defp wrap_media_endpoint_action" not in server:
    helpers = D('''
      defp authoritative_media_endpoint?(call, participant_id, channel_pid, session_id) do
        cond do
          participant_id == Map.get(call, :caller_id) ->
            Map.get(call, :caller_endpoint_pid) == channel_pid and
              Map.get(call, :caller_session_id) == session_id

          participant_id == Map.get(call, :callee_id) ->
            Map.get(call, :callee_endpoint_pid) == channel_pid and
              Map.get(call, :callee_session_id) == session_id

          true ->
            false
        end
      end

      @media_endpoint_actions [
        :cancel_call,
        :end_call,
        :set_call_mute,
        :set_call_effect,
        :signal_call,
        :request_call_media,
        :respond_call_media,
        :request_call_credentials,
        :return_to_voice,
        :send_call_reaction,
        :set_reveal_ready,
        :commit_call_extension
      ]

      defp wrap_media_endpoint_action(message) when is_tuple(message) and tuple_size(message) >= 5 do
        if elem(message, 0) in @media_endpoint_actions do
          {:authorized_media_action, elem(message, 1), elem(message, 2), elem(message, 3),
           elem(message, 4), message}
        else
          message
        end
      end

      defp wrap_media_endpoint_action(message), do: message

    ''')
    server = replace_once(server, admitted_marker, helpers + admitted_marker, "authoritative media helpers")

server = replace_once(
    server,
    D('''
      defp admitted_call(conversation_id, message, mailbox_limit, pressure_error) do
        with {:ok, pid} <- lookup(conversation_id),
             :ok <- mailbox_admission(pid, mailbox_limit, pressure_error) do
          call_pid(pid, message)
    '''),
    D('''
      defp admitted_call(conversation_id, message, mailbox_limit, pressure_error) do
        with {:ok, pid} <- lookup(conversation_id),
             :ok <- mailbox_admission(pid, mailbox_limit, pressure_error) do
          call_pid(pid, wrap_media_endpoint_action(message))
    '''),
    "admitted_call endpoint wrapper"
)

# Replace the entire request media handler so unknown/screen-share requests are rejected.
server = replace_between(
    server,
    D('''
      def handle_call(
            {:request_call_media, participant_id, _channel_pid, _session_id, call_attempt_id,
             request_type, proposal},
            _from,
            state
          ) do
    '''),
    D('''
      def handle_call(
            {:set_reveal_ready, participant_id, _channel_pid, _session_id, call_attempt_id,
    '''),
    D('''
      def handle_call(
            {:request_call_media, participant_id, _channel_pid, _session_id, call_attempt_id,
             request_type, proposal},
            _from,
            state
          ) do
        if not member?(state, participant_id) do
          {:reply, {:error, :not_conversation_member}, state}
        else
          case state.call_state do
            %{call_attempt_id: ^call_attempt_id, status: :ACTIVE} = call ->
              if request_type not in [:video_upgrade, "video_upgrade"] do
                {:reply, {:error, :unsupported_media_type}, state}
              else
                media_request_id = Ecto.UUID.generate()
                other_id = other_participant(state, participant_id)
                timer_ref =
                  Process.send_after(self(), {:media_request_timeout, call_attempt_id, media_request_id}, 20_000)

                mode =
                  case proposal do
                    %{"mode" => "REVEAL_TOGETHER"} -> "REVEAL_TOGETHER"
                    %{mode: :reveal_together} -> "REVEAL_TOGETHER"
                    %{mode: "REVEAL_TOGETHER"} -> "REVEAL_TOGETHER"
                    _ -> "STANDARD_VIDEO"
                  end

                req_info = %{
                  media_request_id: media_request_id,
                  request_type: :video_upgrade,
                  requester_id: participant_id,
                  proposal: proposal,
                  mode: mode,
                  ready_state: %{participant_id => false, other_id => false},
                  status: :PENDING,
                  timer_ref: timer_ref
                }
                updated_call = %{call | media_requests: Map.put(call.media_requests, media_request_id, req_info)}
                state = %{state | call_state: updated_call}
                notify_participant(state, other_id, {:call_media_requested, %{
                  call_attempt_id: call_attempt_id,
                  media_request_id: media_request_id,
                  request_type: "video_upgrade",
                  proposal: proposal,
                  requester_id: participant_id
                }})
                {:reply, {:ok, %{media_request_id: media_request_id}}, state}
              end

            _ ->
              {:reply, {:error, :invalid_call_state}, state}
          end
        end
      end
    '''),
    "request_call_media deferred screen share"
)
server_path.write_text(server)


# ---------------------------------------------------------------------------
# T6-003: legitimate server-side provider configuration, otherwise fail closed.
# ---------------------------------------------------------------------------
c11_path = Path("lib/strangertalks_new/c11_policy.ex")
c11 = c11_path.read_text()
c11 = replace_once(
    c11,
    "          usage_max_staleness_ms: integer()\n        }",
    "          usage_max_staleness_ms: integer(),\n          provider_credentials: map()\n        }",
    "C11 state provider_credentials type"
)
c11 = replace_once(
    c11,
    "      usage_max_staleness_ms: Keyword.get(opts, :usage_max_staleness_ms, 60_000)\n    }",
    D('''
          usage_max_staleness_ms: Keyword.get(opts, :usage_max_staleness_ms, 60_000),
          provider_credentials:
            Keyword.get(
              opts,
              :provider_credentials,
              Application.get_env(:strangertalks_new, :turn_provider_credentials, %{})
            )
        }
    '''),
    "C11 init provider_credentials"
)

c11 = replace_between(
    c11,
    '  def admit_and_reserve(state, conversation_id, call_attempt_id, now \\ nil) do',
    '  @doc """\n  Gating for credential extensions.',
    D('''
      def admit_and_reserve(state, conversation_id, call_attempt_id, now \\ nil) do
        current_time = now || System.monotonic_time(:millisecond)
        state = cleanup_expired_exposures(state, current_time)
        oracle_ready = state.primary_available and provider_configured?(state, :oracle)
        cloudflare_ready = state.fallback_available and provider_configured?(state, :cloudflare)

        cond do
          not state.quotas_verified -> {:error, :unverified_provider_quotas, state}
          is_nil(state.credential_ttl_seconds) or not is_integer(state.credential_ttl_seconds) or state.credential_ttl_seconds <= 0 ->
            {:error, :unverified_credential_ttl, state}

          oracle_ready ->
            reservation = %{
              provider: :oracle,
              reserved_at: current_time,
              expires_at: current_time + state.credential_ttl_seconds * 1000,
              conversation_id: conversation_id,
              call_attempt_id: call_attempt_id
            }
            {:ok, :oracle, put_in(state.active_reservations[call_attempt_id], reservation)}

          cloudflare_ready and quarantined?(state, current_time) -> {:error, :quarantine_active, state}
          cloudflare_ready and stale_or_missing_snapshot?(state, current_time) -> {:error, :stale_usage_snapshot, state}

          cloudflare_ready and safe_capacity_available?(state) ->
            reservation = %{
              provider: :cloudflare,
              reserved_at: current_time,
              expires_at: current_time + state.credential_ttl_seconds * 1000,
              conversation_id: conversation_id,
              call_attempt_id: call_attempt_id
            }
            {:ok, :cloudflare, put_in(state.active_reservations[call_attempt_id], reservation)}

          (state.primary_available and not provider_configured?(state, :oracle)) or
              (state.fallback_available and not provider_configured?(state, :cloudflare)) ->
            {:error, :provider_not_configured, state}

          true -> {:error, :capacity_busy, state}
        end
      end
    '''),
    "C11 admission"
)

c11 = replace_between(
    c11,
    '  def admit_extension(state, call_attempt_id, now \\ nil) do',
    '  @doc """\n  Records human call termination.',
    D('''
      def admit_extension(state, call_attempt_id, now \\ nil) do
        current_time = now || System.monotonic_time(:millisecond)

        cond do
          is_nil(state.credential_ttl_seconds) or not is_integer(state.credential_ttl_seconds) or state.credential_ttl_seconds <= 0 ->
            {:error, :unverified_credential_ttl, state}

          true ->
            case Map.get(state.active_reservations, call_attempt_id) do
              nil -> {:error, :no_active_reservation, state}
              %{provider: provider} = reservation when provider in [:oracle, :cloudflare] ->
                cond do
                  not provider_configured?(state, provider) -> {:error, :provider_not_configured, state}
                  provider == :cloudflare and stale_or_missing_snapshot?(state, current_time) -> {:error, :stale_usage_snapshot, state}
                  true ->
                    updated = %{reservation | expires_at: current_time + state.credential_ttl_seconds * 1000}
                    {:ok, provider, put_in(state.active_reservations[call_attempt_id], updated)}
                end
            end
        end
      end
    '''),
    "C11 extension"
)

c11 = replace_between(
    c11,
    '  def authorize_credentials(provider, _conversation_id, _participant_id, call_attempt_id, ttl) do',
    '  # --- Internal Helpers ---',
    D('''
      def authorize_credentials(provider, _conversation_id, _participant_id, call_attempt_id, ttl) do
        if is_nil(ttl) or not is_integer(ttl) or ttl <= 0 do
          {:error, :unverified_credential_ttl}
        else
          config = provider_config(provider)
          if valid_provider_config?(provider, config),
            do: issue_provider_credentials(provider, config, call_attempt_id, ttl),
            else: {:error, :provider_not_configured}
        end
      end

      defp issue_provider_credentials(:oracle, config, call_attempt_id, ttl) do
        opaque_token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
        username = "#{System.system_time(:second) + ttl}:#{opaque_token}"
        credential = :crypto.mac(:hmac, :sha, config.shared_secret, username) |> Base.encode64()
        {:ok, %{provider: :oracle, ice_servers: [%{urls: config.urls, username: username, credential: credential}],
          ice_transport_policy: "relay", ttl_seconds: ttl, call_attempt_id: call_attempt_id}}
      end

      defp issue_provider_credentials(:cloudflare, config, call_attempt_id, ttl) do
        result =
          case Map.get(config, :client) do
            client when is_atom(client) ->
              if function_exported?(client, :generate_ice_servers, 2),
                do: client.generate_ice_servers(config, ttl),
                else: {:error, :provider_credential_unavailable}

            _ ->
              endpoint = Map.get(config, :endpoint, "https://rtc.live.cloudflare.com")
              url = "#{String.trim_trailing(endpoint, "/")}/v1/turn/keys/#{URI.encode(config.key_id)}/credentials/generate-ice-servers"
              case Req.post(url, headers: [{"authorization", "Bearer #{config.api_token}"}], json: %{ttl: ttl}, receive_timeout: 5_000) do
                {:ok, %Req.Response{status: 201, body: body}} -> {:ok, Map.get(body, "iceServers") || Map.get(body, :iceServers) || []}
                _ -> {:error, :provider_credential_unavailable}
              end
          end

        with {:ok, servers} <- result,
             relay_servers when relay_servers != [] <- relay_only_ice_servers(servers) do
          {:ok, %{provider: :cloudflare, ice_servers: relay_servers, ice_transport_policy: "relay",
            ttl_seconds: ttl, call_attempt_id: call_attempt_id}}
        else
          _ -> {:error, :provider_credential_unavailable}
        end
      end

      defp relay_only_ice_servers(servers) when is_list(servers) do
        Enum.flat_map(servers, fn server ->
          urls = (Map.get(server, "urls") || Map.get(server, :urls) || [])
                 |> List.wrap()
                 |> Enum.filter(fn url -> is_binary(url) and (String.starts_with?(url, "turn:") or String.starts_with?(url, "turns:")) end)
          username = Map.get(server, "username") || Map.get(server, :username)
          credential = Map.get(server, "credential") || Map.get(server, :credential)
          if urls != [] and is_binary(username) and username != "" and is_binary(credential) and credential != "",
            do: [%{urls: urls, username: username, credential: credential}], else: []
        end)
      end
      defp relay_only_ice_servers(_), do: []

      defp provider_config(provider) do
        Application.get_env(:strangertalks_new, :turn_provider_credentials, %{}) |> Map.get(provider)
      end
      defp provider_configured?(state, provider), do: valid_provider_config?(provider, Map.get(state.provider_credentials, provider))

      defp valid_provider_config?(:oracle, %{strategy: :coturn_rest, urls: urls, shared_secret: secret}) do
        is_list(urls) and urls != [] and
          Enum.all?(urls, fn url -> is_binary(url) and (String.starts_with?(url, "turn:") or String.starts_with?(url, "turns:")) end) and
          is_binary(secret) and secret != ""
      end
      defp valid_provider_config?(:cloudflare, %{strategy: :cloudflare_api, key_id: key_id, api_token: token}) do
        is_binary(key_id) and key_id != "" and is_binary(token) and token != ""
      end
      defp valid_provider_config?(_, _), do: false
    '''),
    "C11 credential issuance"
)
c11_path.write_text(c11)


# Runtime configuration supplies secrets only through environment variables.
runtime_path = Path("config/runtime.exs")
runtime = runtime_path.read_text()
if "turn_provider_credentials = %{}" not in runtime:
    marker = 'config :strangertalks_new, :google_continuity, google_continuity\n'
    block = D('''
      config :strangertalks_new, :google_continuity, google_continuity

      turn_oracle_urls = System.get_env("TURN_ORACLE_URLS", "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      turn_oracle_secret = System.get_env("TURN_ORACLE_SHARED_SECRET")
      cloudflare_turn_key_id = System.get_env("CLOUDFLARE_TURN_KEY_ID")
      cloudflare_turn_api_token = System.get_env("CLOUDFLARE_TURN_API_TOKEN")

      turn_provider_credentials = %{}
      turn_provider_credentials =
        if turn_oracle_urls != [] and is_binary(turn_oracle_secret) and turn_oracle_secret != "" do
          Map.put(turn_provider_credentials, :oracle, %{strategy: :coturn_rest, urls: turn_oracle_urls, shared_secret: turn_oracle_secret})
        else
          turn_provider_credentials
        end
      turn_provider_credentials =
        if is_binary(cloudflare_turn_key_id) and cloudflare_turn_key_id != "" and is_binary(cloudflare_turn_api_token) and cloudflare_turn_api_token != "" do
          Map.put(turn_provider_credentials, :cloudflare, %{strategy: :cloudflare_api, key_id: cloudflare_turn_key_id,
            api_token: cloudflare_turn_api_token, endpoint: "https://rtc.live.cloudflare.com"})
        else
          turn_provider_credentials
        end
      config :strangertalks_new, :turn_provider_credentials, turn_provider_credentials
    ''') + "\n"
    runtime = replace_once(runtime, marker, block, "runtime TURN provider contract")
runtime_path.write_text(runtime)

# Test environment uses explicit test-only provider configuration and an injected client.
test_cfg_path = Path("config/test.exs")
test_cfg = test_cfg_path.read_text()
if ":turn_provider_credentials" not in test_cfg:
    test_cfg += D('''

      config :strangertalks_new, :turn_provider_credentials, %{
        oracle: %{strategy: :coturn_rest, urls: ["turn:127.0.0.1:3478?transport=udp"], shared_secret: "team6-test-only-coturn-secret"},
        cloudflare: %{strategy: :cloudflare_api, key_id: "team6-test-key-id", api_token: "team6-test-token",
          client: StrangertalksNew.TurnCredentialTestClient}
      }
    ''') + "\n"
test_cfg_path.write_text(test_cfg)

Path("test/support/turn_credential_test_client.ex").write_text(D('''
  defmodule StrangertalksNew.TurnCredentialTestClient do
    @moduledoc false
    def generate_ice_servers(_config, _ttl) do
      {:ok, [%{"urls" => ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:5349?transport=tcp"],
        "username" => "team6-test-user", "credential" => "team6-test-credential"}]}
    end
  end
''') + "\n")

Path("test/strangertalks_new/team6_turn_provider_test.exs").write_text(D('''
  defmodule StrangertalksNew.Team6TurnProviderTest do
    use ExUnit.Case, async: false
    alias StrangertalksNew.C11Policy

    test "available provider without legitimate credential config fails closed" do
      state = C11Policy.init_state(quotas_verified: true, primary_available: true, fallback_available: false,
        credential_ttl_seconds: 300, provider_credentials: %{})
      assert {:error, :provider_not_configured, _} = C11Policy.admit_and_reserve(state, "conversation", "attempt")
    end

    test "configured Coturn REST credentials are opaque and relay-only" do
      assert {:ok, creds} = C11Policy.authorize_credentials(:oracle, "raw-conversation", "raw-participant", "attempt-a", 300)
      assert creds.ice_transport_policy == "relay"
      assert Enum.all?(creds.ice_servers, fn server -> Enum.all?(List.wrap(server.urls), &(String.starts_with?(&1, "turn:") or String.starts_with?(&1, "turns:"))) end)
      refute inspect(creds) =~ "raw-conversation"
      refute inspect(creds) =~ "raw-participant"
    end

    test "Cloudflare response is stripped to TURN/TURNS entries" do
      assert {:ok, creds} = C11Policy.authorize_credentials(:cloudflare, "c", "p", "attempt-b", 300)
      urls = Enum.flat_map(creds.ice_servers, &List.wrap(&1.urls))
      assert urls != []
      assert Enum.all?(urls, &(String.starts_with?(&1, "turn:") or String.starts_with?(&1, "turns:")))
      refute Enum.any?(urls, &String.starts_with?(&1, "stun:"))
    end

    test "placeholder production secrets and relay hostname are absent" do
      source = File.read!("lib/strangertalks_new/c11_policy.ex")
      refute source =~ "coturn_ephemeral_key"
      refute source =~ "cf_ephemeral_secret"
      refute source =~ "relay.strangertalks.internal"
    end
  end
''') + "\n")

# Provider-independent media privacy/scope tests.
Path("test/js/team6_voice_note_permission_test.mjs").write_text(D(r'''
  import assert from "node:assert/strict"
  import test from "node:test"
  import {readFileSync} from "node:fs"
  import {voiceCaptureStillAuthorized} from "../../priv/static/assets/voice_notes.mjs"

  test("voice capture authority rejects cancel, terminal, stale request, conversation and epoch changes", () => {
    const base = {requestId: 2, currentRequestId: 2, conversationId: "c", currentConversationId: "c", epochId: "e", currentEpochId: "e", conversationAvailable: true}
    assert.equal(voiceCaptureStillAuthorized(base), true)
    assert.equal(voiceCaptureStillAuthorized({...base, currentRequestId: 3}), false)
    assert.equal(voiceCaptureStillAuthorized({...base, conversationAvailable: false}), false)
    assert.equal(voiceCaptureStillAuthorized({...base, currentConversationId: "other"}), false)
    assert.equal(voiceCaptureStillAuthorized({...base, currentEpochId: "new"}), false)
  })

  test("late permission stream is stopped before MediaRecorder construction", () => {
    const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
    const guard = source.indexOf("voiceCaptureStillAuthorized({")
    const stop = source.indexOf("stopMediaTracks(stream)", guard)
    const recorder = source.indexOf("new MediaRecorder(stream", guard)
    assert.ok(guard >= 0 && stop > guard && recorder > stop)
    assert.match(source, /function cancelRecording\(\)\s*\{[\s\S]*app\.voice\.captureRequestId\+\+/)
  })

  test("Conversation End and Block invalidate Voice Note capture authority", () => {
    const source = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
    assert.match(source, /conversation:ended[\s\S]*cancelRecording\(\)/)
    assert.match(source, /#block[\s\S]*cancelRecording\(\)[\s\S]*conversation:block/)
  })
''') + "\n")

Path("test/js/team6_media_privacy_test.mjs").write_text(D(r'''
  import assert from "node:assert/strict"
  import test from "node:test"
  import {readFileSync} from "node:fs"
  const live = readFileSync(new URL("../../priv/static/assets/live_call.mjs", import.meta.url), "utf8")
  const app = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

  test("live calling has no recording, transcription, biometric, or display-capture implementation", () => {
    assert.doesNotMatch(live, /MediaRecorder/)
    assert.doesNotMatch(live, /getDisplayMedia/)
    assert.doesNotMatch(live, /transcript|transcription|voice biometric|face biometric|emotion detection/i)
  })

  test("Screen Share is not presented as an implemented capture control", () => {
    assert.doesNotMatch(app, /getDisplayMedia/)
    assert.doesNotMatch(app, /screen[- ]?share/i)
  })
''') + "\n")

# Append hostile Connecting tests.
gate_path = Path("test/js/team6_media_gate_test.mjs")
gate = gate_path.read_text()
if "late getUserMedia resolution cannot resurrect" not in gate:
    gate += D(r'''

      test("late getUserMedia resolution cannot resurrect a terminal call", async () => {
        const originalNavigator = globalThis.navigator
        const originalRTC = globalThis.RTCPeerConnection
        let resolveMedia
        const stopped = []
        const audioTrack = {kind: "audio", enabled: true, stop() { stopped.push("audio") }}
        const stream = {getAudioTracks: () => [audioTrack], getTracks: () => [audioTrack]}
        class FakePC { constructor() { this.iceConnectionState = "new"; this.senders = [] } addTrack(track) { this.senders.push({track}) } getSenders() { return this.senders } close() {} }
        Object.defineProperty(globalThis, "navigator", {configurable: true, value: {mediaDevices: {getUserMedia: () => new Promise(resolve => { resolveMedia = resolve })}}})
        globalThis.RTCPeerConnection = FakePC
        const channel = {push() { return phoenixPushOk({ice_servers: [{urls: ["turn:relay.invalid:3478"]}]}) }}
        try {
          const coord = new LiveCallCoordinator({participantId: "user-1", conversationId: "conv-1", channel})
          coord.callAttemptId = "attempt-1"; coord.role = "caller"; coord.status = CALL_STATUS.CONNECTING
          const initializing = coord.initializeWebRTC(false)
          await new Promise(resolve => setImmediate(resolve))
          coord.teardown("conversation_ended")
          resolveMedia(stream)
          await initializing
          assert.deepEqual(stopped, ["audio"])
          assert.equal(coord.localStream, null)
          assert.notEqual(coord.status, CALL_STATUS.ACTIVE)
        } finally {
          if (originalNavigator === undefined) delete globalThis.navigator
          else Object.defineProperty(globalThis, "navigator", {configurable: true, value: originalNavigator})
          if (originalRTC === undefined) delete globalThis.RTCPeerConnection
          else globalThis.RTCPeerConnection = originalRTC
        }
      })

      test("stale previous-attempt authority cannot become current", () => {
        const coord = new LiveCallCoordinator({participantId: "user-1", conversationId: "conv-1"})
        coord.callAttemptId = "attempt-new"; coord.mediaGeneration = 2; coord.status = CALL_STATUS.CONNECTING
        assert.equal(coord.mediaAttemptIsCurrent("attempt-old", 2, null), false)
        assert.equal(coord.mediaAttemptIsCurrent("attempt-new", 1, null), false)
      })

      test("terminal teardown stops local hardware and closes peer connection", () => {
        const stopped = []; let closed = false
        const audio = {kind: "audio", enabled: false, stop() { stopped.push("audio") }}
        const video = {kind: "video", enabled: true, stop() { stopped.push("video") }}
        const coord = new LiveCallCoordinator({participantId: "user-1", conversationId: "conv-1"})
        coord.callAttemptId = "attempt"; coord.status = CALL_STATUS.CONNECTING
        coord.localStream = {getTracks: () => [audio], getAudioTracks: () => [audio]}
        coord.localCameraStream = {getTracks: () => [video]}
        coord.peerConnection = {close() { closed = true }}
        coord.teardown("blocked")
        assert.deepEqual(stopped.sort(), ["audio", "video"])
        assert.equal(closed, true)
        assert.equal(coord.callAttemptId, null)
        assert.equal(coord.status, CALL_STATUS.TERMINAL)
      })
    ''') + "\n"
gate_path.write_text(gate)

# Add endpoint attacks to the existing fixture file.
authority_path = Path("test/strangertalks_new/team6_media_authority_test.exs")
authority = authority_path.read_text()
if "sibling tab cannot mutate effect or reaction state" not in authority:
    addition = D('''

      test "sibling tab cannot mutate effect or reaction state" do
        %{conv: conv, p1: p1, attempt: attempt} = active_call()
        sibling = endpoint()
        assert {:error, :not_media_endpoint} = ConversationServer.set_call_effect(conv.conversation_id, p1, sibling, "p1-sibling", attempt, true)
        assert {:error, :not_media_endpoint} = ConversationServer.send_call_reaction(conv.conversation_id, p1, sibling, "p1-sibling", attempt, "rx-sibling", "heart")
      end

      test "owner endpoint disappearance does not transfer media authority to sibling" do
        %{conv: conv, p1: p1, p1_owner: owner, attempt: attempt} = active_call()
        sibling = endpoint()
        Process.exit(owner, :kill)
        Process.sleep(20)
        assert {:error, :not_media_endpoint} = ConversationServer.set_call_mute(conv.conversation_id, p1, sibling, "p1-sibling", attempt, true)
        assert {:ok, state} = ConversationServer.get_call_state(conv.conversation_id, p1)
        assert state.self_muted == false
      end
    ''')
    pos = authority.rfind("\nend")
    if pos < 0:
        raise RuntimeError("authority test module end not found")
    authority = authority[:pos] + addition + authority[pos:]
authority_path.write_text(authority)

print("TEAM6_DIRECT_REMEDIATION_APPLIED")
