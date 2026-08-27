import {
  isActivityOwnedRoute,
  parseRoute,
  resolveActivityEventRoute,
  resolveRequestedRoute
} from "./route_contract.mjs"

export function requiresCanonicalReadiness(routeOrPath) {
  const route = typeof routeOrPath === "string" ? parseRoute(routeOrPath) : routeOrPath
  return Boolean(route?.valid && isActivityOwnedRoute(route))
}

export function createRouteRuntimeState(pathname) {
  const requestedRoute = parseRoute(pathname)

  return {
    requestedRoute,
    requiresCanonicalReadiness: requiresCanonicalReadiness(requestedRoute),
    preserveActivityAway: Boolean(requestedRoute.valid && !isActivityOwnedRoute(requestedRoute))
  }
}

export function refreshResolution(pathname, canonicalSnapshot) {
  return resolveRequestedRoute(parseRoute(pathname), canonicalSnapshot)
}

export function resolveRuntimeActivityEvent(pathname, eventName) {
  return resolveActivityEventRoute(parseRoute(pathname), eventName)
}
