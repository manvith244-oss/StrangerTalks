import "./instagram_chat.mjs"

export const ATMOSPHERES = Object.freeze([
  Object.freeze({id: "rain-window", label: "Rain Window", description: "Cool glass, soft rainlight, and a sheltered midnight blue."}),
  Object.freeze({id: "late-night-library", label: "Late Night Library", description: "Dark walnut, old paper, and a quiet pool of lamplight."}),
  Object.freeze({id: "train-journey", label: "Train Journey", description: "Deep carriage green with passing bands of evening light."}),
  Object.freeze({id: "coffee-shop", label: "Coffee Shop", description: "Roasted brown, warm cream, and a small corner-table glow."}),
  Object.freeze({id: "night-observatory", label: "Night Observatory", description: "Indigo sky, brass instruments, and distant starlight."})
])

const ATMOSPHERE_BY_ID = new Map(ATMOSPHERES.map((atmosphere) => [atmosphere.id, atmosphere]))

export function approvedAtmosphere(id) {
  return typeof id === "string" ? ATMOSPHERE_BY_ID.get(id) || null : null
}

export function transitionAtmosphere(currentId, requestedId) {
  const current = approvedAtmosphere(currentId)?.id || null
  if (requestedId === null) return {status: current === null ? "no_op" : "reset", atmosphereId: null}
  const requested = approvedAtmosphere(requestedId)
  if (!requested) return {status: "invalid", atmosphereId: current}
  if (requested.id === current) return {status: "no_op", atmosphereId: current}
  return {status: "applied", atmosphereId: requested.id}
}
