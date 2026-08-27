import {
  isActivityOwnedRoute,
  parseRoute,
  resolveActivityEventRoute,
  resolveRequestedRoute,
  routeNavigationPathForScreen
} from "./route_contract.mjs"

const ROUTE_STATE_KEY = "__strangerTalksF02Route"

function currentBrowserRoute() {
  return parseRoute(globalThis.location?.pathname || "/")
}

function safeReplace(path) {
  if (!path || globalThis.location?.pathname === path) return
  globalThis.history.replaceState(globalThis.history.state, "", path)
}

function activateExistingScreen(screen) {
  if (!screen || typeof document === "undefined") return
  const target = document.querySelector(`[data-screen="${CSS.escape(screen)}"]`)
  if (!target) return

  const synthetic = document.createElement("button")
  synthetic.type = "button"
  synthetic.dataset.go = screen
  synthetic.hidden = true
  synthetic.dataset.f02InternalRoute = "true"
  document.body.append(synthetic)
  synthetic.click()
  synthetic.remove()
}

async function activateSavedConversation(route) {
  const {keptConversations, listRecords} = await import("./local_data.mjs")
  const records = await listRecords()
  const kept = keptConversations(records).sort((a, b) => b.updated_at.localeCompare(a.updated_at))
  const index = kept.findIndex((record) => record?.value?.conversation_id === route.params.conversationId)

  if (index < 0) {
    safeReplace("/chats")
    activateExistingScreen("chats")
    const status = document.querySelector("#status")
    if (status) status.textContent = "That saved Conversation is not available on this device."
    return false
  }

  activateExistingScreen("chats")
  await new Promise((resolve) => setTimeout(resolve, 0))
  const buttons = document.querySelectorAll("#kept-chat-list button")
  const button = buttons[index]
  if (!button) {
    safeReplace("/chats")
    activateExistingScreen("chats")
    return false
  }
  button.click()
  return true
}

export function createRouteRuntimeState(pathname) {
  const requested = parseRoute(pathname)
  return {
    requested,
    ready: false,
    snapshot: null,
    preserveActivityAway: requested.valid && !isActivityOwnedRoute(requested),
    lastResolvedPath: requested.path
  }
}

export function refreshResolution(pathname, snapshot) {
  return resolveRequestedRoute(parseRoute(pathname), snapshot)
}

