from pathlib import Path

path = Path("tmp/team6_direct_remediate.py")
text = path.read_text()

# 1. Replace the whitespace-sensitive notifyStateChange insertion with a
# function-boundary insertion. This changes only the temporary execution
# harness; production source is still mutated only after the script runs.
start = text.index('if "canTransmitOutgoingAudio()" not in live:')
end = text.index('\nlive = replace_between(', start)
replacement = r'''if "canTransmitOutgoingAudio()" not in live:
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
'''
text = text[:start] + replacement + text[end:]

# 2. Voice Expression must remain fail-closed when WebAudio is unavailable.
# The old proposed harness would have re-opened raw audio in ACTIVE state.
fallback_start = text.index('live = replace_once(\n    live,\n    D(\'\'\'\n        if (!AudioCtx || !this.rawAudioTrack) {')
fallback_end = text.index('\nlive = replace_once(', fallback_start + 10)
text = text[:fallback_start] + '# WebAudio-unavailable effect path already leaves raw audio disabled; preserve that fail-closed behavior.\n' + text[fallback_end + 1:]

# 3. Switching tracks must gate only the track being selected before
# replaceTrack(); do not call the all-track gate while the old sender may still
# reference raw audio.
text = text.replace(
    "          this.applyOutgoingAudioGate()\n          if (this.peerConnection) {",
    "          this.rawAudioTrack.enabled = this.canTransmitOutgoingAudio()\n          if (this.peerConnection) {",
    1,
)
text = text.replace(
    "        this.applyOutgoingAudioGate()\n        if (this.peerConnection) {",
    "        this.processedAudioTrack.enabled = this.canTransmitOutgoingAudio()\n        if (this.peerConnection) {",
    1,
)

path.write_text(text)
print("TEAM6_REMEDIATION_HARNESS_PREPARED")
