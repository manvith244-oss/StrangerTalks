const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

const STATIC_ROUTES = Object.freeze([
  Object.freeze({path: "/", screen: "doors", kind: "talk"}),
  Object.freeze({path: "/matchmaking", screen: "queue", kind: "matchmaking"}),
  Object.freeze({path: "/conversation", screen: "conversation", kind: "conversation"}),
  Object.freeze({path: "/conversation/ended", screen: "ended", kind: "conversation_ended"}),
  Object.freeze({path: "/conversation/unavailable", screen: "unrecoverable", kind: "conversation_unavailable"}),
  Object.freeze({path: "/chats", screen: "chats", kind: "chats"}),
  Object.freeze({path: "/bonds", screen: "relationships", kind: "bonds"}),
  Object.freeze({path: "/you", screen: "settings", kind: "you"}),
  Object.freeze({path: "/you/memories", screen: "memories", kind: "memories"}),
  Object.freeze({path: "/you/reflections", screen: "reflections", kind: "reflections"})
])

export const CANONICAL_ROUTE_PATTERNS = Object.freeze([
  ...STATIC_ROUTES.map(({path}) => path),
  "/chats/:conversationId"
])

const STATIC_BY_PATH = new Map(STATIC_ROUTES.map((route) => [route.path, route]))

export function normalizePathname(pathname) {
  if (typeof pathname !== "string" || !pathname.startsWith("/")) return {path: null, needsCanonicalReplace: false}
  if (pathname === "/") return {path: "/", needsCanonicalReplace: false}
  const normalized = pathname.endsWith("/") ? pathname.slice(0, -1) : pathname
  return {path: normalized, needsCanonicalReplace: normalized !== pathname}
}

export function parseRoute(pathname) {
  const normalized = normalizePathname(pathname)
  if (!normalized.path) return {valid: false, path: null, params: {}, needsCanonicalReplace: false}

  const staticRoute = STATIC_BY_PATH.get(normalized.path)
  if (staticRoute) {
    return {
      valid: true,
      path: staticRoute.path,
      kind: staticRoute.kind,
      screen: staticRoute.screen,
      params: {},
      needsCanonicalReplace: normalized.needsCanonicalReplace
    }
  }

  const chatMatch = normalized.path.match(/^\/chats\/([^/]+)$/)
  if (chatMatch && UUID_RE.test(chatMatch[1])) {
    const conversationId = chatMatch[1].toLowerCase()
    return {
      valid: true,
      path: `/chats/${conversationId}`,
      kind: "chat_detail",
      screen: "history",
      params: {conversationId},
      needsCanonicalReplace: normalized.needsCanonicalReplace || conversationId !== chatMatch[1]
    }
  }

  return {valid: false, path: normalized.path, params: {}, needsCanonicalReplace: false}
}

export function screenForRoute(route) {
  return route?.valid ? route.screen : null
}

export function routeForScreen(screen) {
  const route = STATIC_ROUTES.find((candidate) => candidate.screen === screen)
  return route?.path || null
}

export function isActivityOwnedRoute(route) {
  return route?.kind === "matchmaking" || route?.kind?.startsWith("conversation")
}

function unchangedRoute(route) {
  return {
    path: route.path,
    screen: route.screen,
    replace: route.needsCanonicalReplace,
    reason: route.needsCanonicalReplace ? "canonical_trailing_slash" : null
  }
}

export function resolveRequestedRoute(route, snapshot) {
  if (!route?.valid) return {path: null, screen: null, replace: false, reason: "invalid_route"}

  const canonicalState = snapshot?.canonical_state || "IDLE"

  if (route.kind === "matchmaking") {
    if (canonicalState === "QUEUED" && snapshot?.queue) {
      return unchangedRoute(route)
    }
    if (canonicalState === "CONVERSATION" && snapshot?.conversation) {
      return {path: "/conversation", screen: "conversation", replace: true, reason: "matchmaking_advanced_to_conversation"}
    }
    return {path: "/", screen: "doors", replace: true, reason: "matchmaking_not_queued"}
  }

  if (route.kind === "conversation") {
    if (canonicalState === "CONVERSATION" && snapshot?.conversation) {
      return unchangedRoute(route)
    }
    return {path: "/conversation/unavailable", screen: "unrecoverable", replace: true, reason: "conversation_not_available"}
  }

  if (["conversation_ended", "conversation_unavailable"].includes(route.kind)) {
    if (canonicalState === "CONVERSATION" && snapshot?.conversation) {
      return {path: "/conversation", screen: "conversation", replace: true, reason: "active_conversation_supersedes_stale_location"}
    }
    if (canonicalState === "AVAILABLE" && snapshot?.terminal_retention_pending === false) {
      return {path: "/", screen: "doors", replace: true, reason: "available_supersedes_resolved_terminal_location"}
    }
  }

  return unchangedRoute(route)
}

export function resolveActivityEventRoute(route, event) {
  if (!route?.valid) return {path: null, screen: null, replace: false, reason: "invalid_route"}

  if (event === "match_found" && route.kind === "matchmaking") {
    return {path: "/conversation", screen: "conversation", replace: true, reason: "match_found_handoff"}
  }

  if (event === "conversation_ended" && route.kind === "conversation") {
    return {path: "/conversation/ended", screen: "ended", replace: true, reason: "conversation_ended"}
  }

  if (event === "conversation_unavailable" && route.kind === "conversation") {
    return {path: "/conversation/unavailable", screen: "unrecoverable", replace: true, reason: "conversation_unavailable"}
  }

  return unchangedRoute(route)
}

export function routeNavigationPathForScreen(screen, conversationId = null) {
  if (screen === "history") {
    return conversationId && UUID_RE.test(conversationId) ? `/chats/${conversationId.toLowerCase()}` : null
  }
  return routeForScreen(screen)
}