export function installBrowserRouteRuntime(SocketClass) {
  if (typeof window === "undefined" || typeof document === "undefined" || !SocketClass) return null
  if (window[ROUTE_STATE_KEY]) return window[ROUTE_STATE_KEY]

  const state = createRouteRuntimeState(location.pathname)
  window[ROUTE_STATE_KEY] = state

  const accountReturn = new URLSearchParams(location.search).has("account") && location.pathname === "/you"
  if (accountReturn) {
    const nativeReplace = history.replaceState.bind(history)
    history.replaceState = function(historyState, title, url) {
      if (url === "/" && location.pathname === "/you" && new URLSearchParams(location.search).has("account")) {
        return nativeReplace(historyState, title, "/you")
      }
      return nativeReplace(historyState, title, url)
    }
  }

  const setRequestedPath = (path, preserveActivityAway = null) => {
    const route = parseRoute(path)
    if (!route.valid) return null
    state.requested = route
    state.lastResolvedPath = route.path
    state.preserveActivityAway = preserveActivityAway === null
      ? !isActivityOwnedRoute(route)
      : preserveActivityAway
    safeReplace(route.path)
    return route
  }

  const openSavedConversation = async (route) => {
    const opened = await activateSavedConversation(route)
    if (!opened) setRequestedPath("/chats", true)
    return opened
  }

  const applyStaticRequestedRoute = async () => {
    let route = currentBrowserRoute()
    state.requested = route
    if (!route.valid) return

    if (route.needsCanonicalReplace) {
      safeReplace(route.path)
      route = parseRoute(route.path)
      state.requested = route
      state.lastResolvedPath = route.path
    }

    if (route.kind === "chat_detail") {
      await openSavedConversation(route)
      return
    }
    if (["matchmaking", "conversation"].includes(route.kind)) return
    activateExistingScreen(route.screen)
  }

  const applyCanonicalReadiness = async (snapshot) => {
    state.ready = true
    state.snapshot = snapshot || {canonical_state: "IDLE"}
    const requested = state.requested.valid ? state.requested : currentBrowserRoute()
    const resolved = resolveRequestedRoute(requested, state.snapshot)

    if (resolved.replace && resolved.path) {
      setRequestedPath(resolved.path)
    } else {
      state.requested = requested
      state.lastResolvedPath = resolved.path
    }

    if (requested.kind === "chat_detail") {
      await openSavedConversation(requested)
      return
    }

    const effective = state.requested
    if (!isActivityOwnedRoute(effective)) {
      state.preserveActivityAway = true
      activateExistingScreen(effective.screen)
      return
    }

    state.preserveActivityAway = false
    if (["unrecoverable", "doors", "ended"].includes(resolved.screen)) {
      activateExistingScreen(resolved.screen)
    }
  }

  const applyActivityEvent = (event) => {
    const requested = state.requested.valid ? state.requested : currentBrowserRoute()
    const resolved = resolveActivityEventRoute(requested, event)

    if (resolved.replace && resolved.path) {
      setRequestedPath(resolved.path, false)
    }

    return resolved
  }

  const originalSocketChannel = SocketClass.prototype.channel
  SocketClass.prototype.channel = function(topic, params) {
    const channel = originalSocketChannel.call(this, topic, params)

    if (typeof topic === "string" && topic.startsWith("participant:")) {
      const originalJoin = channel.join.bind(channel)
      const originalOn = channel.on.bind(channel)

      channel.join = function(timeout) {
        const push = originalJoin(timeout)
        push.receive("ok", (response) => {
          setTimeout(() => applyCanonicalReadiness(response?.snapshot), 0)
        })
        return push
      }

      channel.on = function(event, callback) {
        if (event === "match_found") {
          return originalOn(event, (payload) => {
            applyActivityEvent("match_found")
            callback(payload)
          })
        }
        if (event === "transition:recovery_failed") {
          return originalOn(event, (payload) => {
            applyActivityEvent("conversation_unavailable")
            callback(payload)
          })
        }
        return originalOn(event, callback)
      }
    }

    if (typeof topic === "string" && topic.startsWith("conversation:")) {
      const originalOn = channel.on.bind(channel)
      channel.on = function(event, callback) {
        if (event === "conversation:ended") {
          return originalOn(event, (payload) => {
            applyActivityEvent("conversation_ended")
            callback(payload)
          })
        }
        return originalOn(event, callback)
      }
    }

    return channel
  }

  document.addEventListener("click", (event) => {
    const go = event.target.closest("[data-go]")
    if (go && go.dataset.f02InternalRoute !== "true") {
      const path = routeNavigationPathForScreen(go.dataset.go)
      if (path) setRequestedPath(path)
    }

    const matchmakingTrigger = event.target.closest("#doors .door, #join-queue")
    if (matchmakingTrigger && document.querySelector('[data-screen="queue"]')?.classList.contains("active")) {
      setRequestedPath("/matchmaking", false)
    }
  })

  const observer = new MutationObserver(() => {
    const active = document.querySelector("section.screen.active")?.dataset.screen
    if (!active) return

    const requested = state.requested
    if (
      state.preserveActivityAway &&
      requested?.valid &&
      !isActivityOwnedRoute(requested) &&
      active !== requested.screen
    ) {
      activateExistingScreen(requested.screen)
      return
    }

    if (active === "match") {
      if (requested?.kind === "matchmaking") applyActivityEvent("match_found")
      return
    }

    if (active === "queue") return

    if (active === "conversation") {
      if (requested?.kind === "matchmaking") applyActivityEvent("match_found")
      return
    }

    if (active === "ended") {
      if (requested?.kind === "conversation") applyActivityEvent("conversation_ended")
      return
    }

    if (active === "unrecoverable") {
      if (requested?.kind === "conversation") applyActivityEvent("conversation_unavailable")
      return
    }

    if (active === "doors" && requested?.kind === "matchmaking") {
      setRequestedPath("/", true)
    }
  })

  document.querySelectorAll("section.screen").forEach((screen) => observer.observe(screen, {attributes: true, attributeFilter: ["class"]}))

  document.addEventListener("DOMContentLoaded", () => {
    applyStaticRequestedRoute().catch(() => {})
  }, {once: true})

  state.applyCanonicalReadiness = applyCanonicalReadiness
  state.applyStaticRequestedRoute = applyStaticRequestedRoute
  return state
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  const {Socket} = await import("/vendor/phoenix.mjs")
  installBrowserRouteRuntime(Socket)
}
