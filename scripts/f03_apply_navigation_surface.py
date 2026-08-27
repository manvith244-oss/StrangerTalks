from pathlib import Path

path = Path("priv/static/assets/app.js")
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    source = source.replace(old, new, 1)


replace_once(
    'import {applyReconciliationIfCurrent, createSessionReconciliationGuard} from "./session_reconciliation_guard.mjs"\n',
    'import {applyReconciliationIfCurrent, createSessionReconciliationGuard} from "./session_reconciliation_guard.mjs"\n'
    'import {parseRoute, routeNavigationPathForScreen} from "./route_contract.mjs"\n'
    'import {createRouteRuntimeState} from "./route_runtime.mjs"\n'
    'import {createNavigationHistory} from "./navigation_history.mjs"\n',
    "F-03 imports",
)

old_show = '''function announce(message) { $("#status").textContent = message }
function show(name) {
  closeDisclosureDialog({restoreFocus: false})
  if (name !== "relationships") app.reconnectCountdown.stop()
  if (name !== "conversation") cancelReplyStaging()
  document.querySelectorAll("[data-screen]").forEach((node) => node.classList.toggle("active", node.dataset.screen === name))
  $("#expressive-composer").hidden = name !== "conversation"
  if (name !== "conversation") closeExpressivePicker(false)
  $("#bottom-nav").hidden = !["doors", "chats", "relationships", "settings"].includes(name)
  if (name === "chats") renderChats()
  if (name === "relationships") renderLocalViews()
  if (name === "reflections") loadAndRenderReflections()
}
'''

new_show = '''function announce(message) { $("#status").textContent = message }

function presentScreen(name) {
  document.querySelectorAll("[data-screen]").forEach((node) => node.classList.toggle("active", node.dataset.screen === name))
  $("#expressive-composer").hidden = name !== "conversation"
  if (name !== "conversation") closeExpressivePicker(false)
  if (name === "chats") renderChats()
  if (name === "relationships") renderLocalViews()
  if (name === "reflections") loadAndRenderReflections()
}

function updatePrimaryNavigation(primaryDestination) {
  const destinationByScreen = {doors: "talk", chats: "chats", relationships: "bonds", settings: "you"}
  document.querySelectorAll("#bottom-nav [data-go]").forEach((button) => {
    const selected = destinationByScreen[button.dataset.go] === primaryDestination
    if (selected) button.setAttribute("aria-current", "page")
    else button.removeAttribute("aria-current")
  })
}

function presentRoute(decision) {
  const route = parseRoute(decision.path)
  updatePrimaryNavigation(decision.primaryDestination)

  if (decision.screen === "history" && route.valid && route.params?.conversationId) {
    renderHistory(route.params.conversationId).catch(() => announce("This saved Conversation is not available on this device."))
    return
  }

  presentScreen(decision.screen)
}

async function readCanonicalNavigationSnapshot() {
  if (!app.participantJoined || !app.participant) return null
  const response = await push(app.participant, "session:reconcile")
  return response?.snapshot || null
}

let navigationInitialized = false
const navigation = createNavigationHistory({
  history,
  location,
  getCanonicalSnapshot: readCanonicalNavigationSnapshot,
  applyRoute: presentRoute
})

async function initializeOrReconcileNavigation(snapshot) {
  if (!navigationInitialized) {
    navigationInitialized = true
    return navigation.initialize({snapshot})
  }
  return navigation.reconcile(snapshot)
}

async function navigateToScreen(name, conversationId = null) {
  const path = routeNavigationPathForScreen(name, conversationId)
  if (!path) return {applied: false, invalid: true}
  return navigation.navigate(path)
}

function show(name) {
  closeDisclosureDialog({restoreFocus: false})
  if (name !== "relationships") app.reconnectCountdown.stop()
  if (name !== "conversation") cancelReplyStaging()
  presentScreen(name)
  $("#bottom-nav").hidden = !["doors", "chats", "relationships", "settings"].includes(name)
}
'''
replace_once(old_show, new_show, "split legacy show from route presentation")

replace_once(
    '''  app.participant.join().receive("ok", async (response) => {
    app.participantJoined = true
    await reconcileWithServer(response?.snapshot)
    if (document.querySelector('[data-screen="relationships"]')?.classList.contains("active")) renderLocalViews()
  }).receive("error", (error) => {
''',
    '''  app.participant.join().receive("ok", async (response) => {
    app.participantJoined = true
    await reconcileWithServer(response?.snapshot)
    await initializeOrReconcileNavigation(response?.snapshot)
    if (document.querySelector('[data-screen="relationships"]')?.classList.contains("active")) renderLocalViews()
  }).receive("error", (error) => {
''',
    "participant join navigation initialization",
)

replace_once(
    'document.addEventListener("click", (event) => { const target = event.target.closest("[data-go]"); if (target) show(target.dataset.go) })\n',
    'document.addEventListener("click", (event) => { const target = event.target.closest("[data-go]"); if (target) navigateToScreen(target.dataset.go).catch(() => announce("Navigation could not be completed.")) })\n'
    'window.addEventListener("popstate", () => { navigation.popstate().catch(() => announce("Navigation could not be restored.")) })\n',
    "data-go and popstate integration",
)

replace_once(
    'async function openHistory(conversationId) {\n',
    'async function renderHistory(conversationId) {\n',
    "rename history renderer",
)
replace_once(
    '''  show("history")
  scrollHistoryToNewest()
}

function releaseVoiceUrl(voiceNoteId) {
''',
    '''  presentScreen("history")
  scrollHistoryToNewest()
}

async function openHistory(conversationId) {
  return navigateToScreen("history", conversationId)
}

function releaseVoiceUrl(voiceNoteId) {
''',
    "history navigation wrapper",
)

replace_once(
    'initializeLifetimePresentation()\n\nDOORS.forEach',
    'initializeLifetimePresentation()\n\n'
    'const initialNavigationRuntimeState = createRouteRuntimeState(location.pathname)\n'
    'if (!initialNavigationRuntimeState.requiresCanonicalReadiness) {\n'
    '  initializeOrReconcileNavigation(null).catch(() => announce("Navigation could not be initialized."))\n'
    '}\n\n'
    'DOORS.forEach',
    "non-activity direct-entry initialization",
)

replace_once(
    'if (accountResult) history.replaceState({}, "", "/")',
    'if (accountResult) history.replaceState(history.state, "", location.pathname)',
    "OAuth URL cleanup preserves canonical route",
)

path.write_text(source)
print("F-03 navigation surface patch applied")
