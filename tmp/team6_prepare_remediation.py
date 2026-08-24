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

# Voice Expression must remain fail-closed when WebAudio is unavailable.
# Remove the proposed fallback transformation that would have reopened raw
# audio after the effect path had deliberately disabled it.
fallback_marker = "live = replace_once(\n    live,\n    D('''\n        if (!AudioCtx || !this.rawAudioTrack) {"
fallback_start = text.index(fallback_marker)
fallback_end = text.index('\nlive = replace_once(', fallback_start + len(fallback_marker))
text = (
    text[:fallback_start]
    + '# WebAudio-unavailable effect path stays fail-closed with raw audio disabled.\n'
    + text[fallback_end + 1:]
)

# Switching effect tracks must gate only the track being selected before
# replaceTrack(). An all-track gate here could briefly reopen the old raw sender.
plain_old = "          this.applyOutgoingAudioGate()\n          if (this.peerConnection) {"
plain_new = "          this.rawAudioTrack.enabled = this.canTransmitOutgoingAudio()\n          if (this.peerConnection) {"
if plain_old not in text:
    raise RuntimeError("plain voice-expression proposed gate not found")
text = text.replace(plain_old, plain_new, 1)

processed_old = "        this.applyOutgoingAudioGate()\n        if (this.peerConnection) {"
processed_new = "        this.processedAudioTrack.enabled = this.canTransmitOutgoingAudio()\n        if (this.peerConnection) {"
if processed_old not in text:
    raise RuntimeError("processed voice-expression proposed gate not found")
text = text.replace(processed_old, processed_new, 1)

path.write_text(text)
print("TEAM6_REMEDIATION_HARNESS_PREPARED")
