export function reconnectDisplayState(result, relationshipId, now = Date.now()) {
  if (result?.status === "waiting_for_mutual_availability" && Date.parse(result.expires_at) > now) {
    return {relationship_id: relationshipId, status: result.status, door_type: result.door_type, expires_at: result.expires_at}
  }
  if (result?.status === "matched") return {relationship_id: relationshipId, status: "matched", conversation_id: result.conversation_id}
  return {relationship_id: relationshipId, status: "idle"}
}

export function reconnectStateRecord(state, updatedAt) {
  return {id: `bond-reconnect:${state.relationship_id}`, type: "bond_reconnect_state", value: state, updated_at: updatedAt}
}

export function remainingAvailabilitySeconds(expiresAt, now = Date.now()) {
  return Math.max(0, Math.ceil((Date.parse(expiresAt) - now) / 1000))
}

export function matchedConversationId(payload) {
  return payload?.status === "matched" && typeof payload.conversation_id === "string" && payload.conversation_id
    ? payload.conversation_id
    : null
}

export function unavailableReconnectState(relationshipId) {
  return {relationship_id: relationshipId, status: "unavailable"}
}

export function createMatchedTransitionTracker() {
  let current = null
  return {
    claim(payload) {
      const conversationId = matchedConversationId(payload)
      if (!conversationId || current === conversationId) return null
      current = conversationId
      return conversationId
    },
    release(conversationId) { if (current === conversationId) current = null },
    current() { return current }
  }
}

export function createReconnectCountdownController(startInterval = setInterval, stopInterval = clearInterval) {
  let timer = null
  return {
    start(callback) {
      if (timer !== null) stopInterval(timer)
      timer = startInterval(callback, 1_000)
      return timer
    },
    stop() {
      if (timer !== null) stopInterval(timer)
      timer = null
    },
    active() { return timer !== null }
  }
}
