from pathlib import Path

path = Path("tmp/team6_direct_remediate.py")
text = path.read_text()

# Replace the whitespace-sensitive helper insertion with a function-boundary insertion.
start = text.index('if "canTransmitOutgoingAudio()" not in live:')
end = text.index('\nlive = replace_between(', start)
replacement = r"""if "canTransmitOutgoingAudio()" not in live:
    helpers = D('''
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
    live = replace_between(
        live,
        '  notifyStateChange() {',
        '  // --- Channel Event Handlers ---',
        helpers,
        "insert media authority helpers"
    )
"""
text = text[:start] + replacement + text[end:]

# Replace the temporary Voice Expression edit plan with a function-scoped transformation.
effect_plan_start = text.index('# Preserve the existing effect graph')
init_plan_start = text.index("live = replace_between(\n    live,\n    '  async initializeWebRTC", effect_plan_start)
effect_plan = r'''# Voice Expression transmission authority is applied only to the selected sender track.
effect_start = live.index('  async setVoiceExpression(preset = "plain") {')
effect_end = live.index('  cleanupEffectGraph() {', effect_start)
effect_source = live[effect_start:effect_end]

plain_old = 'this.rawAudioTrack.enabled = !this.selfMuted'
if effect_source.count(plain_old) != 1:
    raise RuntimeError(f"plain effect gate: expected one match, found {effect_source.count(plain_old)}")
effect_source = effect_source.replace(plain_old, 'this.rawAudioTrack.enabled = this.canTransmitOutgoingAudio()', 1)

processed_old = 'this.processedAudioTrack.enabled = !this.selfMuted'
if effect_source.count(processed_old) != 1:
    raise RuntimeError(f"processed effect gate: expected one match, found {effect_source.count(processed_old)}")
effect_source = effect_source.replace(processed_old, 'this.processedAudioTrack.enabled = this.canTransmitOutgoingAudio()', 1)

live = live[:effect_start] + effect_source + live[effect_end:]

'''
text = text[:effect_plan_start] + effect_plan + text[init_plan_start:]

# Replace the indentation-sensitive Screen Share client edit plan with a complete public-method replacement.
screen_plan_start = text.index('# Screen Share is frozen OUT OF V1.')
screen_plan_end = text.index('live_path.write_text(live)', screen_plan_start)
screen_plan = r"""# Screen Share is frozen OUT OF V1. Only Video upgrade is accepted by the public client method.
live = replace_between(
    live,
    '  async requestMediaUpgrade(requestType = "video_upgrade", proposal = {}) {',
    '  async respondMediaUpgrade(mediaRequestId, decision = "accept") {',
    D('''
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
    '''),
    "defer screen share client surface"
)
"""
text = text[:screen_plan_start] + screen_plan + text[screen_plan_end:]

# The admitted-call source change is a one-token semantic replacement inside a known private function.
admitted_plan_start = text.index('server = replace_once(\n    server,\n    D(\'\'\'\n      defp admitted_call')
admitted_plan_end = text.index('\n# Replace the entire request media handler', admitted_plan_start)
admitted_plan = r'''admitted_call_old = '      call_pid(pid, message)'
if server.count(admitted_call_old) != 1:
    raise RuntimeError(f"admitted_call endpoint wrapper: expected one call_pid match, found {server.count(admitted_call_old)}")
server = server.replace(admitted_call_old, '      call_pid(pid, wrap_media_endpoint_action(message))', 1)

'''
text = text[:admitted_plan_start] + admitted_plan + text[admitted_plan_end:]

# Defer the legacy Screen Share server-request rejection to the final hardening pass.
request_plan_start = text.index('# Replace the entire request media handler so unknown/screen-share requests are rejected.')
request_plan_end = text.index('server_path.write_text(server)', request_plan_start)
text = text[:request_plan_start] + '# Screen Share server request rejection is applied in the final hardening pass.\n' + text[request_plan_end:]

# C11 transformations replace whole functions; use formatter-independent function-name boundaries.
text = text.replace("    '  def admit_and_reserve(state, conversation_id, call_attempt_id, now \\\\ nil) do',", "    '  def admit_and_reserve(',", 1)
text = text.replace("    '  def admit_extension(state, call_attempt_id, now \\\\ nil) do',", "    '  def admit_extension(',", 1)
text = text.replace("    '  def authorize_credentials(provider, _conversation_id, _participant_id, call_attempt_id, ttl) do',", "    '  def authorize_credentials(',", 1)

# Preserve valid boundaries when the direct script inserts server and test blocks.
text = text.replace(
    '    server = replace_once(server, get_call_marker, gate + get_call_marker, "authoritative media handle gate")',
    '    server = replace_once(server, get_call_marker, gate + "\\n\\n" + get_call_marker, "authoritative media handle gate")',
    1,
)
text = text.replace(
    '    authority = authority[:pos] + addition + authority[pos:]',
    '    authority = authority[:pos] + "\\n\\n" + addition + authority[pos:]',
    1,
)

path.write_text(text)
print("TEAM6_REMEDIATION_HARNESS_PREPARED")
