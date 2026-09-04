import {parseRoute} from "./route_contract.mjs"
import {
  createRouteRuntimeState,
  refreshResolution,
  resolveRuntimeActivityEvent
} from "./route_runtime.mjs"

export const NAVIGATION_STATE_KEY = "__strangertalks_navigation_v1"

export function createNavigationRevision() {
  let revision = 0

  return {
    begin: () => ++revision,
    capture: () => revision,
    current: (capturedRevision) => capturedRevision === revision
  }
}

export function primaryDestinationForPath(pathname) {
  const route = parseRoute(pathname)
  if (!route.valid) return null

  switch (route.kind) {
    case "talk":
      return "talk"
    case "chats":
    case "chat_detail":
      return "chats"
    case "bonds":
      return "bonds"
    case "you":
    case "memories":
    case "reflections":
      return "you"
    default:
      return null
  }
}

export function deepLinkParentPath(pathname) {
  const route = parseRoute(pathname)
  if (!route.valid) return null

  switch (route.kind) {
    case "chat_detail":
      return "/chats"
    case "memories":
    case "reflections":
      return "/you"
    default:
      return null
  }
}

function navigationState(path, priorState = null) {
  return {
    ...(priorState && typeof priorState === "object" ? priorState : {}),
    [NAVIGATION_STATE_KEY]: true,
    path
  }
}

function isNavigationState(state) {
  return Boolean(state && typeof state === "object" && state[NAVIGATION_STATE_KEY] === true)
}

function terminalRetentionPending(records) {
  return records.some((record) => (
    record?.type === "local_conversation" &&
    record?.value?.status === "temporary" &&
    record?.value?.connection_state === "ended"
  ))
}

async function withTerminalRetentionOwnership(route, snapshot) {
  if (
    !["conversation_ended", "conversation_unavailable"].includes(route?.kind) ||
    snapshot?.canonical_state !== "AVAILABLE"
  ) {
    return snapshot
  }

  try {
    const {listRecords} = await import("./local_data.mjs")
    const records = await listRecords()
    return {...snapshot, terminal_retention_pending: terminalRetentionPending(records)}
  } catch {
    // Local ownership is unknown, so preserve terminal presentation rather than
    // guessing that retention/recovery has completed.
    return snapshot
  }
}

export function createNavigationHistory({history, location, getCanonicalSnapshot, applyRoute}) {
  if (!history || typeof history.pushState !== "function" || typeof history.replaceState !== "function") {
    throw new TypeError("history with pushState/replaceState is required")
  }
  if (!location || typeof location.pathname !== "string") {
    throw new TypeError("location.pathname is required")
  }
  if (typeof getCanonicalSnapshot !== "function") {
    throw new TypeError("getCanonicalSnapshot is required")
  }
  if (typeof applyRoute !== "function") {
    throw new TypeError("applyRoute is required")
  }

  const revision = createNavigationRevision()

  async function decisionFor(pathname, suppliedSnapshot) {
    const runtimeState = createRouteRuntimeState(pathname)
    if (!runtimeState.requestedRoute.valid) {
      return refreshResolution(pathname, suppliedSnapshot ?? null)
    }

    let snapshot = suppliedSnapshot
    if (runtimeState.requiresCanonicalReadiness && snapshot === undefined) {
      snapshot = await getCanonicalSnapshot()
    }
    snapshot = await withTerminalRetentionOwnership(runtimeState.requestedRoute, snapshot)

    return refreshResolution(pathname, snapshot ?? null)
  }

  function applyDecision(decision, requestedMode) {
    if (!decision?.path || !decision?.screen) {
      return {applied: false, stale: false, invalid: true, decision, historyMode: "none"}
    }

    const current = parseRoute(location.pathname)
    const sameCanonicalPath = current.valid && current.path === decision.path && !current.needsCanonicalReplace
    let historyMode = requestedMode

    if (decision.replace) historyMode = "replace"
    if (historyMode === "push" && sameCanonicalPath) historyMode = "none"

    const state = navigationState(decision.path, history.state)
    if (historyMode === "push") {
      history.pushState(state, "", decision.path)
    } else if (historyMode === "replace") {
      history.replaceState(state, "", decision.path)
    }

    const appliedDecision = {
      ...decision,
      primaryDestination: primaryDestinationForPath(decision.path)
    }
    applyRoute(appliedDecision)

    return {applied: true, stale: false, invalid: false, decision: appliedDecision, historyMode}
  }

  async function resolveIntent(pathname, requestedMode, {snapshot} = {}) {
    const intentRevision = revision.begin()
    const decision = await decisionFor(pathname, snapshot)

    if (!revision.current(intentRevision)) {
      return {applied: false, stale: true, invalid: false, decision, historyMode: "none"}
    }

    return applyDecision(decision, requestedMode)
  }

  async function initialize({snapshot} = {}) {
    const intentRevision = revision.begin()
    const requestedPath = location.pathname
    const decision = await decisionFor(requestedPath, snapshot)

    if (!revision.current(intentRevision)) {
      return {applied: false, stale: true, invalid: false, decision, historyMode: "none"}
    }
    if (!decision?.path || !decision?.screen) {
      return {applied: false, stale: false, invalid: true, decision, historyMode: "none"}
    }

    const parentPath = deepLinkParentPath(decision.path)
    if (parentPath && !isNavigationState(history.state)) {
      history.replaceState(navigationState(parentPath), "", parentPath)
      history.pushState(navigationState(decision.path), "", decision.path)
    } else {
      history.replaceState(navigationState(decision.path, history.state), "", decision.path)
    }

    const appliedDecision = {
      ...decision,
      primaryDestination: primaryDestinationForPath(decision.path)
    }
    applyRoute(appliedDecision)

    return {
      applied: true,
      stale: false,
      invalid: false,
      decision: appliedDecision,
      historyMode: decision.replace ? "replace" : "initialize"
    }
  }

  async function navigate(pathname, options = {}) {
    return resolveIntent(pathname, "push", options)
  }

  async function replace(pathname, options = {}) {
    return resolveIntent(pathname, "replace", options)
  }

  async function popstate(options = {}) {
    return resolveIntent(location.pathname, "none", options)
  }

  async function reconcile(snapshot) {
    return resolveIntent(location.pathname, "none", {snapshot})
  }

  async function activityEvent(eventName) {
    const intentRevision = revision.begin()
    const presentedRoute = parseRoute(location.pathname)
    let decision = resolveRuntimeActivityEvent(location.pathname, eventName)

    const terminalPath = eventName === "conversation_ended"
      ? "/conversation/ended"
      : eventName === "conversation_unavailable"
        ? "/conversation/unavailable"
        : null

    if (
      terminalPath &&
      presentedRoute.valid &&
      presentedRoute.path !== terminalPath &&
      decision?.path === presentedRoute.path
    ) {
      const snapshot = await getCanonicalSnapshot()

      if (!revision.current(intentRevision)) {
        return {applied: false, stale: true, invalid: false, decision, historyMode: "none"}
      }

      if (snapshot && snapshot.canonical_state !== "CONVERSATION") {
        decision = refreshResolution(terminalPath, snapshot)
      }
    }

    if (!revision.current(intentRevision)) {
      return {applied: false, stale: true, invalid: false, decision, historyMode: "none"}
    }

    const result = applyDecision(decision, "none")
    if (eventName === "conversation_ended" && result.applied) {
      globalThis.document?.querySelector?.("#consent")?.focus()
    }
    return result
  }

  return {
    initialize,
    navigate,
    replace,
    popstate,
    reconcile,
    activityEvent,
    captureRevision: revision.capture,
    revisionCurrent: revision.current
  }
}