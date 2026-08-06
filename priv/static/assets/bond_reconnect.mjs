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
