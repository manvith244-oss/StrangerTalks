from pathlib import Path

path = Path("tmp/team6_direct_remediate.py")
text = path.read_text()

# Replace the whitespace-sensitive helper insertion with a function-boundary
# insertion. This mutates only the temporary remediation script.
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

# Replace the entire temporary Voice Expression edit plan with a function-scoped
# transformation. This avoids indentation-sensitive matching and preserves the
# existing fail-closed no-AudioContext path: raw audio was disabled immediately
# before effect setup and remains disabled when setup cannot be completed.
effect_plan_start = text.index('# Preserve the existing effect graph')
init_plan_start = text.index("live = replace_between(\n    live,\n    '  async initializeWebRTC", effect_plan_start)
effect_plan = r'''# Voice Expression transmission authority is applied only to the track that is
# about to become the sender. Never run the all-track gate before replaceTrack,
# because the old sender may still reference raw microphone audio.
effect_start = live.index('  async setVoiceExpression(preset = "plain") {')
effect_end = live.index('  cleanupEffectGraph() {', effect_start)
effect_source = live[effect_start:effect_end]

plain_old = 'this.rawAudioTrack.enabled = !this.selfMuted'
if effect_source.count(plain_old) != 1:
    raise RuntimeError(f"plain effect gate: expected one match, found {effect_source.count(plain_old)}")
effect_source = effect_source.replace(
    plain_old,
    'this.rawAudioTrack.enabled = this.canTransmitOutgoingAudio()',
    1,
)

processed_old = 'this.processedAudioTrack.enabled = !this.selfMuted'
if effect_source.count(processed_old) != 1:
    raise RuntimeError(f"processed effect gate: expected one match, found {effect_source.count(processed_old)}")
effect_source = effect_source.replace(
    processed_old,
    'this.processedAudioTrack.enabled = this.canTransmitOutgoingAudio()',
    1,
)

live = live[:effect_start] + effect_source + live[effect_end:]

'''
text = text[:effect_plan_start] + effect_plan + text[init_plan_start:]

path.write_text(text)
print("TEAM6_REMEDIATION_HARNESS_PREPARED")
