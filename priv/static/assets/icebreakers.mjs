export const ICEBREAKER_CATALOG = Object.freeze([
  Object.freeze({id: "ocean-or-space", text: "Would you rather explore the ocean or outer space?"}),
  Object.freeze({id: "tiny-smile-story", text: "Tell a tiny story about something that made you smile recently."}),
  Object.freeze({id: "instant-skill", text: "If you could instantly master one harmless skill, what would it be?"}),
  Object.freeze({id: "new-city-afternoon", text: "Imagine you both have a free afternoon in a new city—where do you start?"}),
  Object.freeze({id: "small-comfort", text: "What’s a small comfort you think more people should know about?"}),
  Object.freeze({id: "ordinary-meaning", text: "What’s something ordinary that means more to you than people might guess?"}),
  Object.freeze({id: "conversation-direction", text: "Would you rather keep things light, swap stories, or talk about something meaningful?"})
])

const ICEBREAKER_BY_ID = new Map(ICEBREAKER_CATALOG.map((item) => [item.id, item]))

export function approvedIcebreaker(identity) {
  return typeof identity === "string" ? ICEBREAKER_BY_ID.get(identity) || null : null
}

export function initialIcebreakerState() {
  return {canonicalStatus: "unavailable", identity: null, localDismissed: false}
}

export function applyIcebreakerSnapshot(state, snapshot) {
  const current = state || initialIcebreakerState()

  if (snapshot?.status === "retired") {
    return {canonicalStatus: "retired", identity: null, localDismissed: current.localDismissed}
  }

  const approved = snapshot?.status === "active" ? approvedIcebreaker(snapshot.identity) : null
  if (!approved) {
    return {canonicalStatus: "unavailable", identity: null, localDismissed: current.localDismissed}
  }

  return {canonicalStatus: "active", identity: approved.id, localDismissed: current.localDismissed}
}

export function dismissIcebreaker(state) {
  const current = state || initialIcebreakerState()
  if (current.canonicalStatus !== "active" || current.localDismissed) return current
  return {...current, localDismissed: true}
}

export function resetIcebreakerState() {
  return initialIcebreakerState()
}

export function visibleIcebreaker(state) {
  if (state?.canonicalStatus !== "active" || state.localDismissed) return null
  return approvedIcebreaker(state.identity)
}
