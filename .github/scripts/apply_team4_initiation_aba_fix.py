from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "priv/static/assets/live_call.mjs"
source = path.read_text()

old_state = """    this.transportAudioTransceiver = null
    this.transportVideoTransceiver = null
    this.activeMediaAcquisitionGeneration = 0
"""
new_state = """    this.transportAudioTransceiver = null
    this.transportVideoTransceiver = null
    this.activeMediaAcquisitionGeneration = 0
    this.initiationOperationGeneration = 0
"""
if source.count(old_state) != 1:
    raise SystemExit(f"initiation generation state anchor count={source.count(old_state)}")
source = source.replace(old_state, new_state, 1)

old_initiate = """    const initiationConversationId = this.conversationId
    return new Promise((resolve, reject) => {
      if (!this.channel) return reject(new Error(\"Channel unavailable\"))
      this.channel.push(\"call:initiate\", { call_type: callType })
        .receive(\"ok\", (res) => {
          const stillCurrent =
            this.status === CALL_STATUS.PENDING_OUTGOING &&
            this.role === \"caller\" &&
            this.callAttemptId === null &&
            this.conversationId === initiationConversationId
          if (!stillCurrent) { resolve({ ...res, stale: true }); return }
          this.callAttemptId = res.call_attempt_id
          this.notifyStateChange()
          resolve(res)
        })
        .receive(\"error\", (err) => {
          if (this.status === CALL_STATUS.PENDING_OUTGOING && this.role === \"caller\" && this.callAttemptId === null && this.conversationId === initiationConversationId) {
            this.teardown(\"initiate_failed\")
          }
          reject(err)
        })
    })
"""
new_initiate = """    const initiationOperationGeneration = ++this.initiationOperationGeneration
    const initiationConversationId = this.conversationId
    const initiationIsCurrent = () =>
      this.initiationOperationGeneration === initiationOperationGeneration &&
      this.status === CALL_STATUS.PENDING_OUTGOING &&
      this.role === \"caller\" &&
      this.callAttemptId === null &&
      this.conversationId === initiationConversationId

    return new Promise((resolve, reject) => {
      if (!this.channel) return reject(new Error(\"Channel unavailable\"))
      this.channel.push(\"call:initiate\", { call_type: callType })
        .receive(\"ok\", (res) => {
          if (!initiationIsCurrent()) { resolve({ ...res, stale: true }); return }
          this.callAttemptId = res.call_attempt_id
          this.notifyStateChange()
          resolve(res)
        })
        .receive(\"error\", (err) => {
          if (initiationIsCurrent()) this.teardown(\"initiate_failed\")
          reject(err)
        })
    })
"""
if source.count(old_initiate) != 1:
    raise SystemExit(f"initiate authority anchor count={source.count(old_initiate)}")
source = source.replace(old_initiate, new_initiate, 1)
path.write_text(source)
