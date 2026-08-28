import {Socket} from "/vendor/phoenix.mjs"
import {CONVERSATION_LANGUAGES, DOORS, doorLabelForBackend, queuePayloadFor} from "./door_mapping.mjs"
import {
  activeConversations, chooseConversationRetention, clearRecords, conversationSyncCursor, decryptBackup,
  deleteAllKeptConversations, deleteKeptConversation, deleteRecord, encryptBackup,
  getRecord, importRecords, keptConversations, listRecords, localMessage, mergeMessageContent, putRecord,
  localVoiceNote, mergeReactionRecord, normalizeReactionSlot, replaceRecords, sanitizeMessageReference,
  temporaryConversation
} from "./local_data.mjs"
import {
  MAX_VOICE_BYTES, MAX_VOICE_DURATION_MS, VOICE_WARNING_VERSION, baseMediaType,
  chronologicalTimeline, formatVoiceTime, nextPlaybackRate, selectVoiceMediaType, stopMediaTracks, validVoiceBlob,
  voiceDraftMatchesRuntime, voiceCaptureStillAuthorized,
  warningAcknowledged
} from "./voice_notes.mjs"
import {createMatchedTransitionTracker, createReconnectCountdownController, reconnectDisplayState, reconnectStateRecord, remainingAvailabilitySeconds, unavailableReconnectState} from "./bond_reconnect.mjs"
import {decryptSyncWithKey, encryptSyncBundle, encryptSyncWithKey, loadSyncKey, mergeSyncRecords, storeSyncKey, supportsPersistentCryptoKey, syncableRecords, tombstoneFor, unlockSync} from "./encrypted_sync.mjs"
import {applyCanonicalSequence, createDeliveryProgress} from "./delivery_progress.mjs"
import {ATMOSPHERES, approvedAtmosphere, transitionAtmosphere} from "./atmospheres.mjs"
import {
  approvedPrompt, initialPromptCardState, insertPromptDraft, promptsForCategory, transitionPromptCards
} from "./prompt_cards.mjs"
import {
  applyIcebreakerSnapshot, dismissIcebreaker, initialIcebreakerState, resetIcebreakerState, visibleIcebreaker
} from "./icebreakers.mjs"
import {AmbientAudioController} from "./ambient_audio.mjs"
import {
  MAX_PHOTO_BYTES, MAX_PHOTO_DIMENSION, isApprovedPhotoType, validPhotoBlob, viewOnceDraftMatchesRuntime
} from "./view_once.mjs"
import {
  CALL_STATUS,
  LiveCallCoordinator,
  StrangerTalksRing,
  REACTION_WHITELIST,
  REACTION_LABELS,
  REACTION_EMOJIS,
  attachMediaStream,
  stopMediaTracks as stopLiveCallMediaTracks
} from "./live_call.mjs"
import {ReflectionManager} from "./reflections.mjs"
import {applyReconciliationIfCurrent, createSessionReconciliationGuard} from "./session_reconciliation_guard.mjs"
import {parseRoute, routeNavigationPathForScreen} from "./route_contract.mjs"
import {createRouteRuntimeState} from "./route_runtime.mjs"
import {createNavigationHistory} from "./navigation_history.mjs"

const identityKey = "strangertalks.identity.v1"
const conversationLanguageKey = "strangertalks.conversation-language.v1"
const SOCKET_RECONNECT_BASE_MS = [250, 500, 1000, 2000, 5000]
const SOCKET_RECONNECT_CAP_MS = 10000
const CHANNEL_REJOIN_BASE_MS = [1000, 2000, 5000]
const CHANNEL_REJOIN_CAP_MS = 10000
const SWIPE_REPLY_THRESHOLD_PX = 48
const LONG_PRESS_MS = 450

const EXPRESSIVE_CATALOG = Object.freeze([
  {id: "warm-wave", kind: "sticker", category: "friendly", label: "A friendly wave", asset_path: "/assets/expressive/warm-wave.svg"},
  {id: "bright-spark", kind: "sticker", category: "celebrate", label: "A bright spark", asset_path: "/assets/expressive/bright-spark.svg"},
  {id: "happy-bounce", kind: "loop", category: "happy", label: "A happy bouncing face", asset_path: "/assets/expressive/happy-bounce.svg"},
  {id: "calm-breathe", kind: "loop", category: "calm", label: "A calm breathing glow", asset_path: "/assets/expressive/calm-breathe.svg"}
])

const DEFAULT_QUICK_EMOJIS = Object.freeze(["❤️", "😂", "😭", "👍️", "👀", "🫂"])

const app = {
  identity: null,
  socket: null,
  participant: null,
  participantJoined: false,
  reflections: null,
  conversation: null,
  conversationId: null,
  currentEpochId: null,
  selectedDoor: null,
  conversationLanguage: localStorage.getItem(conversationLanguageKey),
  queueAttemptId: null,
  sessionReconciliationGuard: createSessionReconciliationGuard(),
  rendered: new Set(),
  typingTimer: null,
  historyConversationId: null,
  timelinePinned: true,
  replyState: null,
  replySelectionGeneration: 0,
  reactionInFlight: new Map(),
  reactionAuthority: new Map(),
  activeReactionPickerTarget: null,
  account: {available: false, connected: false, revision: 0, passphrase: null, syncKey: null, envelope: null},
  matchedTransition: createMatchedTransitionTracker(),
  reconnectCountdown: createReconnectCountdownController(),
  voice: {mediaType: null, recorder: null, stream: null, chunks: [], startedAt: 0, timer: null, stopTimer: null, activityFrame: null, discard: false, blob: null, objectUrl: null, voiceNoteId: null, durationMs: 0, originConversationId: null, originEpochId: null, captureRequestId: 0},
  voiceUrls: new Map(),
  pinnedMessages: {conversationId: null, epochId: null, items: [], revision: 0},
  pinMutationInFlight: false,
  pinReconcileInFlight: false,
  localConnectionState: "connected",
  peerPresence: null,
  quietMode: false,
  atmosphereId: null,
  promptCards: initialPromptCardState(),
  icebreaker: initialIcebreakerState(),
  activeDisclosureDialog: null,
  disclosureReturnFocus: null,
  ambient: null,
  activeVoicePlayback: new Set(),
  deliveryProgress: {epochId: null, baseline: 1, contiguous: 0, applied: new Set(), inFlight: false, desired: 0, confirmed: 0, retryFor: null, reconciling: false},
  avatars: null,
  messageEdit: null,
  messageUnsend: null,
  messageContentReconcileInFlight: false,
  messageRecordUpdates: new Map(),
  messageAvailability: new Map(),
  reportTargetMessageId: null,
  reportReturnFocus: null,
  liveCall: null
}
const $ = (selector) => document.querySelector(selector)
const now = () => new Date().toISOString()

function bindQueueAttempt(queueAttemptId) {
  if (app.queueAttemptId === queueAttemptId) return
  app.queueAttemptId = queueAttemptId
  app.sessionReconciliationGuard.transition()
}

function markConversationAuthorityTransition() {
  app.sessionReconciliationGuard.transition()
}

function accountFetch(path, options = {}) {
  const headers = {...(options.headers || {})}
  if (options.method && !["GET", "HEAD"].includes(options.method)) headers["X-StrangerTalks-CSRF"] = app.account.csrf_token
  return fetch(path, {...options, credentials: "same-origin", headers})
}

function announce(message) { $("#status").textContent = message }

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
  $("#bottom-nav").hidden = !["doors", "chats", "relationships", "settings", "conversation"].includes(name)
}

function disclosureFocusables(dialog) {
  return Array.from(dialog.querySelectorAll('button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'))
    .filter((node) => !node.hidden)
}

function openDisclosureDialog(backdrop, trigger, initialFocus) {
  closeDisclosureDialog({restoreFocus: false})
  app.activeDisclosureDialog = backdrop
  app.disclosureReturnFocus = trigger
  backdrop.hidden = false
  trigger?.setAttribute("aria-expanded", "true")
  requestAnimationFrame(() => (initialFocus || disclosureFocusables(backdrop)[0])?.focus())
}

function closeDisclosureDialog({restoreFocus = true} = {}) {
  const backdrop = app.activeDisclosureDialog
  if (!backdrop) return
  backdrop.hidden = true
  document.querySelectorAll(`[aria-controls="${backdrop.querySelector('[role="dialog"]')?.id}"]`).forEach((trigger) => trigger.setAttribute("aria-expanded", "false"))
  const returnFocus = app.disclosureReturnFocus
  app.activeDisclosureDialog = null
  app.disclosureReturnFocus = null
  if (restoreFocus) returnFocus?.focus()
}

function handleDisclosureDialogKeydown(event) {
  const backdrop = event.currentTarget
  if (event.key === "Escape") {
    event.preventDefault()
    closeDisclosureDialog()
    return
  }
  if (event.key !== "Tab") return
  const focusables = disclosureFocusables(backdrop)
  if (!focusables.length) return
  const first = focusables[0]
  const last = focusables[focusables.length - 1]
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault()
    last.focus()
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault()
    first.focus()
  }
}

function initializeLifetimePresentation() {
  const presenceSupport = document.createElement("p")
  presenceSupport.id = "presence-support"
  presenceSupport.className = "presence-support"
  presenceSupport.hidden = true
  presenceSupport.textContent = "Your Conversation may still recover."
  $("#presence").after(presenceSupport)

  const lifetimeReportSection = $("#lifetime-reports-title")?.closest("section")
  if (lifetimeReportSection) {
    const unsentSafetyDisclosure = document.createElement("p")
    unsentSafetyDisclosure.textContent = "An unsent text message may be kept temporarily inside the active Conversation for safety reporting. If that unsent message is reported while the safety copy is still available, the specific message text may be stored with the report."
    lifetimeReportSection.querySelector("p")?.after(unsentSafetyDisclosure)
  }

  const reportForm = $("#report-form")
  reportForm.classList.add("report-form")
  reportForm.querySelector("h2")?.remove()
  reportForm.querySelector(":scope > p")?.remove()
  reportForm.insertAdjacentHTML("afterbegin", '<div class="report-disclosure"><h2>About this report</h2><p>Reports are stored separately for safety and can remain after this Conversation ends.</p><p>An unsent text message may be kept temporarily inside the active Conversation for safety reporting. If that unsent message is reported while the safety copy is still available, the specific message text may be stored with the report.</p><p>Submitting this report does not automatically save the ordinary Conversation transcript, Reply structure, GIF or sticker choice, voice-note identity or audio, or surrounding chat history into the report.</p><p>Stored report and safety-review records currently have no automatic expiry or cleanup.</p><p id="report-target-disclosure" role="status" hidden></p></div>')
  reportForm.querySelector("h2").tabIndex = -1
  const reportSubmit = reportForm.querySelector('button[type="submit"], button:not([type])')
  reportSubmit.textContent = "Submit Report"
  const reportCancel = document.createElement("button")
  reportCancel.id = "report-cancel"
  reportCancel.type = "button"
  reportCancel.textContent = "Cancel"
  const reportActions = document.createElement("div")
  reportActions.className = "report-actions"
  reportSubmit.before(reportActions)
  reportActions.append(reportSubmit, reportCancel)
}
function push(channel, event, payload = {}) { return new Promise((resolve, reject) => channel.push(event, payload).receive("ok", resolve).receive("error", reject).receive("timeout", () => reject({reason: "timeout"}))) }

// Math.random() is used only to disperse retry timing, never for identity or security values.
function proportionalJitter(baseDelay, cap) {
  const boundedBase = Math.min(baseDelay, cap)
  const minimum = Math.ceil(boundedBase / 2)
  return minimum + Math.floor(Math.random() * (boundedBase - minimum + 1))
}

function socketReconnectAfterMs(tries) {
  const baseDelay = SOCKET_RECONNECT_BASE_MS[tries - 1] || SOCKET_RECONNECT_CAP_MS
  return proportionalJitter(baseDelay, SOCKET_RECONNECT_CAP_MS)
}

function channelRejoinAfterMs(tries) {
  const baseDelay = CHANNEL_REJOIN_BASE_MS[tries - 1] || CHANNEL_REJOIN_CAP_MS
  return proportionalJitter(baseDelay, CHANNEL_REJOIN_CAP_MS)
}

let bootstrapPromise = null

function ensureBootstrap() {
  if (!bootstrapPromise) bootstrapPromise = bootstrap()
  return bootstrapPromise
}

async function bootstrap() {
  const saved = await getRecord(identityKey)


  const account = await fetch("/api/account/session", {credentials: "same-origin"}).then((response) => response.json()).catch(() => ({available: false, connected: false}))
  app.account = {...app.account, ...account}
  if (account.connected && await supportsPersistentCryptoKey().catch(() => false)) app.account.syncKey = await loadSyncKey(account.continuity_id).catch(() => null)
  if (account.connected) {
    const retained = syncableRecords(await listRecords())
    const useConnected = !saved || saved.value.participant_id === account.participant_id || !retained.length || confirm("Use your privately connected participant on this device? Existing kept local data will remain here until you choose Restore or Sync. Choose Cancel to stay with this guest.")
    if (useConnected) {
      app.identity = {participant_id: account.participant_id, token: account.participant_token}
      await putRecord({id: identityKey, type: "identity", value: app.identity, updated_at: now()})
    } else {
      await accountFetch("/api/account/session", {method: "DELETE"})
      app.account.connected = false
    }
  }
  if (!app.identity && saved) app.identity = saved.value
  if (!app.identity) await createIdentity(false)
  await renderAccountState()
  connectSocket()
}

async function createIdentity(replacing) {
  if (replacing) announce("Your previous anonymous identity is unavailable. Creating a new one.")
  const response = await fetch("/api/participants", {method: "POST", headers: {"content-type": "application/json"}, body: "{}"})
  if (!response.ok) throw new Error("participant bootstrap failed")
  app.identity = await response.json()
  await putRecord({id: identityKey, type: "identity", value: app.identity, updated_at: now()})
}

function connectSocket() {
  if (!app.identity?.token) return
  if (app.socket) {
    if (app.socket.isConnected()) return
    app.socket.disconnect()
  }
  app.socket = new Socket("/socket", {
    authToken: () => app.identity?.token,
    reconnectAfterMs: socketReconnectAfterMs,
    rejoinAfterMs: channelRejoinAfterMs
  })
  app.socket.onError(() => { updateLocalConnection("reconnecting"); announce("Connection interrupted. Reconnecting.") })
  app.socket.onClose(() => { if (app.conversationId) { updateLocalConnection("recovery") } })
  app.socket.connect()
  app.participant = app.socket.channel(`participant:${app.identity.participant_id}`, {})
  app.participant.on("queue:status", ({status, queue_attempt_id}) => {
    if (status === "queued" && queue_attempt_id) bindQueueAttempt(queue_attempt_id)
    if (["left", "timed_out"].includes(status) && queue_attempt_id !== app.queueAttemptId) return
    announce(`Queue status: ${status}`)
    if (["left", "timed_out"].includes(status)) {
      bindQueueAttempt(null)
      show("doors")
    }
    if (status === "queued" && queue_attempt_id) {
      const currentRoute = parseRoute(location.pathname)
      if (currentRoute.valid && currentRoute.kind === "talk") {
        navigation.navigate("/matchmaking", {
          snapshot: {canonical_state: "QUEUED", queue: {queue_attempt_id}}
        }).catch(() => announce("Matchmaking navigation could not be applied."))
      } else if (currentRoute.valid && currentRoute.kind === "matchmaking") {
        presentScreen("queue")
      }
    }
  })
  app.participant.on("match_found", (payload) => {
    navigation.activityEvent("match_found").catch(() => announce("Conversation navigation could not be applied."))
    handleMatchedConversation(payload).catch(() => announce("Reconnecting to the Conversation…"))
  })
  app.participant.on("transition:recovery_failed", () => {
    announce("That Conversation ended before it opened. Returning to Doors.")
    resumeLocalConversation().catch(() => show("doors"))
  })
  app.participant.on("relationship:created", ({relationship_id}) => { rememberRelationship(relationship_id); $("#consent-status").textContent = "Bond created."; announce("Mutual Bond created.") })
  app.participant.on("reflection:changed", () => { if (document.querySelector('[data-screen="reflections"]')?.classList.contains("active")) loadAndRenderReflections() })
  app.participant.on("reflection:deleted", () => { if (document.querySelector('[data-screen="reflections"]')?.classList.contains("active")) loadAndRenderReflections() })
  app.participant.on("reflection:excerpt_removed", () => { if (document.querySelector('[data-screen="reflections"]')?.classList.contains("active")) loadAndRenderReflections() })
  app.participant.join().receive("ok", async (response) => {
    app.participantJoined = true
    await reconcileWithServer(response?.snapshot)
    await initializeOrReconcileNavigation(response?.snapshot)
    if (document.querySelector('[data-screen="relationships"]')?.classList.contains("active")) renderLocalViews()
  }).receive("error", (error) => {
    handleDomainError(error, {fallbackMessage: "Could not restore session. Please try again.", fallbackScreen: "doors"})
  })
}

async function reconcileWithServer(snapshot, expectedRevision = null) {
  if (expectedRevision !== null && !app.sessionReconciliationGuard.current(expectedRevision)) return
  if (!snapshot) {
    await resumeLocalConversation()
    return
  }

  if (snapshot.canonical_state === "CONVERSATION" && snapshot.conversation) {
    bindQueueAttempt(null)
    const id = snapshot.conversation.conversation_id
    app.selectedDoor = doorLabelForBackend(snapshot.conversation.door_type) || DOORS[0].label
    app.conversationLanguage = snapshot.conversation.conversation_language
    if (app.conversationLanguage) localStorage.setItem(conversationLanguageKey, app.conversationLanguage)
    if ($("#conversation-language")) $("#conversation-language").value = app.conversationLanguage || ""
    updateDoorLabels()
    await handleMatchedConversation({status: "matched", conversation_id: id})
  } else if (snapshot.canonical_state === "QUEUED" && snapshot.queue) {
    if (app.conversation || app.conversationId) releaseConversationRuntime()
    bindQueueAttempt(snapshot.queue.queue_attempt_id)
    app.selectedDoor = doorLabelForBackend(snapshot.queue.door_type) || DOORS[0].label
    app.conversationLanguage = snapshot.queue.conversation_language
    if (app.conversationLanguage) localStorage.setItem(conversationLanguageKey, app.conversationLanguage)
    if ($("#conversation-language")) $("#conversation-language").value = app.conversationLanguage || ""
    updateDoorLabels()
    announce(`Looking for someone who chose ${app.selectedDoor} too.`)
    show("queue")
  } else {
    if (app.conversation || app.conversationId) releaseConversationRuntime()
    bindQueueAttempt(null)
    const appliedRevision = app.sessionReconciliationGuard.capture()
    await invalidateStaleActiveConversations()
    if (expectedRevision !== null && !app.sessionReconciliationGuard.current(appliedRevision)) return
    const activeNode = document.querySelector('section.screen.active')
    if (!activeNode || ["match", "queue", "conversation"].includes(activeNode.dataset.screen)) {
      show("doors")
    }
  }
}

async function invalidateStaleActiveConversations() {
  const records = await listRecords()
  const active = activeConversations(records)
  for (const record of active) {
    await putRecord({
      ...record,
      value: {...record.value, status: "ended", connection_state: "ended"},
      updated_at: now()
    })
  }
}

async function resumeLocalConversation() {
  if (app.participantJoined && app.participant) {
    try {
      const requestRevision = app.sessionReconciliationGuard.capture()
      const response = await push(app.participant, "session:reconcile")
      if (response?.snapshot) {
        let reconciliation
        const applied = applyReconciliationIfCurrent(
          app.sessionReconciliationGuard,
          requestRevision,
          () => { reconciliation = reconcileWithServer(response.snapshot, requestRevision) }
        )
        if (applied) return reconciliation
        return
      }
    } catch (e) {
      console.warn("session:reconcile error:", e)
      handleDomainError(e, {fallbackMessage: "Could not restore session. Please try again.", fallbackScreen: "doors"})
      return
    }
  }
  const active = activeConversations(await listRecords())[0]
  if (active) {
    app.selectedDoor = active.value.display_door
    updateDoorLabels()
    await handleMatchedConversation({status: "matched", conversation_id: active.value.conversation_id})
  } else {
    const activeNode = document.querySelector('section.screen.active')
    if (!activeNode || ["match", "queue", "conversation"].includes(activeNode.dataset.screen)) {
      show("doors")
    }
  }
}

async function recoverIdentity() { await deleteRecord(identityKey); app.socket?.disconnect(); await createIdentity(true); connectSocket() }

function handleDomainError(error, context = {}) {
  const code = (error?.error?.code || error?.code || error?.reason || "").toUpperCase().replace(/[\s-]+/g, "_")

  switch (code) {
    case "PARTICIPANT_BUSY":
      announce("Reconnecting to your active conversation…")
      return resumeLocalConversation()

    case "STALE_ATTEMPT":
      announce("Refreshing your current matchmaking state…")
      return resumeLocalConversation()

    case "ALREADY_QUEUED_DIFFERENT_DOOR":
      announce("You are already waiting for a match.")
      return show("queue")

    case "INVALID_TOKEN":
    case "INVALID_PARTICIPANT":
    case "PARTICIPANT_MISMATCH":
      announce("Your session has expired. Reconnecting…")
      return recoverIdentity()

    case "NOT_CONVERSATION_MEMBER":
    case "CONVERSATION_NOT_FOUND":
    case "CONVERSATION_UNAVAILABLE":
    case "INVALID_TRANSITION":
    case "CONVERSATION_TERMINATING":
      announce("This Conversation can't be restored. The live Conversation is no longer available to recover.")
      return show("unrecoverable")

    case "QUEUE_JOIN_FAILED":
    case "INVALID_DOOR_TYPE":
      announce("Could not start matching right now. Please try again.")
      return show("doors")

    case "RATE_LIMITED":
    case "MESSAGE_BUFFER_FULL":
    case "VOICE_NOTE_PENDING_LIMIT":
      announce("Sending too quickly. Please wait a moment.")
      break

    case "CONVERSATION_BUSY":
      announce("The Conversation is busy. Please wait a moment.")
      break

    default:
      if (context.fallbackMessage) {
        announce(context.fallbackMessage)
      } else {
        announce("An unexpected error occurred. Please try again.")
      }
      if (context.fallbackScreen) {
        show(context.fallbackScreen)
      }
      break
  }
}

async function advanceSyncCursor(conversationId, epochId, sequence) {
  if (!sequence) return
  const cursorKey = `sync_cursor:${conversationId}`
  const existing = await getRecord(cursorKey)
  const prevSeq = existing?.value?.epoch_id === epochId ? (existing.value.last_applied_sequence || 0) : 0
  const nextSeq = Math.max(prevSeq, sequence)
  app.currentEpochId = epochId
  await putRecord(conversationSyncCursor({
    conversation_id: conversationId,
    epoch_id: epochId,
    last_applied_sequence: nextSeq,
    updated_at: now()
  }))
}

function initializeDeliveryProgress(epochId, baselineSequence, storedSequence = 0) {
  const progress = createDeliveryProgress(epochId, baselineSequence, storedSequence)
  app.deliveryProgress = {
    ...progress,
    inFlight: false,
    desired: progress.contiguous,
    confirmed: progress.baseline - 1,
    retryFor: null,
    reconciling: false
  }
}

async function markCanonicalSequenceApplied(sequence) {
  if (!Number.isInteger(sequence) || sequence <= 0 || !app.deliveryProgress.epochId) return
  if (sequence <= app.deliveryProgress.contiguous) return flushDeliveryProgress()
  if (sequence > app.deliveryProgress.contiguous + 1) requestDeliveryGapReconcile()
  app.deliveryProgress = {...app.deliveryProgress, ...applyCanonicalSequence(app.deliveryProgress, sequence)}
  app.deliveryProgress.desired = Math.max(app.deliveryProgress.desired, app.deliveryProgress.contiguous)
  await advanceSyncCursor(app.conversationId, app.deliveryProgress.epochId, app.deliveryProgress.contiguous)
  return flushDeliveryProgress()
}

async function requestDeliveryGapReconcile() {
  if (!app.conversation || app.deliveryProgress.reconciling) return
  app.deliveryProgress.reconciling = true
  try {
    const result = await push(app.conversation, "sync:reconcile", {
      last_applied_sequence: app.deliveryProgress.contiguous
    })
    await applySyncPayload(app.conversationId, {
      ...result,
      status: "catch_up_complete",
      latest_sequence: result.through_sequence,
      baseline_sequence: result.from_sequence
    })
  } catch (_error) {
    return
  } finally {
    app.deliveryProgress.reconciling = false
  }
}

async function flushDeliveryProgress() {
  if (!app.conversation || app.deliveryProgress.inFlight || !app.deliveryProgress.epochId) return
  if (app.deliveryProgress.desired < app.deliveryProgress.baseline - 1) return
  if (app.deliveryProgress.desired <= app.deliveryProgress.confirmed) return
  const reported = app.deliveryProgress.desired
  app.deliveryProgress.inFlight = true
  try {
    const result = await push(app.conversation, "delivery:progress", {
      epoch_id: app.deliveryProgress.epochId,
      highest_contiguous_sequence: reported
    })
    app.deliveryProgress.confirmed = Math.max(app.deliveryProgress.confirmed, result.highest_contiguous_sequence || reported)
  } catch (_error) {
    if (app.deliveryProgress.retryFor !== reported) {
      app.deliveryProgress.retryFor = reported
      setTimeout(() => flushDeliveryProgress(), 500)
    }
    return
  } finally {
    app.deliveryProgress.inFlight = false
  }
  if (app.deliveryProgress.desired > reported) return flushDeliveryProgress()
}

async function applySyncPayload(conversationId, syncPayload) {
  const {status, epoch_id, latest_sequence, messages, baseline_sequence} = syncPayload
  if (app.currentEpochId && epoch_id && app.currentEpochId !== epoch_id) {
    resetAmbientAudio()
    cancelMessageEdit({restoreFocus: false})
    closeMessageUnsend({restoreFocus: false})
    resetAtmosphere()
    resetPromptCards()
    resetIcebreaker()
    resetAvatars()
    app.messageAvailability.clear()
    if (conversationId === app.conversationId) resetPinnedMessages(conversationId, epoch_id)
  }
  app.currentEpochId = epoch_id
  applyCanonicalIcebreaker(syncPayload.icebreaker)
  if (syncPayload.avatars) {
    applyAvatarPresentation(syncPayload.avatars)
  }
  if (syncPayload.call_state) {
    applyCallStateSync(syncPayload.call_state)
  }

  const cursorRecord = await getRecord(`sync_cursor:${conversationId}`)
  const storedSequence = cursorRecord?.value?.epoch_id === epoch_id ? (cursorRecord.value.last_applied_sequence || 0) : 0
  initializeDeliveryProgress(epoch_id, baseline_sequence, storedSequence)

  if (status === "epoch_changed") {
    await putRecord(conversationSyncCursor({
      conversation_id: conversationId,
      epoch_id,
      last_applied_sequence: 0,
      updated_at: now()
    }))
  }

  if (status === "catch_up_partial") {
    announce("Some messages from while you were away are no longer available.")
  }

  for (const item of (messages || [])) {
    if (item.disposition === "skipped_terminal_failure") {
      await markCanonicalSequenceApplied(item.sequence)
      continue
    }

    if (item.type === "text") {
      const mine = item.sender_id === app.identity?.participant_id || item.mine
      if (mine) {
        updateMessageStatus({client_message_id: item.client_message_id, message_id: item.message_id, sequence: item.sequence, status: item.status})
      } else {
        await renderMessage(item, false)
        if (item.status !== "failed") {
        }
      }
      await applyCanonicalMessageRevision(item, {source: "sync"})
      await markCanonicalSequenceApplied(item.sequence)
    } else if (item.type === "voice_note") {
      await markCanonicalSequenceApplied(item.sequence)
    } else if (item.type === "expressive") {
      const mine = item.sender_id === app.identity?.participant_id || item.mine
      if (mine && app.rendered.has(item.client_message_id || item.message_id)) {
        updateMessageStatus({client_message_id: item.client_message_id, message_id: item.message_id, sequence: item.sequence, status: item.status})
      } else {
        renderMessage(item, mine)
      }
      await markCanonicalSequenceApplied(item.sequence)
    }
  }

  for (const current of (syncPayload.current_message_revisions || [])) {
    const messageId = current.client_message_id || current.message_id
    if (!app.rendered.has(messageId)) await renderMessage(current, current.mine === true)
    await applyCanonicalMessageRevision(current, {source: "sync"})
  }

  if (status !== "sequence_inconsistent" && Array.isArray(syncPayload.current_message_revisions)) {
    await removeLocalOnlyCanonicalMessages(conversationId, syncPayload.current_message_revisions)
  }

  if (status === "up_to_date" && latest_sequence === app.deliveryProgress.contiguous) await flushDeliveryProgress()

  if (Array.isArray(syncPayload.reaction_snapshots)) {
    const authoritativeTargetIds = new Set(syncPayload.reaction_snapshots.map((s) => s.target_client_message_id))
    for (const snap of syncPayload.reaction_snapshots) {
      app.reactionAuthority.set(snap.target_client_message_id, "active")
      const msgKey = `message:${conversationId}:${snap.target_client_message_id}`
      let selfWinner = null
      let peerWinner = null
      if (snap.self_reaction) {
        const res = await mergeReactionRecord(msgKey, "self_reaction", snap.self_reaction)
        selfWinner = res.winner
      }
      if (snap.peer_reaction) {
        const res = await mergeReactionRecord(msgKey, "peer_reaction", snap.peer_reaction)
        peerWinner = res.winner
      }
      const rec = await getRecord(msgKey)
      const currentSelf = selfWinner || rec?.value?.self_reaction
      const currentPeer = peerWinner || rec?.value?.peer_reaction
      updateMessageReactionsDisplay(snap.target_client_message_id, currentSelf, currentPeer, undefined)
    }

    const allRenderedNodes = document.querySelectorAll("#messages .message")
    for (const node of allRenderedNodes) {
      const msgId = node.dataset.messageId
      if (msgId && !authoritativeTargetIds.has(msgId)) {
        app.reactionAuthority.set(msgId, "frozen")
      }
    }
  }

  if (syncPayload.pins && status !== "sequence_inconsistent") {
    establishPinnedMessagesScope(conversationId, epoch_id)
    mergePinnedMessages(syncPayload.pins, {authoritative: true, conversationId, epochId: epoch_id})
  }

  if (syncPayload.peer_presence !== undefined) {
    updatePresenceDisplay(syncPayload.peer_presence)
  }

  await reconcileAmbiguousSendingMessages(conversationId, epoch_id, messages || [])
}

async function removeLocalOnlyCanonicalMessages(conversationId, canonicalMessages) {
  const canonicalIds = new Set(canonicalMessages.map((message) => message.client_message_id || message.message_id).filter(Boolean))
  const records = await listRecords()
  const stale = records.filter((record) => record.type === "local_message" && record.value.conversation_id === conversationId && record.value.delivery_status !== "sending" && !canonicalIds.has(record.value.client_message_id || record.value.message_id))
  for (const record of stale) {
    const messageId = record.value.client_message_id || record.value.message_id
    await deleteRecord(record.id)
    document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`)?.remove()
    app.rendered.delete(messageId)
    app.messageAvailability.set(messageId, "unavailable")
    await sanitizeLocalReplyReferences(messageId, "unavailable")
  }
}

async function sanitizeLocalReplyReferences(targetMessageId, reason) {
  app.replySelectionGeneration++
  if (app.replyState?.reply_to_client_message_id === targetMessageId) {
    setReplyStaging({
      ...app.replyState,
      reply_snippet: reason === "unsent" ? "Unsent message" : "Message unavailable"
    })
  }
  const records = await listRecords()
  for (const record of records) {
    const sanitized = sanitizeMessageReference(record, targetMessageId, reason, now())
    if (sanitized === record) continue
    await putRecord(sanitized)
    const messageId = sanitized.value.client_message_id || sanitized.value.message_id
    const snippet = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"] .reply-snippet`)
    if (snippet) snippet.textContent = sanitized.value.reply_snippet
  }
}

async function reconcileAmbiguousSendingMessages(conversationId, epochId, serverReplayMessages) {
  const records = await listRecords()
  const localSendingMessages = records.filter((rec) =>
    rec.type === "local_message" &&
    rec.value.conversation_id === conversationId &&
    rec.value.mine &&
    rec.value.delivery_status === "sending"
  )

  const serverMsgIds = new Set(serverReplayMessages.map((m) => m.client_message_id || m.message_id))

  for (const rec of localSendingMessages) {
    const msgId = rec.value.client_message_id || rec.value.message_id
    if (serverMsgIds.has(msgId)) {
      continue
    }

    if (app.conversation && app.currentEpochId === epochId) {
      try {
        const sendPayload = {
          client_message_id: msgId,
          message_id: msgId,
          content: rec.value.content
        }
        if (rec.value.reply_to_client_message_id) {
          sendPayload.reply_to_client_message_id = rec.value.reply_to_client_message_id
        }
        const reply = await push(app.conversation, "message:send", sendPayload)
        updateMessageStatus(reply)
        await markCanonicalSequenceApplied(reply.sequence)
      } catch (err) {
        const errorCode = err?.error?.code || err?.code
        if (errorCode && ["NOT_CONVERSATION_MEMBER", "CONVERSATION_UNAVAILABLE", "INVALID_MESSAGE_ID", "INVALID_PAYLOAD", "MESSAGE_ID_CONFLICT", "CONVERSATION_TERMINATING"].includes(errorCode)) {
          updateMessageStatus({client_message_id: msgId, message_id: msgId, status: "failed"})
        }
        handleDomainError(err)
      }
    }
  }
}

async function joinConversation(id) {
  const cursorRecord = await getRecord(`sync_cursor:${id}`)
  const clientEpochId = cursorRecord?.value?.epoch_id || null
  const lastAppliedSequence = cursorRecord?.value?.last_applied_sequence || 0

  const channel = app.socket.channel(`conversation:${id}`, {
  epoch_id: clientEpochId,
  last_applied_sequence: lastAppliedSequence
})
  app.conversation = channel
  const runtimeBindings = []
  const runtimeIsCurrent = () => app.conversation === channel && app.conversationId === id
  const onCurrent = (event, handler) => {
    const ref = channel.on(event, (...args) => {
      if (!runtimeIsCurrent()) return
      return handler(...args)
    })
    runtimeBindings.push([event, ref])
    return ref
  }
  channel.__f04ReleaseRuntimeBindings = () => {
    for (const [event, ref] of runtimeBindings.splice(0)) {
      try { channel.off(event, ref) } catch (_) {}
    }
  }

  onCurrent("conversation:presence", ({status}) => {
    updatePresenceDisplay(status)
    if (status === "connected") scrollTimelineToNewest()
  })

  onCurrent("typing:status", ({typing}) => {
    $("#typing").textContent = typing ? "The other person is typing…" : ""
  })

  onCurrent("message:new", async (message) => {
    if (app.currentEpochId && message.epoch_id && message.epoch_id !== app.currentEpochId) return
    await renderMessage(message, false)
    await applyCanonicalMessageRevision(message, {source: "live"})
    await markCanonicalSequenceApplied(message.sequence)
  })

  onCurrent("message:status", updateMessageStatus)
  onCurrent("message:edited", (message) => applyCanonicalMessageRevision(message, {source: "live"}))
  onCurrent("message:unsent", (message) => applyCanonicalMessageUnsent(message, {source: "live"}))
  onCurrent("message:content_status", updateMessageContentStatus)
  onCurrent("message:reaction", handleLiveReaction)
  onCurrent("conversation:pins", (payload) => handleLivePins(payload, id))
  onCurrent("conversation:icebreaker", applyCanonicalIcebreaker)
  onCurrent("voice_note:new", async (note) => {
    await receiveVoiceNote(note, {conversationId: id, channel, isCurrent: runtimeIsCurrent})
    if (!runtimeIsCurrent()) return
    await markCanonicalSequenceApplied(note.sequence)
  })
  onCurrent("voice_note:status", updateVoiceNoteStatus)
  onCurrent("view_once:viewed", (payload) => {
    updateViewOnceState(
      payload.client_message_id || payload.message_id,
      payload.view_once_state || "viewed",
      payload.views_remaining,
      payload.presentation_limit
    )
  })
  onCurrent("view_once:unavailable", (payload) => {
    updateViewOnceState(
      payload.client_message_id || payload.message_id,
      "unavailable",
      0,
      payload.presentation_limit
    )
  })
  const coord = initLiveCallCoordinator()
  coord.setChannel(channel)
  coord.setParticipantId(app.identity?.participant_id)
  coord.setConversationId(id)

  onCurrent("call:incoming", (payload) => coord.handleIncomingCall(payload))
  onCurrent("call:accepted", (payload) => coord.handleCallAccepted(payload))
  onCurrent("call:ended", (payload) => coord.handleCallEnded(payload))
  onCurrent("call:mute_changed", (payload) => coord.handleMuteChanged(payload))
  onCurrent("call:effect_changed", (payload) => coord.handleEffectChanged(payload))
  onCurrent("call:signal", (payload) => coord.handleSignal(payload))
  onCurrent("call:media_requested", (payload) => coord.handleMediaRequested(payload))
  onCurrent("call:media_updated", (payload) => coord.handleMediaUpdated(payload))
  onCurrent("call:media_declined", (payload) => coord.handleMediaDeclined(payload))
  onCurrent("call:reveal_ready", (payload) => coord.handleRevealReady(payload))
  onCurrent("call:reveal_committed", (payload) => coord.handleRevealCommitted(payload))
  onCurrent("call:reaction", (payload) => coord.handleReaction(payload))

  onCurrent("conversation:ended", async () => {
    if (app.conversationId !== id) return
    clearConversationTypingRuntime()
    app.liveCall?.teardown()
    closeViewOnceModal()
    clearViewOncePreview()
    cancelMessageEdit({restoreFocus: false})
    closeMessageUnsend({restoreFocus: false})
    closeReactionPicker()
    closeReportForm()
    $("#report-form")?.reset()
    cancelRecording()
    cancelReplyStaging()
    $("#message-form")?.classList.remove("ig-tray-open")
    const composerInput = $("#message-input")
    if (composerInput) {
      composerInput.value = ""
      renderPromptDraftAvailability()
    }
    resetPinnedMessages()
    app.peerPresence = null
    renderPresenceText()
    resetAmbientAudio()
    resetQuietMode()
    resetAtmosphere()
    resetPromptCards()
    resetIcebreaker()
    resetAvatars()
    app.messageAvailability.clear()
    await markConversationEnded()
    await navigation.activityEvent("conversation_ended")
    $("#consent")?.focus()
    announce("Conversation ended. Choose what this device should retain.")
  })

  channel.join()
    .receive("ok", async (syncPayload) => {
      if (!runtimeIsCurrent()) { releaseConversationChannel(channel); return }
      await ensureTemporaryConversation(id)
      if (!runtimeIsCurrent()) return
      await renderCachedConversation(id)
      if (!runtimeIsCurrent()) return
      if (syncPayload) {
        await applySyncPayload(id, syncPayload)
        if (!runtimeIsCurrent()) return
      }
      updateLocalConnection("connected")
      app.ambient?.setConversationActive(true)
      reportCurrentVisibility()
      renderQuietModeUI()
      show("conversation")
      scrollTimelineToNewest()
      announce("Conversation joined.")
    })
    .receive("error", async (error) => {
      if (!runtimeIsCurrent()) { releaseConversationChannel(channel); return }
      releaseConversationRuntime({conversationId: id, channel})
      cancelMessageEdit({restoreFocus: false})
      closeMessageUnsend({restoreFocus: false})
      app.matchedTransition.release(id)
      if (app.conversationId === id) app.conversationId = null
      if (app.pinnedMessages.conversationId === id) resetPinnedMessages()
      resetAmbientAudio()
      resetQuietMode()
      resetAtmosphere()
      resetPromptCards()
      resetIcebreaker()
      resetAvatars()
      app.messageAvailability.clear()
      await markConversationEndedById(id)
      handleDomainError(error, {fallbackMessage: "Previous conversation is no longer available.", fallbackScreen: "doors"})
    })
}

async function handleMatchedConversation(payload, relationshipId = null) {
  const conversationId = app.matchedTransition.claim(payload)
  if (!conversationId) return
  if (app.conversation || app.conversationId) releaseConversationRuntime()
  markConversationAuthorityTransition()
  app.queueAttemptId = null
  cancelMessageEdit({restoreFocus: false})
  closeMessageUnsend({restoreFocus: false})
  resetAmbientAudio()
  resetQuietMode()
  resetAtmosphere()
  resetPromptCards()
  resetIcebreaker()
  resetAvatars()
  app.messageAvailability.clear()
  if (relationshipId) await putRecord(reconnectStateRecord({relationship_id: relationshipId, status: "matched", conversation_id: conversationId}, now()))
  app.reconnectCountdown.stop()
  app.conversationId = conversationId
  resetPinnedMessages(conversationId)
  await ensureTemporaryConversation(conversationId)
  show("match")
  joinConversation(conversationId)
}

async function ensureTemporaryConversation(conversationId) {
  const id = `conversation:${conversationId}`
  const existing = await getRecord(id)
  if (existing) return putRecord({...existing, value: {...existing.value, connection_state: "connected"}, updated_at: now()})
  const door = DOORS.find(({label}) => label === app.selectedDoor) || DOORS[0]
  return putRecord(temporaryConversation({conversation_id: conversationId, door_type: door.value, display_door: door.label, started_at: now()}))
}

async function updateLocalConnection(connection_state) {
  app.localConnectionState = connection_state
  renderPresenceText()
  if (!app.conversationId) return
  const record = await getRecord(`conversation:${app.conversationId}`)
  if (record?.value.status === "temporary") await putRecord({...record, value: {...record.value, connection_state}, updated_at: now()})
}

function updatePresenceDisplay(peerStatus) {
  app.peerPresence = peerStatus || null
  renderPresenceText()
}

function renderPresenceText() {
  const presenceEl = $("#presence")
  if (!presenceEl) return
  const supportEl = $("#presence-support")

  if (app.localConnectionState === "reconnecting" || app.localConnectionState === "recovery") {
    if (supportEl) supportEl.hidden = false
    presenceEl.textContent = "Reconnecting…"
    return
  }

  if (supportEl) supportEl.hidden = true

  if (app.peerPresence === "connected") {
    presenceEl.textContent = "Connected"
  } else if (app.peerPresence === "away") {
    presenceEl.textContent = "Temporarily away"
  } else {
    presenceEl.textContent = ""
  }
}

function reportCurrentVisibility() {
  if (!app.conversation) return
  const visibility = document.visibilityState === "hidden" ? "hidden" : "visible"
  push(app.conversation, "session:visibility", {visibility}).catch(() => {})
}

function clearConversationTypingRuntime() {
  clearTimeout(app.typingTimer)
  app.typingTimer = null
  const typing = $("#typing")
  if (typing) typing.textContent = ""
}

const releasedConversationChannels = new WeakSet()

function releaseConversationChannel(channel) {
  if (!channel || releasedConversationChannels.has(channel)) return
  releasedConversationChannels.add(channel)
  try { channel.__f04ReleaseRuntimeBindings?.() } catch (_) {}
  try { channel.leave() } catch (_) {}
}

function releaseConversationRuntime({conversationId = app.conversationId, channel = app.conversation} = {}) {
  const targetsCurrent = Boolean(conversationId || channel) && app.conversation === channel && app.conversationId === conversationId
  if (targetsCurrent) {
    clearConversationTypingRuntime()
    app.conversation = null
    app.conversationId = null
    app.currentEpochId = null
    app.matchedTransition.release(conversationId)
  }
  releaseConversationChannel(channel)
  return targetsCurrent
}

function isQuietModeActive() {
  return Boolean(app.quietMode)
}

function setQuietMode(active) {
  const next = Boolean(active)
  if (app.quietMode === next) return
  app.quietMode = next
  app.ambient?.setQuiet(next)
  renderQuietModeUI()
}

function toggleQuietMode() {
  setQuietMode(!app.quietMode)
}

function resetQuietMode() {
  app.quietMode = false
  app.ambient?.setQuiet(false)
  renderQuietModeUI()
}

function renderQuietModeUI() {
  const control = $("#quiet-mode-control")
  if (!control) return
  const isActive = Boolean(app.quietMode)
  control.setAttribute("aria-pressed", isActive ? "true" : "false")
  control.setAttribute("aria-label", isActive ? "Quiet Mode, on" : "Quiet Mode, off")
  control.textContent = isActive ? "🔕" : "🔔"
  control.classList.toggle("is-active", isActive)
}

function triggerPresentationEffect(effectFn) {
  if (isQuietModeActive()) return false
  if (typeof effectFn === "function") {
    effectFn()
  }
  return true
}

function renderPromptDraftAvailability() {
  const useButton = $("#prompt-use")
  const status = $("#prompt-draft-status")
  const input = $("#message-input")
  if (!useButton || !status || !input) return
  const hasDraft = input.value.length > 0
  useButton.disabled = hasDraft || !approvedPrompt(app.promptCards.promptId)
  status.textContent = hasDraft
    ? "Your existing draft is kept. Clear it before using a prompt."
    : "Using a prompt adds editable text here. It will not send until you press Send."
}

function renderPromptCardsUI({focusSelected = false} = {}) {
  const helper = $("#prompt-helper")
  const control = $("#prompt-control")
  const options = $("#prompt-options")
  if (!helper || !control || !options) return

  helper.hidden = !app.promptCards.open
  control.setAttribute("aria-expanded", app.promptCards.open ? "true" : "false")
  document.querySelectorAll("[data-prompt-category]").forEach((button) => {
    button.setAttribute("aria-pressed", button.dataset.promptCategory === app.promptCards.categoryId ? "true" : "false")
  })

  options.replaceChildren()
  for (const prompt of promptsForCategory(app.promptCards.categoryId)) {
    const option = document.createElement("button")
    option.type = "button"
    option.className = "prompt-option"
    option.dataset.promptOption = prompt.id
    option.setAttribute("aria-pressed", prompt.id === app.promptCards.promptId ? "true" : "false")
    option.textContent = prompt.text
    option.addEventListener("click", () => selectPromptCard(prompt.id))
    options.append(option)
  }

  renderPromptDraftAvailability()
  if (focusSelected) options.querySelector('[aria-pressed="true"]')?.focus()
}

function applyPromptCardTransition(operation, options = {}) {
  const transition = transitionPromptCards(app.promptCards, operation)
  if (transition.status === "invalid") return transition
  app.promptCards = transition.state
  renderPromptCardsUI(options)
  return transition
}

function openPromptCards() {
  applyPromptCardTransition({type: "open"})
  document.querySelector(`[data-prompt-category="${app.promptCards.categoryId}"]`)?.focus()
}

function closePromptCards({restoreFocus = true} = {}) {
  applyPromptCardTransition({type: "close"})
  if (restoreFocus) $("#prompt-control")?.focus()
}

function selectPromptCategory(categoryId) {
  applyPromptCardTransition({type: "select_category", categoryId}, {focusSelected: true})
}

function selectPromptCard(promptId) {
  applyPromptCardTransition({type: "select_prompt", promptId}, {focusSelected: true})
}

function useSelectedPrompt() {
  const input = $("#message-input")
  if (!input) return
  const insertion = insertPromptDraft(input.value, app.promptCards.promptId)
  if (insertion.status === "inserted") {
    input.value = insertion.draft
    closePromptCards({restoreFocus: false})
    input.focus()
    announce("Prompt added to your draft. Edit it, then send when ready.")
  } else if (insertion.status === "blocked_non_empty") {
    announce("Your existing draft was kept. Clear it before using a prompt.")
  }
  renderPromptDraftAvailability()
}

function resetPromptCards() {
  app.promptCards = transitionPromptCards(app.promptCards, {type: "reset"}).state
  renderPromptCardsUI()
}

function renderIcebreakerUI() {
  const card = $("#icebreaker-card")
  const text = $("#icebreaker-text")
  if (!card || !text) return
  const item = visibleIcebreaker(app.icebreaker)
  card.hidden = !item
  text.textContent = item?.text || ""
}

function applyCanonicalIcebreaker(snapshot) {
  app.icebreaker = applyIcebreakerSnapshot(app.icebreaker, snapshot)
  renderIcebreakerUI()
}

function locallyDismissIcebreaker() {
  app.icebreaker = dismissIcebreaker(app.icebreaker)
  renderIcebreakerUI()
  $("#message-input")?.focus()
}

function resetIcebreaker() {
  app.icebreaker = resetIcebreakerState()
  renderIcebreakerUI()
}

function applyAvatarPresentation(avatars) {
  if (!avatars) return
  app.avatars = avatars
  renderAvatarPresentation()
}

function renderAvatarPresentation() {
  if (!app.avatars) return
  let container = $("#conversation-avatar-presentation")
  if (!container) {
    const parent = document.querySelector(".conversation-identity div")
    if (!parent) return
    container = document.createElement("div")
    container.id = "conversation-avatar-presentation"
    container.className = "avatar-presentation"
    container.setAttribute("role", "region")
    container.setAttribute("aria-label", "Conversation avatars")

    const selfBadge = document.createElement("div")
    selfBadge.className = "avatar-badge avatar-self"
    selfBadge.tabIndex = 0
    selfBadge.setAttribute("role", "img")
    selfBadge.innerHTML = '<img src="" alt="" class="avatar-img" /><span class="avatar-fallback" hidden>You</span><span class="avatar-name">You</span>'

    const peerBadge = document.createElement("div")
    peerBadge.className = "avatar-badge avatar-peer"
    peerBadge.tabIndex = 0
    peerBadge.setAttribute("role", "img")
    peerBadge.innerHTML = '<img src="" alt="" class="avatar-img" /><span class="avatar-fallback" hidden>Other participant</span><span class="avatar-name">Other participant</span>'

    container.append(selfBadge, peerBadge)
    parent.appendChild(container)
  }

  const self = app.avatars.self
  const peer = app.avatars.peer

  const selfLabel = self?.label || "You"
  const peerLabel = peer?.label || "Other participant"
  const selfKey = self?.avatar_key || "generic-self"
  const peerKey = peer?.avatar_key || "generic-peer"
  const selfUrl = self?.asset_url || `/assets/avatars/${selfKey}.svg`
  const peerUrl = peer?.asset_url || `/assets/avatars/${peerKey}.svg`

  container.hidden = false
  container.setAttribute("aria-label", `Your avatar: ${selfLabel}. Peer avatar: ${peerLabel}.`)

  const selfElem = container.querySelector(".avatar-self")
  if (selfElem) {
    selfElem.setAttribute("data-avatar-key", selfKey)
    selfElem.setAttribute("aria-label", `Your avatar: ${selfLabel}`)
    const img = selfElem.querySelector("img")
    if (img) {
      img.src = selfUrl
      img.alt = `Your avatar: ${selfLabel}`
      img.onerror = () => {
        img.style.display = "none"
        const fb = selfElem.querySelector(".avatar-fallback")
        if (fb) fb.hidden = false
      }
      img.onload = () => {
        img.style.display = ""
        const fb = selfElem.querySelector(".avatar-fallback")
        if (fb) fb.hidden = true
      }
    }
    const labelSpan = selfElem.querySelector(".avatar-name")
    if (labelSpan) labelSpan.textContent = `You (${selfLabel})`
  }

  const peerElem = container.querySelector(".avatar-peer")
  if (peerElem) {
    peerElem.setAttribute("data-avatar-key", peerKey)
    peerElem.setAttribute("aria-label", `Peer avatar: ${peerLabel}`)
    const img = peerElem.querySelector("img")
    if (img) {
      img.src = peerUrl
      img.alt = `Peer avatar: ${peerLabel}`
      img.onerror = () => {
        img.style.display = "none"
        const fb = peerElem.querySelector(".avatar-fallback")
        if (fb) fb.hidden = false
      }
      img.onload = () => {
        img.style.display = ""
        const fb = peerElem.querySelector(".avatar-fallback")
        if (fb) fb.hidden = true
      }
    }
    const labelSpan = peerElem.querySelector(".avatar-name")
    if (labelSpan) labelSpan.textContent = peerLabel
  }
}

function resetAvatars() {
  app.avatars = null
  const container = $("#conversation-avatar-presentation")
  if (container) {
    container.remove()
  }
}

function setAtmosphere(requestedId) {
  const transition = transitionAtmosphere(app.atmosphereId, requestedId)
  if (transition.status === "invalid") return transition
  app.atmosphereId = transition.atmosphereId
  app.ambient?.setTheme(app.atmosphereId)
  renderAtmosphereUI()
  return transition
}

function initializeAmbientAudio() {
  app.ambient = new AmbientAudioController({
    createAudio: () => $("#ambient-audio"),
    onStateChange: renderAmbientAudioUI
  })
  app.ambient.setTheme(app.atmosphereId)
  app.ambient.setQuiet(app.quietMode)
  app.ambient.setVisible(document.visibilityState !== "hidden")
  renderAmbientAudioUI()
}

function renderAmbientAudioUI() {
  const control = $("#ambient-audio-control")
  if (!control || !app.ambient) return
  const {enabled, status} = app.ambient.snapshot()
  control.setAttribute("aria-pressed", enabled ? "true" : "false")
  control.setAttribute("aria-label", `Ambient Audio, ${enabled ? "on" : "off"}`)
  control.textContent = `Ambient Audio: ${enabled ? "On" : "Off"}`
  control.dataset.playbackStatus = status
}

function toggleAmbientAudio() {
  if (!app.ambient) return
  app.ambient.setEnabled(!app.ambient.enabled)
}

function resetAmbientAudio() {
  app.activeVoicePlayback.clear()
  app.ambient?.reset()
}

function updateExplicitVoiceConflict(audio, playing) {
  if (playing) app.activeVoicePlayback.add(audio)
  else app.activeVoicePlayback.delete(audio)
  app.ambient?.setExplicitAudioConflict(app.activeVoicePlayback.size > 0)
}

function resetAtmosphere() {
  const transition = setAtmosphere(null)
  closeAtmosphereChooser({ restoreFocus: false })
  return transition
}

function renderAtmosphereUI() {
  const conversation = document.querySelector('section[data-screen="conversation"]')
  if (!conversation) return
  const atmosphere = approvedAtmosphere(app.atmosphereId)
  if (atmosphere) conversation.dataset.atmosphere = atmosphere.id
  else delete conversation.dataset.atmosphere

  const control = $("#atmosphere-control")
  if (control) control.textContent = atmosphere ? atmosphere.label : "Atmosphere"
  document.querySelectorAll("[data-atmosphere-option]").forEach((option) => {
    option.setAttribute("aria-pressed", option.dataset.atmosphereOption === atmosphere?.id ? "true" : "false")
  })
}

function openAtmosphereChooser() {
  const chooser = $("#atmosphere-chooser")
  if (!chooser) return
  chooser.hidden = false
  $("#atmosphere-control")?.setAttribute("aria-expanded", "true")
  chooser.querySelector("[data-atmosphere-option]")?.focus()
}

function closeAtmosphereChooser({restoreFocus = true} = {}) {
  const chooser = $("#atmosphere-chooser")
  if (!chooser) return
  chooser.hidden = true
  $("#atmosphere-control")?.setAttribute("aria-expanded", "false")
  if (restoreFocus) $("#atmosphere-control")?.focus()
}

function renderAtmosphereCatalog() {
  const options = $("#atmosphere-options")
  if (!options || options.childElementCount) return
  for (const atmosphere of ATMOSPHERES) {
    const option = document.createElement("button")
    option.type = "button"
    option.className = "atmosphere-option"
    option.dataset.atmosphereOption = atmosphere.id
    option.setAttribute("aria-pressed", "false")
    option.innerHTML = `<span class="atmosphere-swatch" data-preview="${atmosphere.id}" aria-hidden="true"></span><span><strong>${atmosphere.label}</strong><small>${atmosphere.description}</small></span>`
    option.addEventListener("click", () => setAtmosphere(atmosphere.id))
    options.append(option)
  }
  renderAtmosphereUI()
}

document.addEventListener("visibilitychange", () => {
  reportCurrentVisibility()
  app.ambient?.setVisible(document.visibilityState !== "hidden")
})

async function markConversationEndedById(conversationId) {
  if (!conversationId) return
  const record = await getRecord(`conversation:${conversationId}`)
  if (record) await putRecord({...record, value: {...record.value, connection_state: "ended", ended_at: now()}, updated_at: now()})
}

async function markConversationEnded() {
  await markConversationEndedById(app.conversationId)
}


async function renderCachedConversation(conversationId) {
  app.rendered.clear(); $("#messages").replaceChildren()
  const records = await listRecords()
  chronologicalTimeline(records.filter((record) => ["local_message", "local_voice_note"].includes(record.type) && record.value.conversation_id === conversationId)).forEach((record) => record.type === "local_voice_note" ? renderVoiceNoteNode(record.value, $("#messages"), false) : renderMessageNode(record.value, record.value.mine, $("#messages")))
}

function isValidStatusTransition(current, next) {
  const normCurrent = current === "sent_to_server" ? "sent" : current || "sending"
  const normNext = next === "sent_to_server" ? "sent" : next
  if (normCurrent === normNext) return true
  if (normCurrent === "delivered") return false
  if (normCurrent === "failed") return false
  if (normCurrent === "sending" && ["sent", "delivered", "failed"].includes(normNext)) return true
  if (normCurrent === "sent" && ["delivered", "failed"].includes(normNext)) return true
  return false
}

function cancelReplyStaging() {
  app.replyState = null
  app.replySelectionGeneration++
  const staging = $("#reply-staging")
  if (staging) staging.hidden = true
}

function setReplyStaging(replyContext) {
  app.replyState = replyContext
  const authorLabel = replyContext.reply_author_relation === "same_author" ? "You" : "Stranger"
  const authorEl = $("#reply-staging-author")
  const snippetEl = $("#reply-staging-snippet")
  const stagingEl = $("#reply-staging")
  if (authorEl) authorEl.textContent = `Replying to ${authorLabel}`
  if (snippetEl) snippetEl.textContent = replyContext.reply_snippet
  if (stagingEl) stagingEl.hidden = false
  $("#message-input")?.focus()
}

function startReplyCheck(targetMessageId) {
  if (!targetMessageId || !app.conversation) return
  const generation = ++app.replySelectionGeneration
  push(app.conversation, "message:reply_target", {reply_to_client_message_id: targetMessageId})
    .then((res) => {
      if (app.replySelectionGeneration !== generation) return
      if (res?.status === "found") {
        setReplyStaging({
          reply_to_client_message_id: res.reply_to_client_message_id,
          reply_author_relation: res.reply_author_relation,
          reply_snippet: res.reply_snippet
        })
      } else if (res?.status === "confirmed_unavailable") {
        announce("This older message can't be replied to anymore.")
      } else {
        announce("Couldn't check that message right now. Try again.")
      }
    })
    .catch((error) => {
      if (app.replySelectionGeneration !== generation) return
      const errorCode = error?.error?.code || error?.code
      if (["INVALID_REQUEST", "INVALID_PAYLOAD", "INVALID_MESSAGE_ID"].includes(errorCode)) {
        announce("This message cannot be replied to.")
      } else {
        announce("Couldn't check that message right now. Try again.")
      }
    })
}

function jumpToOriginalMessage(targetId) {
  if (!targetId) return
  const targetEl = document.querySelector(`[data-message-id="${CSS.escape(targetId)}"]`)
  if (targetEl) {
    targetEl.scrollIntoView({behavior: "smooth", block: "center"})
    targetEl.classList.remove("highlight")
    void targetEl.offsetWidth
    targetEl.classList.add("highlight")
    targetEl.focus({preventScroll: true})
    setTimeout(() => targetEl.classList.remove("highlight"), 1200)
  } else {
    announce("Original message is no longer available.")
  }
}

let fullPickerLoaded = false
let fullPickerElement = null

async function ensureFullPickerElement() {
  if (!fullPickerLoaded) {
    await import("/assets/emoji_picker/index.js")
    fullPickerLoaded = true
  }
  if (!fullPickerElement) {
    fullPickerElement = document.createElement("emoji-picker")
    fullPickerElement.className = "full-emoji-picker"
    fullPickerElement.dataSource = "/assets/emoji_picker/data.json"
    fullPickerElement.locale = "en"
    fullPickerElement.addEventListener("emoji-click", (e) => {
      const selectedEmoji = e.detail?.unicode || e.detail?.emoji?.unicode
      if (selectedEmoji && app.activeReactionPickerTarget) {
        const targetId = app.activeReactionPickerTarget
        closeReactionPicker()
        mutateReaction(targetId, selectedEmoji)
      }
    })
  }
  return fullPickerElement
}

function openReactionPicker(targetId, anchorNode) {
  if (!targetId || !app.conversation) return
  if (app.activeReactionPickerTarget === targetId) {
    closeReactionPicker()
    return
  }
  closeReactionPicker()
  if (app.reactionAuthority.get(targetId) === "frozen") {
    announce("Reactions are no longer available for this message.")
    return
  }

  const picker = document.createElement("div")
  picker.className = "reaction-picker"
  picker.setAttribute("role", "dialog")
  picker.setAttribute("aria-label", "Choose a reaction")

  // Quick tray default 6 shortcuts
  DEFAULT_QUICK_EMOJIS.forEach((emoji) => {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "reaction-btn"
    btn.dataset.emoji = emoji
    btn.dataset.code = emoji
    btn.setAttribute("aria-label", `React with ${emoji}`)
    btn.textContent = emoji
    btn.addEventListener("click", (e) => {
      e.stopPropagation()
      closeReactionPicker()
      mutateReaction(targetId, emoji)
    })
    picker.append(btn)
  })

  // '+' button to open full picker lazily
  const moreBtn = document.createElement("button")
  moreBtn.type = "button"
  moreBtn.className = "reaction-btn more-btn"
  moreBtn.setAttribute("aria-label", "More reactions")
  moreBtn.textContent = "+"
  moreBtn.addEventListener("click", async (e) => {
    e.stopPropagation()
    picker.classList.add("loading-full-picker")
    const fullPicker = await ensureFullPickerElement()
    picker.replaceChildren(fullPicker)
    picker.classList.remove("loading-full-picker")
    picker.classList.add("expanded-picker")
    fullPicker.focus()
  })
  picker.append(moreBtn)

  picker.addEventListener("keydown", (e) => {
    const buttons = Array.from(picker.querySelectorAll(".reaction-btn"))
    if (!buttons.length) return
    const currentIndex = buttons.indexOf(document.activeElement)
    if (e.key === "ArrowRight") {
      e.preventDefault()
      const nextIndex = currentIndex < buttons.length - 1 ? currentIndex + 1 : 0
      buttons[nextIndex]?.focus()
    } else if (e.key === "ArrowLeft") {
      e.preventDefault()
      const prevIndex = currentIndex > 0 ? currentIndex - 1 : buttons.length - 1
      buttons[prevIndex]?.focus()
    } else if (e.key === "Escape") {
      e.preventDefault()
      closeReactionPicker()
      anchorNode?.focus()
    }
  })

  anchorNode?.append(picker)
  app.activeReactionPickerTarget = targetId
  picker.querySelector(".reaction-btn")?.focus()
}

function closeReactionPicker() {
  document.querySelectorAll(".reaction-picker").forEach((el) => el.remove())
  app.activeReactionPickerTarget = null
}

function updateMessageReactionsDisplay(targetId, selfSlot, peerSlot, optimisticSelfEmoji) {
  if (!targetId) return
  const container = document.querySelector(`.message-reactions[data-reactions-for="${CSS.escape(targetId)}"]`)
  if (!container) return

  container.replaceChildren()

  const selfNorm = normalizeReactionSlot(selfSlot)
  const peerNorm = normalizeReactionSlot(peerSlot)

  const selfEmoji = optimisticSelfEmoji !== undefined ? optimisticSelfEmoji : selfNorm?.emoji
  const peerEmoji = peerNorm?.emoji

  if (selfEmoji) {
    const selfBtn = document.createElement("button")
    selfBtn.type = "button"
    selfBtn.className = "reaction-pill self"
    selfBtn.setAttribute("aria-label", `You reacted with ${selfEmoji}`)
    selfBtn.textContent = selfEmoji
    selfBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      mutateReaction(targetId, null)
    })
    container.append(selfBtn)
  }

  if (peerEmoji) {
    const peerBtn = document.createElement("button")
    peerBtn.type = "button"
    peerBtn.className = "reaction-pill peer"
    peerBtn.setAttribute("aria-label", `Stranger reacted with ${peerEmoji}`)
    peerBtn.textContent = peerEmoji
    peerBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      const targetEl = document.querySelector(`[data-message-id="${CSS.escape(targetId)}"]`)
      openReactionPicker(targetId, targetEl)
    })
    container.append(peerBtn)
  }
}

async function mutateReaction(targetId, desiredEmoji) {
  if (!targetId || !app.conversation) return
  if (desiredEmoji !== null && (typeof desiredEmoji !== "string" || !desiredEmoji.trim())) return
  if (app.reactionAuthority.get(targetId) === "frozen") {
    announce("Reactions are no longer available for this message.")
    return
  }

  const inFlightState = app.reactionInFlight.get(targetId)
  if (inFlightState?.inFlight) {
    inFlightState.queuedDesired = desiredEmoji
    const id = `message:${app.conversationId}:${targetId}`
    const record = await getRecord(id)
    updateMessageReactionsDisplay(targetId, record?.value?.self_reaction, record?.value?.peer_reaction, desiredEmoji)
    return
  }

  const msgKey = `message:${app.conversationId}:${targetId}`
  const record = await getRecord(msgKey)
  const selfSlot = normalizeReactionSlot(record?.value?.self_reaction) || {emoji: null, revision: 0}
  const peerSlot = normalizeReactionSlot(record?.value?.peer_reaction) || {emoji: null, revision: 0}

  if (desiredEmoji === selfSlot.emoji) {
    updateMessageReactionsDisplay(targetId, selfSlot, peerSlot, undefined)
    return
  }

  const nextInFlight = {
    inFlight: true,
    desiredReaction: desiredEmoji,
    expectedRevision: selfSlot.revision || 0,
    queuedDesired: undefined,
    retryCount: 0
  }
  app.reactionInFlight.set(targetId, nextInFlight)
  updateMessageReactionsDisplay(targetId, selfSlot, peerSlot, desiredEmoji)

  push(app.conversation, "message:react", {
    target_client_message_id: targetId,
    desired_reaction: desiredEmoji,
    expected_reaction_revision: selfSlot.revision || 0
  })
    .then(async (res) => {
      nextInFlight.inFlight = false
      const serverEmoji = res?.emoji !== undefined ? res.emoji : res?.reaction
      if (res?.status === "applied" || res?.status === "already_canonical") {
        const {winner} = await mergeReactionRecord(msgKey, "self_reaction", {emoji: serverEmoji, revision: res.revision})
        const rec = await getRecord(msgKey)
        updateMessageReactionsDisplay(targetId, winner, rec?.value?.peer_reaction, undefined)
        if (nextInFlight.queuedDesired !== undefined && nextInFlight.queuedDesired !== serverEmoji) {
          const nextDesired = nextInFlight.queuedDesired
          app.reactionInFlight.delete(targetId)
          mutateReaction(targetId, nextDesired)
        } else {
          app.reactionInFlight.delete(targetId)
        }
      } else if (res?.status === "stale_revision") {
        nextInFlight.queuedDesired = undefined
        const {winner} = await mergeReactionRecord(msgKey, "self_reaction", {emoji: serverEmoji, revision: res.revision})
        const rec = await getRecord(msgKey)
        updateMessageReactionsDisplay(targetId, winner, rec?.value?.peer_reaction, undefined)
        app.reactionInFlight.delete(targetId)
      } else if (res?.status === "no_op") {
        const rec = await getRecord(msgKey)
        updateMessageReactionsDisplay(targetId, rec?.value?.self_reaction, rec?.value?.peer_reaction, undefined)
        if (nextInFlight.queuedDesired !== undefined && nextInFlight.queuedDesired !== serverEmoji) {
          const nextDesired = nextInFlight.queuedDesired
          app.reactionInFlight.delete(targetId)
          mutateReaction(targetId, nextDesired)
        } else {
          app.reactionInFlight.delete(targetId)
        }
      } else if (res?.status === "target_absent") {
        app.reactionAuthority.set(targetId, "frozen")
        nextInFlight.queuedDesired = undefined
        const rec = await getRecord(msgKey)
        updateMessageReactionsDisplay(targetId, rec?.value?.self_reaction, rec?.value?.peer_reaction, undefined)
        app.reactionInFlight.delete(targetId)
        announce("This message is no longer eligible for reactions.")
      } else {
        app.reactionInFlight.delete(targetId)
      }
    })
    .catch(async (error) => {
      nextInFlight.inFlight = false
      app.reactionInFlight.delete(targetId)
      const rec = await getRecord(msgKey)
      updateMessageReactionsDisplay(targetId, rec?.value?.self_reaction, rec?.value?.peer_reaction, undefined)
      const errorCode = error?.error?.code || error?.code
      if (errorCode === "RATE_LIMITED") {
        announce("Reaction limit reached. Please wait a moment.")
      } else if (errorCode === "INVALID_REQUEST" || errorCode === "INVALID_PAYLOAD") {
        announce("This reaction request was not valid.")
      } else {
        announce("Could not update reaction right now.")
      }
    })
}

async function handleLiveReaction(payload) {
  const {target_client_message_id, owner_relation, emoji, reaction, revision} = payload || {}
  if (!target_client_message_id) return
  if (app.messageAvailability.has(target_client_message_id)) {
    updateMessageReactionsDisplay(target_client_message_id, null, null, undefined)
    return
  }
  const slotKey = owner_relation === "self" ? "self_reaction" : "peer_reaction"
  const msgKey = `message:${app.conversationId}:${target_client_message_id}`
  const reactionVal = emoji !== undefined ? emoji : reaction
  const {winner} = await mergeReactionRecord(msgKey, slotKey, {emoji: reactionVal, revision})
  const rec = await getRecord(msgKey)
  const inFlight = app.reactionInFlight.get(target_client_message_id)
  const optimisticSelf = (owner_relation === "self" && inFlight?.inFlight) ? inFlight.desiredReaction : undefined
  const selfSlot = owner_relation === "self" ? winner : rec?.value?.self_reaction
  const peerSlot = owner_relation === "peer" ? winner : rec?.value?.peer_reaction
  updateMessageReactionsDisplay(target_client_message_id, selfSlot, peerSlot, optimisticSelf)
}

function resetPinnedMessages(conversationId = null, epochId = null) {
  app.pinnedMessages = {conversationId, epochId, items: [], revision: 0}
  app.pinMutationInFlight = false
  app.pinReconcileInFlight = false
  renderPinnedMessagesPanel()
  updatePinnedMarkers()
}

function pinnedMessagesScopeMatches(conversationId, epochId = null) {
  if (!conversationId || app.pinnedMessages.conversationId !== conversationId) return false
  return !epochId || !app.pinnedMessages.epochId || app.pinnedMessages.epochId === epochId
}

function establishPinnedMessagesScope(conversationId, epochId = null) {
  if (!conversationId || conversationId !== app.conversationId) return false
  const conversationChanged = app.pinnedMessages.conversationId !== conversationId
  const epochChanged = Boolean(epochId && app.pinnedMessages.epochId && app.pinnedMessages.epochId !== epochId)
  if (conversationChanged || epochChanged) {
    resetPinnedMessages(conversationId, epochId)
  } else if (epochId && !app.pinnedMessages.epochId) {
    app.pinnedMessages = {...app.pinnedMessages, epochId}
  }
  return true
}

function handleLivePins(payload, conversationId) {
  mergePinnedMessages(payload, {conversationId, epochId: app.currentEpochId})
}

function mergePinnedMessages(incoming, {authoritative = false, conversationId = app.conversationId, epochId = app.currentEpochId} = {}) {
  if (!incoming || !Number.isInteger(incoming.revision)) return
  if (conversationId !== app.conversationId || !pinnedMessagesScopeMatches(conversationId, epochId)) return
  if (incoming.revision < app.pinnedMessages.revision) return

  const rawIncomingItems = Array.isArray(incoming.pins)
    ? incoming.pins
    : (Array.isArray(incoming.items) ? incoming.items : [])
  const incomingItems = rawIncomingItems.map((item) => {
    const reason = app.messageAvailability.get(item.target_client_message_id)
    if (!reason) return item
    return {
      ...item,
      snippet: reason === "unsent" ? "Unsent message" : "Message unavailable",
      unavailable_reason: reason
    }
  })

  if (incoming.revision === app.pinnedMessages.revision) {
    const currentIds = app.pinnedMessages.items.map((p) => p.target_client_message_id).join(",")
    const incomingIds = incomingItems.map((p) => p.target_client_message_id).join(",")
    if (currentIds === incomingIds) {
      const sameProjection = JSON.stringify(app.pinnedMessages.items) === JSON.stringify(incomingItems)
      if (!sameProjection) {
        app.pinnedMessages = {...app.pinnedMessages, items: incomingItems}
        renderPinnedMessagesPanel()
        updatePinnedMarkers()
      }
      return
    }

    if (authoritative) {
      app.pinnedMessages = {
        conversationId,
        epochId: epochId || app.pinnedMessages.epochId,
        revision: incoming.revision,
        items: incomingItems
      }
      renderPinnedMessagesPanel()
      updatePinnedMarkers()
      return
    }

    if (!app.pinReconcileInFlight && app.conversation) {
      app.pinReconcileInFlight = true
      const lastSeq = app.lastSeenSequence || 0
      const reconcileConversationId = conversationId
      const reconcileEpochId = epochId
      push(app.conversation, "sync:reconcile", {last_applied_sequence: lastSeq})
        .then((res) => {
          if (res?.pins && pinnedMessagesScopeMatches(reconcileConversationId, reconcileEpochId)) {
            mergePinnedMessages(res.pins, {authoritative: true, conversationId: reconcileConversationId, epochId: reconcileEpochId})
          }
        })
        .catch(() => {})
        .finally(() => {
          if (pinnedMessagesScopeMatches(reconcileConversationId, reconcileEpochId)) {
            app.pinReconcileInFlight = false
          }
        })
    }
    return
  }

  app.pinnedMessages = {
    conversationId,
    epochId: epochId || app.pinnedMessages.epochId,
    revision: incoming.revision,
    items: incomingItems
  }

  renderPinnedMessagesPanel()
  updatePinnedMarkers()
}

function renderPinnedMessagesPanel() {
  const count = app.pinnedMessages.items.length
  const control = $("#pinned-messages-control")
  const countSpan = $("#pinned-count")
  const panel = $("#pinned-messages-panel")
  const list = $("#pinned-items-list")

  if (control && countSpan) {
    countSpan.textContent = count
    control.setAttribute("aria-label", `Pinned messages, ${count}`)
    if (count > 0) {
      control.removeAttribute("hidden")
      control.style.display = ""
    } else {
      control.setAttribute("hidden", "")
      control.style.display = "none"
      if (panel) {
        panel.setAttribute("hidden", "")
        panel.style.display = "none"
      }
    }
  }

  if (list) {
    list.replaceChildren()
    app.pinnedMessages.items.forEach((pin) => {
      const card = document.createElement("div")
      card.className = "pinned-card"
      card.dataset.pinnedTargetId = pin.target_client_message_id

      const header = document.createElement("div")
      header.className = "pinned-card-header"

      const authorSpan = document.createElement("span")
      authorSpan.className = "pinned-author-relation"
      authorSpan.textContent = pin.author_relation === "self" ? "You" : "Stranger"

      const unpinBtn = document.createElement("button")
      unpinBtn.type = "button"
      unpinBtn.className = "pinned-unpin-btn"
      unpinBtn.setAttribute("aria-label", "Unpin message")
      unpinBtn.textContent = "Unpin"
      unpinBtn.addEventListener("click", (e) => {
        e.stopPropagation()
        togglePinMessage(pin.target_client_message_id, false)
      })

      header.append(authorSpan, unpinBtn)

      const snippetP = document.createElement("p")
      snippetP.className = "pinned-snippet"
      snippetP.textContent = pin.snippet

      card.append(header, snippetP)

      card.addEventListener("click", () => {
        jumpToOriginalMessage(pin.target_client_message_id)
      })

      list.append(card)
    })
  }
}

function updatePinnedMarkers() {
  const pinnedIds = new Set(app.pinnedMessages.items.map((p) => p.target_client_message_id))
  document.querySelectorAll("#messages li.message").forEach((item) => {
    const msgId = item.dataset.messageId
    const isPinned = pinnedIds.has(msgId)
    const pinBtn = item.querySelector(".pin-action-btn")

    if (isPinned) {
      item.classList.add("is-pinned")
      if (pinBtn) {
        pinBtn.textContent = "Unpin"
        pinBtn.setAttribute("aria-label", "Unpin message")
      }
      if (!item.querySelector(".message-pinned-badge")) {
        const badge = document.createElement("span")
        badge.className = "message-pinned-badge"
        badge.setAttribute("aria-hidden", "true")
        badge.textContent = "📌"
        item.prepend(badge)
      }
    } else {
      item.classList.remove("is-pinned")
      if (pinBtn) {
        pinBtn.textContent = "Pin"
        pinBtn.setAttribute("aria-label", "Pin message")
      }
      const badge = item.querySelector(".message-pinned-badge")
      if (badge) badge.remove()
    }
  })
}

async function togglePinMessage(targetMessageId, desiredPinned) {
  if (app.pinMutationInFlight || !app.conversation) return
  const mutationConversationId = app.conversationId
  const mutationEpochId = app.currentEpochId
  if (!pinnedMessagesScopeMatches(mutationConversationId, mutationEpochId)) return
  app.pinMutationInFlight = true

  const expectedRevision = app.pinnedMessages.revision
  const payload = {
    target_client_message_id: targetMessageId,
    pinned: desiredPinned,
    expected_pin_revision: expectedRevision
  }

  try {
    const res = await push(app.conversation, "message:pin", payload)
    if (res && res.status) {
      if (res.status === "applied" || res.status === "already_canonical" || res.status === "stale_revision") {
        mergePinnedMessages({pins: res.pins, revision: res.revision}, {authoritative: true, conversationId: mutationConversationId, epochId: mutationEpochId})
      } else if (res.status === "target_absent") {
        announce("Original message isn't available to pin.")
      }
    }
  } catch (err) {
    if (err && (err.code === "PIN_LIMIT_REACHED" || err.reason === "pin_limit_reached")) {
      announce("Pin limit reached (maximum 3 pins).")
    }
  } finally {
    if (pinnedMessagesScopeMatches(mutationConversationId, mutationEpochId)) {
      app.pinMutationInFlight = false
    }
  }
}

function attachMessageGestures(item, messageId) {
  let startX = 0
  let startY = 0
  let longPressTimer = null
  let isTracking = false

  const clearTimer = () => {
    if (longPressTimer) {
      clearTimeout(longPressTimer)
      longPressTimer = null
    }
  }

  item.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse") return
    startX = e.clientX
    startY = e.clientY
    isTracking = true
    clearTimer()
    longPressTimer = setTimeout(() => {
      if (isTracking) {
        clearTimer()
        openReactionPicker(messageId, item)
      }
    }, LONG_PRESS_MS)
  }, {passive: true})

  item.addEventListener("pointermove", (e) => {
    if (!isTracking) return
    const dx = e.clientX - startX
    const dy = e.clientY - startY
    if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
      clearTimer()
    }
  }, {passive: true})

  item.addEventListener("pointerup", (e) => {
    if (!isTracking) return
    clearTimer()
    const dx = e.clientX - startX
    const dy = e.clientY - startY
    isTracking = false

    if (Math.abs(dx) >= SWIPE_REPLY_THRESHOLD_PX && Math.abs(dx) > Math.abs(dy) * 1.5) {
      startReplyCheck(messageId)
    }
  }, {passive: true})

  item.addEventListener("pointercancel", () => {
    isTracking = false
    clearTimer()
  }, {passive: true})
}

function renderMessage(message, mine) {
  const messageId = message.client_message_id || message.message_id
  if (app.rendered.has(messageId)) return
  const shouldFollow = mine || timelineNearBottom()
  renderMessageNode(message, mine, $("#messages"))
  requestAnimationFrame(() => {
    if (shouldFollow) scrollTimelineToNewest({smooth: true})
    else $("#new-messages").hidden = false
  })
  const sent_at = message.sent_at || now()
  const sequence = message.sequence || null
  const rawStatus = message.status || message.delivery_status || (mine ? "sending" : "delivered")
  const normStatus = rawStatus === "sent_to_server" ? "sent" : rawStatus
  const viewOnceState = message.view_once_state || (message.type === "view_once_photo" || message.type === "view_twice_photo" ? "unviewed" : null)
  const presentationLimit = Number.isInteger(message.presentation_limit) ? message.presentation_limit : (message.type === "view_twice_photo" ? 2 : (message.type === "view_once_photo" ? 1 : null))
  const viewsRemaining = Number.isInteger(message.views_remaining) ? message.views_remaining : (viewOnceState === "viewed" ? 0 : (viewOnceState === "viewed_once" ? 1 : presentationLimit))
  const viewsConsumed = Number.isInteger(message.views_consumed) ? message.views_consumed : (viewOnceState === "viewed" ? presentationLimit : (viewOnceState === "viewed_once" ? 1 : 0))
  return putRecord(localMessage({
    conversation_id: app.conversationId,
    client_message_id: messageId,
    message_id: messageId,
    type: message.type || (message.expressive ? "expressive" : "text"),
    content: message.content,
    expressive: message.expressive || null,
    mine,
    delivery_status: normStatus,
    sent_at,
    sequence,
    content_revision: message.content_revision || 0,
    peer_applied_content_revision: message.peer_applied_content_revision,
    edited: message.edited === true,
    availability: message.availability || (message.unsent ? "unsent" : "available"),
    unsent: message.unsent === true,
    reply_to_client_message_id: message.reply_to_client_message_id || null,
    reply_author_relation: message.reply_author_relation || null,
    reply_snippet: message.reply_snippet || null,
    reply_target_availability: message.reply_target_availability || null,
    self_reaction: message.self_reaction || null,
    peer_reaction: message.peer_reaction || null,
    view_once_state: viewOnceState,
    presentation_limit: presentationLimit,
    views_remaining: viewsRemaining,
    views_consumed: viewsConsumed,
    media_type: message.media_type || null,
    byte_size: message.byte_size || null
  })).catch(() => {})
}

function renderMessageNode(message, mine, container) {
  const messageId = message.client_message_id || message.message_id
  if (app.rendered.has(messageId)) return
  app.rendered.add(messageId)
  const item = document.createElement("li")
  item.className = `message${mine ? " mine" : ""}`
  item.dataset.messageId = messageId
  item.tabIndex = 0
  const terminalUnsent = message.availability === "unsent" || message.unsent === true
  if (terminalUnsent) app.messageAvailability.set(messageId, "unsent")
  if (terminalUnsent) item.classList.add("message-unsent")

  if (message.reply_to_client_message_id && message.reply_snippet) {
    const quote = document.createElement("div")
    quote.className = "reply-quote"
    quote.dataset.replyTo = message.reply_to_client_message_id
    quote.setAttribute("role", "button")
    quote.setAttribute("tabindex", "0")
    quote.setAttribute("aria-label", "Jump to quoted original message")

    const author = document.createElement("span")
    author.className = "reply-author"
    let authorLabel = "Stranger"
    if (mine) {
      authorLabel = message.reply_author_relation === "same_author" ? "You" : "Stranger"
    } else {
      authorLabel = message.reply_author_relation === "same_author" ? "Stranger" : "You"
    }
    author.textContent = `Replying to ${authorLabel}`

    const snippet = document.createElement("p")
    snippet.className = "reply-snippet"
    snippet.textContent = message.reply_snippet

    quote.append(author, snippet)
    item.append(quote)
  }

  if (message.type === "view_once_photo" || message.type === "view_twice_photo" || message.type === "view_once_video" || message.type === "view_twice_video") {
    item.classList.add("view-once-message")
    const isVideo = message.type === "view_once_video" || message.type === "view_twice_video" || message.media_type === "video/mp4"
    const presentationLimit = Number.isInteger(message.presentation_limit) ? message.presentation_limit : (message.type === "view_twice_photo" || message.type === "view_twice_video" ? 2 : 1)
    const viewOnceState = message.view_once_state || "unviewed"
    const viewsRemaining = Number.isInteger(message.views_remaining) ? message.views_remaining : (viewOnceState === "viewed" ? 0 : (viewOnceState === "viewed_once" ? 1 : presentationLimit))

    const card = document.createElement("div")
    card.className = `view-once-card view-once-${viewOnceState}`
    card.dataset.viewOnceState = viewOnceState
    card.dataset.presentationLimit = String(presentationLimit)
    card.dataset.viewsRemaining = String(viewsRemaining)
    card.dataset.mediaType = isVideo ? "video/mp4" : (message.media_type || "image/jpeg")

    const header = document.createElement("div")
    header.className = "view-once-header"
    const icon = document.createElement("span")
    icon.className = "view-once-icon"
    icon.textContent = isVideo ? "🎬" : "👁️"
    const title = document.createElement("span")
    title.textContent = isVideo ? (presentationLimit === 2 ? "View-twice video" : "View-once video") : (presentationLimit === 2 ? "View-twice photo" : "View-once photo")
    header.append(icon, title)
    card.append(header)

    if (viewOnceState === "unavailable") {
      const statusText = document.createElement("span")
      statusText.className = "view-once-status"
      statusText.textContent = "Unavailable"
      card.append(statusText)
    } else if (viewOnceState === "viewed" || viewsRemaining === 0) {
      const statusText = document.createElement("span")
      statusText.className = "view-once-status"
      statusText.textContent = isVideo ? (presentationLimit === 2 ? "Opened (2 of 2)" : "Viewed") : (presentationLimit === 2 ? "Opened (2 of 2)" : "Opened")
      card.append(statusText)
    } else if (presentationLimit === 2 && viewsRemaining === 1) {
      if (mine) {
        const statusText = document.createElement("span")
        statusText.className = "view-once-status"
        statusText.textContent = "Opened once · 1 view remaining"
        card.append(statusText)
      } else {
        const openBtn = document.createElement("button")
        openBtn.type = "button"
        openBtn.className = "view-once-open-btn"
        openBtn.textContent = "Open again (1 view remaining)"
        openBtn.setAttribute("aria-label", isVideo ? "Open video again. 1 view remaining." : "Open photo again. 1 view remaining.")
        openBtn.addEventListener("click", (e) => {
          e.stopPropagation()
          openViewOncePhoto(messageId, openBtn)
        })
        card.append(openBtn)
      }
    } else {
      if (mine) {
        const statusText = document.createElement("span")
        statusText.className = "view-once-status"
        statusText.textContent = isVideo ? (presentationLimit === 2 ? "Sent · 2 views available" : "Sent · Unopened") : (presentationLimit === 2 ? "Sent · 2 views available" : "Sent · Unopened")
        card.append(statusText)
      } else {
        const openBtn = document.createElement("button")
        openBtn.type = "button"
        openBtn.className = "view-once-open-btn"
        openBtn.textContent = isVideo ? (presentationLimit === 2 ? "Open (1 of 2)" : "Open once") : (presentationLimit === 2 ? "Open (1 of 2)" : "Open once")
        openBtn.setAttribute("aria-label", isVideo ? (presentationLimit === 2 ? "Open video. 2 views remaining." : "Open once. Opening uses your one view.") : (presentationLimit === 2 ? "Open photo. 2 views remaining." : "Open once. Opening uses your one view."))
        openBtn.addEventListener("click", (e) => {
          e.stopPropagation()
          openViewOncePhoto(messageId, openBtn)
        })
        card.append(openBtn)
      }
    }
    item.append(card)

    if (container.id === "messages" && !mine) {
      const actionsBar = document.createElement("div")
      actionsBar.className = "message-actions-bar"
      installReportAction(actionsBar, messageId)
      item.append(actionsBar)
    }

    container.append(item)
    return
  }

  if (message.type === "expressive" || message.expressive) {
    item.classList.add("expressive-message")
    const media = message.expressive || {}
    const figure = document.createElement("figure")
    const img = document.createElement("img")
    img.src = media.asset_path || ""
    img.alt = media.label || "Expressive media"
    img.loading = "lazy"
    img.decoding = "async"
    if (media.kind === "loop") img.classList.add("expressive-loop")
    img.addEventListener("error", () => {
      figure.classList.add("expressive-unavailable")
      figure.replaceChildren(Object.assign(document.createElement("span"), {textContent: "Expressive media unavailable"}))
    }, {once: true})
    figure.append(img)
    item.append(figure)
  } else {
    const content = document.createElement("span")
    content.className = "message-content"
    content.textContent = terminalUnsent ? "Message unsent" : message.content
    item.append(content)

    const edited = document.createElement("span")
    edited.className = "message-edited"
    edited.textContent = "Edited"
    edited.hidden = terminalUnsent || !(message.edited === true || (message.content_revision || 0) > 0)
    item.append(edited)
  }

  const reactionsContainer = document.createElement("div")
  reactionsContainer.className = "message-reactions"
  reactionsContainer.dataset.reactionsFor = messageId
  item.append(reactionsContainer)

  if (mine && container.id !== "history-messages") {
    const rawStatus = message.delivery_status || message.status || "sending"
    const statusText = rawStatus === "sent_to_server" ? "sent" : rawStatus
    const status = document.createElement("small")
    status.className = "message-status"
    status.textContent = messageStatusText(message, statusText)
    item.append(status)
  }

  if (container.id === "messages" && !terminalUnsent) {
    const actionsBar = document.createElement("div")
    actionsBar.className = "message-actions-bar"

    const reactBtn = document.createElement("button")
    reactBtn.type = "button"
    reactBtn.className = "message-action-btn react-action-btn"
    reactBtn.setAttribute("aria-label", "React to message")
    reactBtn.textContent = "😊"
    reactBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      openReactionPicker(messageId, item)
    })

    const replyBtn = document.createElement("button")
    replyBtn.type = "button"
    replyBtn.className = "message-action-btn reply-action-btn"
    replyBtn.setAttribute("aria-label", "Reply to message")
    replyBtn.textContent = "Reply"
    replyBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      startReplyCheck(messageId)
    })

    const isPinned = app.pinnedMessages.items.some((p) => p.target_client_message_id === messageId)
    const pinBtn = document.createElement("button")
    pinBtn.type = "button"
    pinBtn.className = "message-action-btn pin-action-btn"
    pinBtn.setAttribute("aria-label", isPinned ? "Unpin message" : "Pin message")
    pinBtn.textContent = isPinned ? "Unpin" : "Pin"
    pinBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      const currentlyPinned = app.pinnedMessages.items.some((p) => p.target_client_message_id === messageId)
      togglePinMessage(messageId, !currentlyPinned)
    })

    const copyBtn = document.createElement("button")
    copyBtn.type = "button"
    copyBtn.className = "message-action-btn copy-action-btn"
    copyBtn.setAttribute("aria-label", "Copy message text")
    copyBtn.textContent = "Copy"
    copyBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      copyCurrentMessage(messageId)
    })

    actionsBar.append(reactBtn, replyBtn, pinBtn)
    if (message.type !== "expressive" && !message.expressive) {
      actionsBar.append(copyBtn)

      const reflectBtn = document.createElement("button")
      reflectBtn.type = "button"
      reflectBtn.className = "message-action-btn reflect-action-btn"
      reflectBtn.setAttribute("aria-label", "Reflect on message")
      reflectBtn.textContent = "📝"
      reflectBtn.addEventListener("click", (e) => {
        e.stopPropagation()
        openReflectionComposerForMessage(message)
      })
      actionsBar.append(reflectBtn)
    }
    if (!mine && message.type !== "expressive" && !message.expressive) installReportAction(actionsBar, messageId)

    if (mine && message.type !== "expressive" && !message.expressive && ["sent", "delivered", "sent_to_server"].includes(message.delivery_status || message.status)) {
      installEditAction(item, messageId)
      installUnsendAction(item, messageId)
    }
    item.append(actionsBar)

    if (isPinned) {
      item.classList.add("is-pinned")
      const badge = document.createElement("span")
      badge.className = "message-pinned-badge"
      badge.setAttribute("aria-hidden", "true")
      badge.textContent = "📌"
      item.prepend(badge)
    }

    attachMessageGestures(item, messageId)
  }

  if (container.id === "messages" && terminalUnsent && !mine) {
    const actionsBar = document.createElement("div")
    actionsBar.className = "message-actions-bar"
    installReportAction(actionsBar, messageId)
    item.append(actionsBar)
  }

  container.append(item)
  updateMessageReactionsDisplay(messageId, message.self_reaction, message.peer_reaction, undefined)
}

function messageStatusText(message, fallbackStatus = "sent") {
  if (message?.availability === "unsent" || message?.unsent === true) return fallbackStatus
  const revision = Number.isInteger(message?.content_revision) ? message.content_revision : 0
  if (revision <= 0) return fallbackStatus
  const applied = message?.peer_applied_content_revision
  const latest = Number.isInteger(applied) && applied >= revision ? "Delivered" : "Sent"
  return `Edited · ${latest}`
}

function queueMessageRecordUpdate(messageId, update) {
  const previous = app.messageRecordUpdates.get(messageId) || Promise.resolve()
  const next = previous.catch(() => {}).then(update)
  app.messageRecordUpdates.set(messageId, next)
  next.finally(() => {
    if (app.messageRecordUpdates.get(messageId) === next) app.messageRecordUpdates.delete(messageId)
  }).catch(() => {})
  return next
}

function installEditAction(item, messageId) {
  const actionsBar = item?.querySelector(".message-actions-bar")
  if (!actionsBar || actionsBar.querySelector(".edit-action-btn")) return
  const editBtn = document.createElement("button")
  editBtn.type = "button"
  editBtn.className = "message-action-btn edit-action-btn"
  editBtn.setAttribute("aria-label", "Edit message")
  editBtn.textContent = "Edit"
  editBtn.addEventListener("click", (event) => {
    event.stopPropagation()
    beginMessageEdit(messageId, editBtn)
  })
  actionsBar.append(editBtn)
}

function installUnsendAction(item, messageId) {
  const actionsBar = item?.querySelector(".message-actions-bar")
  if (!actionsBar || actionsBar.querySelector(".unsend-action-btn")) return
  const unsendBtn = document.createElement("button")
  unsendBtn.type = "button"
  unsendBtn.className = "message-action-btn unsend-action-btn"
  unsendBtn.setAttribute("aria-label", "Unsend message")
  unsendBtn.textContent = "Unsend"
  unsendBtn.addEventListener("click", (event) => {
    event.stopPropagation()
    beginMessageUnsend(messageId, unsendBtn)
  })
  actionsBar.append(unsendBtn)
}

function installReportAction(actionsBar, messageId) {
  if (!actionsBar || actionsBar.querySelector(".report-message-action-btn")) return
  const reportBtn = document.createElement("button")
  reportBtn.type = "button"
  reportBtn.className = "message-action-btn report-message-action-btn"
  reportBtn.setAttribute("aria-label", "Report this message")
  reportBtn.textContent = "Report"
  reportBtn.addEventListener("click", (event) => {
    event.stopPropagation()
    openReportForm({targetMessageId: messageId, trigger: reportBtn})
  })
  actionsBar.append(reportBtn)
}

function updateMessageVisual(record) {
  const messageId = record?.value?.client_message_id || record?.value?.message_id
  if (!messageId) return
  const item = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`)
  if (!item) return
  const terminalUnsent = record.value.availability === "unsent" || record.value.unsent === true
  item.classList.toggle("message-unsent", terminalUnsent)
  const content = item.querySelector(":scope > .message-content")
  if (content) content.textContent = terminalUnsent ? "Message unsent" : record.value.content
  const edited = item.querySelector(":scope > .message-edited")
  if (edited) edited.hidden = terminalUnsent || !(record.value.edited || (record.value.content_revision || 0) > 0)
  const status = item.querySelector(":scope > .message-status")
  if (status) status.textContent = messageStatusText(record.value, record.value.delivery_status || "sent")
  if (terminalUnsent) {
    item.querySelector(":scope > .message-reactions")?.replaceChildren()
    item.querySelector(":scope > .message-actions-bar")?.remove()
    app.reactionAuthority.set(messageId, "frozen")
    if (app.activeReactionPickerTarget === messageId) closeReactionPicker()
    if (!record.value.mine) {
      const actionsBar = document.createElement("div")
      actionsBar.className = "message-actions-bar"
      installReportAction(actionsBar, messageId)
      item.append(actionsBar)
    }
  } else if (record.value.mine && record.value.type === "text" && ["sent", "delivered"].includes(record.value.delivery_status)) {
    installEditAction(item, messageId)
    installUnsendAction(item, messageId)
  }
  if (app.messageEdit?.messageId === messageId) {
    const current = item.querySelector(".edit-canonical-current")
    if (current) current.textContent = `Current message: ${record.value.content}`
  }
}

async function copyCurrentMessage(messageId) {
  const record = await getRecord(`message:${app.conversationId}:${messageId}`)
  if (!record || record.value.type !== "text" || record.value.availability === "unsent" || record.value.unsent === true || typeof record.value.content !== "string") return
  try {
    await navigator.clipboard.writeText(record.value.content)
    announce("Message copied.")
  } catch (_error) {
    announce("Could not copy this message.")
  }
}

async function beginMessageUnsend(messageId, trigger) {
  const record = await getRecord(`message:${app.conversationId}:${messageId}`)
  if (!record || !record.value.mine || record.value.type !== "text" || record.value.availability === "unsent" || record.value.unsent === true || !["sent", "delivered"].includes(record.value.delivery_status)) return
  closeMessageUnsend({restoreFocus: false})
  app.messageUnsend = {
    messageId,
    expectedRevision: record.value.content_revision || 0,
    trigger,
    submitting: false
  }
  $("#unsend-confirm").disabled = false
  const backdrop = $("#unsend-confirmation-backdrop")
  backdrop.hidden = false
  $("#unsend-confirm")?.focus()
}

function closeMessageUnsend({restoreFocus = true} = {}) {
  const pending = app.messageUnsend
  $("#unsend-confirmation-backdrop").hidden = true
  $("#unsend-confirm").disabled = false
  app.messageUnsend = null
  if (restoreFocus) pending?.trigger?.focus()
}

async function confirmMessageUnsend() {
  const pending = app.messageUnsend
  if (!pending || pending.submitting || !app.conversation) return
  pending.submitting = true
  $("#unsend-confirm").disabled = true
  try {
    const result = await push(app.conversation, "message:unsend", {
      target_client_message_id: pending.messageId,
      expected_content_revision: pending.expectedRevision
    })
    if (result.status === "stale") {
      await applyCanonicalMessageRevision(result, {source: "stale"})
      closeMessageUnsend()
      announce("This message changed elsewhere and was not unsent. Choose Unsend again to review the current message.")
      return
    }
    if (result.status === "absent_from_authority") {
      closeMessageUnsend()
      announce("This message is no longer available to unsend.")
      return
    }
    if (result.status === "unavailable") {
      closeMessageUnsend()
      announce("This message is no longer available to unsend.")
      return
    }
    if (["applied", "already_canonical"].includes(result.status)) {
      await applyCanonicalMessageUnsent(result, {source: "reply"})
      closeMessageUnsend()
      announce("Message unsent.")
    }
  } catch (error) {
    pending.submitting = false
    $("#unsend-confirm").disabled = false
    handleDomainError(error, {fallbackMessage: "Could not unsend this message. Please try again."})
  }
}

async function beginMessageEdit(messageId, trigger) {
  const record = await getRecord(`message:${app.conversationId}:${messageId}`)
  if (!record || !record.value.mine || record.value.type !== "text" || record.value.availability === "unsent" || record.value.unsent === true || !["sent", "delivered"].includes(record.value.delivery_status)) return
  cancelMessageEdit({restoreFocus: false})
  const item = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`)
  if (!item) return

  const form = document.createElement("form")
  form.className = "message-edit-form"
  form.setAttribute("aria-label", "Editing message")

  const canonical = document.createElement("p")
  canonical.className = "edit-canonical-current"
  canonical.textContent = `Current message: ${record.value.content}`

  const label = document.createElement("label")
  label.textContent = "Edit message text"
  const textarea = document.createElement("textarea")
  textarea.value = record.value.content
  textarea.maxLength = 16384
  label.append(textarea)

  const conflict = document.createElement("p")
  conflict.className = "message-edit-conflict"
  conflict.setAttribute("role", "status")
  conflict.hidden = true

  const actions = document.createElement("div")
  actions.className = "message-edit-actions"
  const save = document.createElement("button")
  save.type = "submit"
  save.className = "primary"
  save.textContent = "Save"
  const cancel = document.createElement("button")
  cancel.type = "button"
  cancel.textContent = "Cancel"
  cancel.addEventListener("click", () => cancelMessageEdit())
  actions.append(save, cancel)
  form.append(canonical, label, conflict, actions)
  item.insertBefore(form, item.querySelector(".message-reactions"))

  app.messageEdit = {
    messageId,
    expectedRevision: record.value.content_revision || 0,
    attemptedContent: textarea.value,
    trigger,
    form,
    textarea,
    saving: false,
    submittedContent: null
  }
  form.addEventListener("submit", (event) => {
    event.preventDefault()
    saveMessageEdit()
  })
  textarea.addEventListener("input", () => {
    if (app.messageEdit?.messageId === messageId) app.messageEdit.attemptedContent = textarea.value
  })
  textarea.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault()
      cancelMessageEdit()
    }
  })
  textarea.focus()
  textarea.select()
}

function cancelMessageEdit({restoreFocus = true} = {}) {
  const editing = app.messageEdit
  if (!editing) return
  editing.form?.remove()
  app.messageEdit = null
  if (restoreFocus) editing.trigger?.focus()
}

function showMessageEditConflict(messageId) {
  if (app.messageEdit?.messageId !== messageId) return
  const conflict = app.messageEdit.form?.querySelector(".message-edit-conflict")
  if (conflict) {
    conflict.hidden = false
    conflict.textContent = "This message changed elsewhere. Your attempted edit is preserved. Cancel and choose Edit again to make a fresh change."
  }
  app.messageEdit.saving = false
  app.messageEdit.form?.querySelector('button[type="submit"]')?.removeAttribute("disabled")
  announce("Message changed elsewhere. Your attempted edit is still available for review.")
}

async function saveMessageEdit() {
  const editing = app.messageEdit
  if (!editing || editing.saving || !app.conversation) return
  const content = editing.textarea.value.trim()
  editing.attemptedContent = editing.textarea.value
  if (!content) {
    announce("An edited message cannot be blank.")
    return
  }
  editing.saving = true
  editing.submittedContent = content
  editing.form.querySelector('button[type="submit"]')?.setAttribute("disabled", "")

  try {
    const result = await push(app.conversation, "message:edit", {
      target_client_message_id: editing.messageId,
      expected_content_revision: editing.expectedRevision,
      content
    })
    if (result.status === "stale") {
      await applyCanonicalMessageRevision(result, {source: "stale"})
      showMessageEditConflict(editing.messageId)
      return
    }
    if (["absent_from_authority", "unavailable"].includes(result.status)) {
      editing.saving = false
      editing.form.querySelector('button[type="submit"]')?.removeAttribute("disabled")
      announce("This message is no longer available to edit. Your attempted edit is preserved.")
      return
    }
    if (["applied", "already_canonical", "no_op"].includes(result.status)) {
      await applyCanonicalMessageRevision(result, {source: "reply"})
      cancelMessageEdit()
      announce(result.status === "no_op" ? "Message unchanged." : "Message edited.")
    }
  } catch (error) {
    if (app.messageEdit?.messageId === editing.messageId) {
      editing.saving = false
      editing.form.querySelector('button[type="submit"]')?.removeAttribute("disabled")
    }
    handleDomainError(error, {fallbackMessage: "Could not edit this message. Your attempted edit is preserved."})
  }
}

async function acknowledgeContentRevision(messageId, contentRevision, attemptsRemaining = 1) {
  if (!app.conversation || !app.currentEpochId || !Number.isInteger(contentRevision)) return
  try {
    await push(app.conversation, "content:applied", {
      epoch_id: app.currentEpochId,
      target_client_message_id: messageId,
      content_revision: contentRevision
    })
  } catch (_error) {
    if (attemptsRemaining > 0) setTimeout(() => acknowledgeContentRevision(messageId, contentRevision, attemptsRemaining - 1), 500)
  }
}

async function reconcileMessageContent() {
  if (!app.conversation || app.messageContentReconcileInFlight) return
  app.messageContentReconcileInFlight = true
  try {
    const result = await push(app.conversation, "sync:reconcile", {
      last_applied_sequence: app.deliveryProgress.contiguous
    })
    await applySyncPayload(app.conversationId, {
      ...result,
      status: "catch_up_complete",
      latest_sequence: result.through_sequence,
      baseline_sequence: result.from_sequence
    })
  } catch (_error) {
    return
  } finally {
    app.messageContentReconcileInFlight = false
  }
}

async function applyCanonicalMessageRevision(message, {source = "live"} = {}) {
  if (app.currentEpochId && message?.epoch_id && message.epoch_id !== app.currentEpochId) return "ignored_epoch"
  const messageId = message?.client_message_id || message?.message_id
  const terminalUnsent = message?.availability === "unsent" || message?.unsent === true
  const referenceReason = app.messageAvailability.get(message?.reply_to_client_message_id)
  const canonicalMessage = referenceReason ? {
    ...message,
    reply_snippet: referenceReason === "unsent" ? "Unsent message" : "Message unavailable",
    reply_target_availability: referenceReason
  } : message
  if (!messageId || !Number.isInteger(canonicalMessage.content_revision) || (!terminalUnsent && typeof canonicalMessage.content !== "string")) return "invalid"
  const id = `message:${app.conversationId}:${messageId}`
  const merged = await queueMessageRecordUpdate(messageId, async () => {
    const record = await getRecord(id)
    if (!record) return {status: "absent", record: null}
    const result = mergeMessageContent(record, canonicalMessage, now())
    if (!["invalid", "ignored_older", "equal_revision_conflict"].includes(result.status)) {
      if (result.record !== record) await putRecord(result.record)
      updateMessageVisual(result.record)
    }
    return result
  })
  if (merged.status === "equal_revision_conflict") {
    if (source !== "sync") reconcileMessageContent()
    return merged.status
  }
  if (["invalid", "ignored_older", "ignored_terminal", "absent"].includes(merged.status)) return merged.status

  if (terminalUnsent) {
    app.messageAvailability.set(messageId, "unsent")
    await sanitizeLocalReplyReferences(messageId, "unsent")
    if (app.messageEdit?.messageId === messageId) {
      app.messageEdit.saving = false
      app.messageEdit.form?.querySelector('button[type="submit"]')?.removeAttribute("disabled")
      const conflict = app.messageEdit.form?.querySelector(".message-edit-conflict")
      if (conflict) {
        conflict.hidden = false
        conflict.textContent = "This message was unsent. Your attempted edit is preserved, but it cannot be saved."
      }
    }
    return merged.status
  }

  const editing = app.messageEdit
  if (editing?.messageId === messageId && message.content_revision > editing.expectedRevision) {
    const ownAccepted = editing.saving && message.content_revision === editing.expectedRevision + 1 && message.content === editing.submittedContent
    if (!ownAccepted) showMessageEditConflict(messageId)
  }
  if (!merged.record.value.mine) acknowledgeContentRevision(messageId, message.content_revision)
  return merged.status
}

async function applyCanonicalMessageUnsent(message, options = {}) {
  const messageId = message?.client_message_id || message?.message_id
  if (messageId && !app.rendered.has(messageId)) {
    await renderMessage(
      {...message, availability: "unsent", unsent: true},
      message.mine === true || message.sender_id === app.identity?.participant_id
    )
  }
  return applyCanonicalMessageRevision(
    {...message, availability: "unsent", unsent: true},
    options
  )
}

async function updateMessageContentStatus(payload) {
  if (payload?.epoch_id && app.currentEpochId && payload.epoch_id !== app.currentEpochId) return
  const messageId = payload?.client_message_id || payload?.message_id
  if (!messageId || !Number.isInteger(payload.peer_applied_content_revision)) return
  const id = `message:${app.conversationId}:${messageId}`
  return queueMessageRecordUpdate(messageId, async () => {
    const record = await getRecord(id)
    if (!record) return
    const current = Number.isInteger(record.value.peer_applied_content_revision) ? record.value.peer_applied_content_revision : -1
    if (payload.peer_applied_content_revision < current) return
    const updated = {
      ...record,
      value: {...record.value, peer_applied_content_revision: payload.peer_applied_content_revision},
      updated_at: now()
    }
    await putRecord(updated)
    updateMessageVisual(updated)
  })
}

function updateMessageStatus(statusPayload) {
  if (statusPayload?.epoch_id && app.currentEpochId && statusPayload.epoch_id !== app.currentEpochId) return
  const messageId = statusPayload?.client_message_id || statusPayload?.message_id
  const rawStatus = statusPayload?.status
  const nextStatus = rawStatus === "sent_to_server" ? "sent" : rawStatus
  const sequence = statusPayload?.sequence || null
  if (!messageId || !nextStatus) return

  const id = `message:${app.conversationId}:${messageId}`
  return queueMessageRecordUpdate(messageId, async () => {
    const record = await getRecord(id)
    if (!record) return
    const currentStatus = record.value.delivery_status || "sending"
    if (!isValidStatusTransition(currentStatus, nextStatus)) return

    const updatedValue = {...record.value, delivery_status: nextStatus}
    const node = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`)
    if (nextStatus === "failed" && record.value.type === "expressive" && node) {
      node.classList.add("expressive-rejected")
      node.querySelector("figure")?.replaceChildren(Object.assign(document.createElement("span"), {textContent: "Expressive message not sent"}))
    }
    if (sequence) updatedValue.sequence = sequence
    const updated = {...record, value: updatedValue, updated_at: now()}
    updateMessageVisual(updated)
    await putRecord(updated)
  }).catch(() => {})
}

function renderVoiceNoteNode(note, container, historical) {
  if (app.rendered.has(note.voice_note_id)) return
  app.rendered.add(note.voice_note_id)
  const item = document.createElement("li"); item.className = `message voice-note${note.mine ? " mine" : ""}`; item.dataset.voiceNoteId = note.voice_note_id
  const label = document.createElement("strong"); label.textContent = "Voice note"
  const audio = document.createElement("audio"); audio.controls = true; audio.preload = "metadata"; audio.autoplay = false
  audio.setAttribute("aria-label", "Voice note playback")
  releaseVoiceUrl(note.voice_note_id)
  const url = URL.createObjectURL(note.blob); app.voiceUrls.set(note.voice_note_id, url); audio.src = url
  const player = createVoicePlayerControls(audio, note.duration_ms)
  item.append(label, audio, player)
  if (historical) { const copy = document.createElement("span"); copy.className = "local-voice-copy"; copy.textContent = "This voice note is stored on this device as part of your local Conversation copy."; item.append(copy) }
  else if (note.mine) { const status = document.createElement("small"); status.textContent = note.delivery_status || "sent_to_server"; item.append(status) }
  container.append(item)
}

function createVoicePlayerControls(audio, declaredDurationMs = 0) {
  const controls = document.createElement("div")
  controls.className = "voice-player-controls"
  const waveform = document.createElement("div")
  waveform.className = "voice-waveform"
  waveform.setAttribute("aria-hidden", "true")
  for (let i = 0; i < 18; i++) waveform.append(document.createElement("i"))
  const seek = document.createElement("input")
  seek.type = "range"; seek.min = "0"; seek.max = "1000"; seek.value = "0"; seek.step = "1"
  seek.setAttribute("aria-label", "Voice note position")
  const position = document.createElement("output")
  position.className = "voice-position"
  position.setAttribute("aria-live", "off")
  position.textContent = `0:00 / ${formatVoiceTime(declaredDurationMs / 1000)}`
  const speed = document.createElement("button")
  speed.type = "button"; speed.className = "voice-speed"; speed.textContent = "1×"
  speed.setAttribute("aria-label", "Playback speed 1 times")
  const failure = document.createElement("span")
  failure.className = "voice-playback-failure"; failure.setAttribute("role", "status"); failure.hidden = true
  failure.textContent = "Voice note playback is unavailable. The message is still here."

  const update = () => {
    const duration = Number.isFinite(audio.duration) ? audio.duration : declaredDurationMs / 1000
    const current = Number.isFinite(audio.currentTime) ? audio.currentTime : 0
    seek.value = duration > 0 ? String(Math.round((current / duration) * 1000)) : "0"
    position.textContent = `${formatVoiceTime(current)} / ${formatVoiceTime(duration)}`
    waveform.style.setProperty("--voice-progress", `${duration > 0 ? (current / duration) * 100 : 0}%`)
  }
  audio.addEventListener("loadedmetadata", update)
  audio.addEventListener("timeupdate", update)
  audio.addEventListener("play", () => updateExplicitVoiceConflict(audio, true))
  audio.addEventListener("pause", () => updateExplicitVoiceConflict(audio, false))
  audio.addEventListener("ended", () => updateExplicitVoiceConflict(audio, false))
  audio.addEventListener("error", () => { failure.hidden = false; updateExplicitVoiceConflict(audio, false) })
  seek.addEventListener("input", () => {
    if (Number.isFinite(audio.duration) && audio.duration > 0) audio.currentTime = (Number(seek.value) / 1000) * audio.duration
    update()
  })
  speed.addEventListener("click", () => {
    audio.playbackRate = nextPlaybackRate(audio.playbackRate)
    speed.textContent = `${audio.playbackRate}×`
    speed.setAttribute("aria-label", `Playback speed ${audio.playbackRate} times`)
  })
  controls.append(waveform, seek, position, speed, failure)
  return controls
}

async function receiveVoiceNote(note, runtime = null) {
  const conversationId = runtime?.conversationId || app.conversationId
  const channel = runtime?.channel || app.conversation
  const runtimeIsCurrent = runtime?.isCurrent || (() => app.conversationId === conversationId && app.conversation === channel)
  if (!runtimeIsCurrent()) return
  if (note?.epoch_id && app.currentEpochId && note.epoch_id !== app.currentEpochId) return
  const shouldFollow = timelineNearBottom()
  const id = `voice:${conversationId}:${note.voice_note_id}`
  const existing = await getRecord(id)
  if (!runtimeIsCurrent()) return
  if (existing?.value.blob) {
    renderVoiceNoteNode(existing.value, $("#messages"), false)
    await push(channel, "voice_note:ack", {voice_note_id: note.voice_note_id})
    return
  }

  try {
    const response = await fetch(`/api/conversations/${conversationId}/voice-notes/${note.voice_note_id}`, {headers: {authorization: `Bearer ${app.identity.token}`}})
    if (!runtimeIsCurrent()) return
    if (!response.ok) throw new Error("download_failed")
    const blob = await response.blob()
    if (!runtimeIsCurrent()) return
    if (!validVoiceBlob(blob)) throw new Error("invalid_voice_note")
    const record = localVoiceNote({conversation_id: conversationId, voice_note_id: note.voice_note_id, blob, mine: false, delivery_status: "delivered", sent_at: note.timestamp, sequence: note.sequence, duration_ms: note.duration_ms, byte_size: note.byte_size, media_type: note.media_type})
    try { await putRecord(record) } catch { if (runtimeIsCurrent()) announce("Voice note received, but it may not survive refresh because local storage is unavailable.") }
    if (!runtimeIsCurrent()) return
    renderVoiceNoteNode(record.value, $("#messages"), false)
    requestAnimationFrame(() => { if (!runtimeIsCurrent()) return; if (shouldFollow) scrollTimelineToNewest({smooth: true}); else $("#new-messages").hidden = false })
    await push(channel, "voice_note:ack", {voice_note_id: note.voice_note_id})
  } catch { if (runtimeIsCurrent()) announce("A voice note could not be downloaded before it expired.") }
}

function updateVoiceNoteStatus({voice_note_id, status, epoch_id}) {
  if (epoch_id && app.currentEpochId && epoch_id !== app.currentEpochId) return
  document.querySelector(`[data-voice-note-id="${CSS.escape(voice_note_id)}"] small`)?.replaceChildren(document.createTextNode(status))
  const id = `voice:${app.conversationId}:${voice_note_id}`
  getRecord(id).then((record) => record && putRecord({...record, value: {...record.value, delivery_status: status}, updated_at: now()})).catch(() => {})
}

// --- Feature 1O: View-Once Media ---
app.viewOnce = {
  activeBlob: null,
  previewUrl: null,
  draft: null
}

let activeViewOnceUrl = null
let activeViewOnceTrigger = null

function updateViewOnceState(clientMessageId, state, viewsRemaining, presentationLimit) {
  const node = document.querySelector(`[data-message-id="${CSS.escape(clientMessageId)}"]`)
  if (node) {
    const card = node.querySelector(".view-once-card")
    if (card) {
      const isVideo = card.dataset.mediaType === "video/mp4" || node.classList.contains("view-once-video")
      const limit = Number.isInteger(presentationLimit) ? presentationLimit : (parseInt(card.dataset.presentationLimit, 10) || 1)
      const remaining = Number.isInteger(viewsRemaining) ? viewsRemaining : (state === "viewed" ? 0 : (state === "viewed_once" ? 1 : limit))
      card.className = `view-once-card view-once-${state}`
      card.dataset.viewOnceState = state
      card.dataset.presentationLimit = String(limit)
      card.dataset.viewsRemaining = String(remaining)

      const oldStatus = card.querySelector(".view-once-status")
      const oldBtn = card.querySelector(".view-once-open-btn")
      if (oldBtn) oldBtn.remove()
      if (oldStatus) oldStatus.remove()

      const isMine = node.classList.contains("mine")

      if (state === "unavailable") {
        const statusText = document.createElement("span")
        statusText.className = "view-once-status"
        statusText.textContent = "Unavailable"
        card.append(statusText)
      } else if (state === "viewed" || remaining === 0) {
        const statusText = document.createElement("span")
        statusText.className = "view-once-status"
        statusText.textContent = isVideo ? (limit === 2 ? "Opened (2 of 2)" : "Viewed") : (limit === 2 ? "Opened (2 of 2)" : "Opened")
        card.append(statusText)
      } else if (limit === 2 && remaining === 1) {
        if (isMine) {
          const statusText = document.createElement("span")
          statusText.className = "view-once-status"
          statusText.textContent = "Opened once · 1 view remaining"
          card.append(statusText)
        } else {
          const openBtn = document.createElement("button")
          openBtn.type = "button"
          openBtn.className = "view-once-open-btn"
          openBtn.textContent = "Open again (1 view remaining)"
          openBtn.setAttribute("aria-label", isVideo ? "Open video again. 1 view remaining." : "Open photo again. 1 view remaining.")
          openBtn.addEventListener("click", (e) => {
            e.stopPropagation()
            openViewOncePhoto(clientMessageId, openBtn)
          })
          card.append(openBtn)
        }
      } else {
        if (isMine) {
          const statusText = document.createElement("span")
          statusText.className = "view-once-status"
          statusText.textContent = isVideo ? (limit === 2 ? "Sent · 2 views available" : "Sent · Unopened") : (limit === 2 ? "Sent · 2 views available" : "Sent · Unopened")
          card.append(statusText)
        } else {
          const openBtn = document.createElement("button")
          openBtn.type = "button"
          openBtn.className = "view-once-open-btn"
          openBtn.textContent = isVideo ? (limit === 2 ? "Open (1 of 2)" : "Open once") : (limit === 2 ? "Open (1 of 2)" : "Open once")
          openBtn.setAttribute("aria-label", isVideo ? (limit === 2 ? "Open video. 2 views remaining." : "Open once. Opening uses your one view.") : (limit === 2 ? "Open photo. 2 views remaining." : "Open once. Opening uses your one view."))
          openBtn.addEventListener("click", (e) => {
            e.stopPropagation()
            openViewOncePhoto(clientMessageId, openBtn)
          })
          card.append(openBtn)
        }
      }
    }
  }

  queueMessageRecordUpdate(clientMessageId, async () => {
    const key = `message:${app.conversationId}:${clientMessageId}`
    const record = await getRecord(key)
    if (record && record.value) {
      record.value.view_once_state = state
      if (Number.isInteger(viewsRemaining)) record.value.views_remaining = viewsRemaining
      if (Number.isInteger(presentationLimit)) record.value.presentation_limit = presentationLimit
      await putRecord({...record, updated_at: now()})
    }
  })
}

async function openViewOncePhoto(clientMessageId, triggerBtn, attemptId) {
  if (!app.conversation || !app.conversationId) return
  if (triggerBtn) triggerBtn.disabled = true

  const attempt = attemptId || crypto.randomUUID()

  try {
    const resp = await push(app.conversation, "view_once:open", {
      target_client_message_id: clientMessageId,
      client_message_id: clientMessageId,
      attempt_id: attempt
    })

    if (resp?.presentation_token) {
      const token = app.identity?.token || ""
      const url = `/api/conversations/${app.conversationId}/view-once/${clientMessageId}?token=${encodeURIComponent(resp.presentation_token)}`
      const fetchResp = await fetch(url, {
        headers: {
          "Authorization": `Bearer ${token}`
        }
      })

      if (!fetchResp.ok) {
        throw new Error("presentation_fetch_failed")
      }

      const blob = await fetchResp.blob()
      const objectUrl = URL.createObjectURL(blob)
      showViewOnceModal(
        objectUrl,
        triggerBtn,
        clientMessageId,
        resp.view_once_state || resp.status || "viewed",
        resp.views_remaining,
        resp.presentation_limit,
        resp.media_type || blob.type
      )
    } else if (resp?.duplicate) {
      if (triggerBtn) triggerBtn.disabled = false
    } else {
      updateViewOnceState(clientMessageId, "unavailable", 0)
    }
  } catch (err) {
    console.error("Failed to open view-once media", err)
    if (err?.reason === "presentation_capacity_unavailable" || err?.error === "presentation_capacity_unavailable") {
      if (triggerBtn) triggerBtn.disabled = false
      announce("Server presentation capacity is currently busy. Please try again.")
    } else {
      updateViewOnceState(clientMessageId, "unavailable", 0)
    }
  }
}

function showViewOnceModal(objectUrl, triggerElement, messageId, state = "viewed", viewsRemaining = 0, presentationLimit = 1, mediaType = "image/jpeg") {
  if (activeViewOnceUrl) {
    URL.revokeObjectURL(activeViewOnceUrl)
    activeViewOnceUrl = null
  }

  activeViewOnceUrl = objectUrl
  activeViewOnceTrigger = triggerElement

  const backdrop = $("#view-once-viewer-backdrop")
  const container = $("#view-once-viewer-container")
  const closeBtn = $("#view-once-viewer-close")
  const title = $("#view-once-viewer-title")
  const note = $("#view-once-viewer-note")

  const isVideo = mediaType && (mediaType.startsWith("video/") || mediaType === "video/mp4")

  if (container) {
    if (isVideo) {
      const video = document.createElement("video")
      video.id = "view-once-viewer-video"
      video.src = objectUrl
      video.controls = true
      video.playsInline = true
      video.autoplay = false
      video.setAttribute("aria-label", "View-Once video playback")
      container.replaceChildren(video)

      if (app.ambientAudioPlaying && typeof app.pauseAmbientAudio === "function") {
        app.pauseAmbientAudio()
      }
    } else {
      const img = document.createElement("img")
      img.id = "view-once-viewer-img"
      img.src = objectUrl
      img.alt = presentationLimit === 2 ? "View-Twice photo" : "View-Once photo"
      container.replaceChildren(img)
    }
  }

  if (title) {
    title.textContent = isVideo ? (presentationLimit === 2 ? "View-Twice video" : "View-Once video") : (presentationLimit === 2 ? "View-Twice photo" : "View-Once photo")
  }

  if (note) {
    if (presentationLimit === 2 && viewsRemaining > 0) {
      note.textContent = "Closing this view will leave 1 view remaining."
    } else if (presentationLimit === 2) {
      note.textContent = "This was your final view. Closing it closes this view permanently."
    } else if (isVideo) {
      note.textContent = "This video can only be opened once. Closing it closes this view permanently."
    } else {
      note.textContent = "This photo can only be opened once. Closing it closes this view permanently."
    }
  }
  if (backdrop) backdrop.hidden = false
  if (closeBtn) closeBtn.focus()

  updateViewOnceState(messageId, state, viewsRemaining, presentationLimit)
}

function closeViewOnceModal() {
  const backdrop = $("#view-once-viewer-backdrop")
  const container = $("#view-once-viewer-container")

  if (container) {
    const video = container.querySelector("video")
    if (video) {
      try {
        video.pause()
        video.removeAttribute("src")
        video.load()
      } catch (_) {}
    }
    container.replaceChildren()
  }

  if (backdrop) backdrop.hidden = true

  if (activeViewOnceUrl) {
    URL.revokeObjectURL(activeViewOnceUrl)
    activeViewOnceUrl = null
  }

  if (app.ambientAudioPausedByVideo && typeof app.resumeAmbientAudio === "function") {
    app.resumeAmbientAudio()
  }

  if (activeViewOnceTrigger && typeof activeViewOnceTrigger.focus === "function") {
    try { activeViewOnceTrigger.focus() } catch (_) {}
  }
  activeViewOnceTrigger = null
}

function clearViewOncePreview() {
  if (app.viewOnce.previewUrl) {
    URL.revokeObjectURL(app.viewOnce.previewUrl)
    app.viewOnce.previewUrl = null
  }
  app.viewOnce.activeBlob = null
  app.viewOnce.draft = null
  const sheet = $("#view-once-preview")
  if (sheet) sheet.hidden = true
  const container = $("#view-once-preview-container")
  if (container) {
    const video = container.querySelector("video")
    if (video) {
      try {
        video.pause()
        video.removeAttribute("src")
        video.load()
      } catch (_) {}
    }
    container.replaceChildren()
  }
  const title = $("#view-once-preview-title")
  if (title) title.textContent = "Preview View-Once photo"
  const sendBtn = $("#view-once-send")
  const sendTwiceBtn = $("#view-twice-send")
  const sendVideoBtn = $("#view-once-video-send")
  const sendTwiceVideoBtn = $("#view-twice-video-send")
  if (sendBtn) sendBtn.hidden = false
  if (sendTwiceBtn) sendTwiceBtn.hidden = false
  if (sendVideoBtn) sendVideoBtn.hidden = true
  if (sendTwiceVideoBtn) sendTwiceVideoBtn.hidden = true
  const input = $("#view-once-file-input")
  if (input) input.value = ""
}

async function normalizeImageForViewOnce(file) {
  return new Promise((resolve, reject) => {
    if (!validPhotoBlob(file)) {
      return reject(new Error("invalid_file"))
    }
    const img = new Image()
    const reader = new FileReader()
    reader.onload = (e) => {
      img.onload = () => {
        let width = img.naturalWidth || img.width
        let height = img.naturalHeight || img.height

        if (width > MAX_PHOTO_DIMENSION || height > MAX_PHOTO_DIMENSION) {
          if (width > height) {
            height = Math.round((height * MAX_PHOTO_DIMENSION) / width)
            width = MAX_PHOTO_DIMENSION
          } else {
            width = Math.round((width * MAX_PHOTO_DIMENSION) / height)
            height = MAX_PHOTO_DIMENSION
          }
        }

        const canvas = document.createElement("canvas")
        canvas.width = width
        canvas.height = height
        const ctx = canvas.getContext("2d")
        ctx.drawImage(img, 0, 0, width, height)

        canvas.toBlob((blob) => {
          if (!blob) return reject(new Error("canvas_blob_failed"))
          resolve(blob)
        }, "image/jpeg", 0.9)
      }
      img.onerror = () => reject(new Error("image_decode_failed"))
      img.src = e.target.result
    }
    reader.onerror = () => reject(new Error("file_read_failed"))
    reader.readAsDataURL(file)
  })
}

async function handleViewOnceFileSelected(file) {
  if (!file) return
  if (!validPhotoBlob(file)) {
    announce("Please select an approved photo (JPEG, PNG, WebP) under 1 MB.")
    return
  }

  try {
    const normalizedBlob = await normalizeImageForViewOnce(file)
    app.viewOnce.activeBlob = normalizedBlob
    app.viewOnce.previewUrl = URL.createObjectURL(normalizedBlob)
    app.viewOnce.draft = {
      originConversationId: app.conversationId,
      originEpochId: app.currentEpochId
    }

    const previewSheet = $("#view-once-preview")
    const previewContainer = $("#view-once-preview-container")
    const previewTitle = $("#view-once-preview-title")
    const status = $("#view-once-preview-status")
    const sendBtn = $("#view-once-send")
    const sendTwiceBtn = $("#view-twice-send")
    const sendVideoBtn = $("#view-once-video-send")
    const sendTwiceVideoBtn = $("#view-twice-video-send")

    if (previewTitle) previewTitle.textContent = "Preview View-Once photo"

    if (previewContainer) {
      const previewImg = document.createElement("img")
      previewImg.src = app.viewOnce.previewUrl
      previewImg.alt = "View-once preview"
      previewContainer.replaceChildren(previewImg)
    }

    if (status) status.textContent = `${Math.round(normalizedBlob.size / 1024)} KB · Photo ready`
    if (sendBtn) {
      sendBtn.hidden = false
      sendBtn.disabled = false
    }
    if (sendTwiceBtn) {
      sendTwiceBtn.hidden = false
      sendTwiceBtn.disabled = false
    }
    if (sendVideoBtn) sendVideoBtn.hidden = true
    if (sendTwiceVideoBtn) sendTwiceVideoBtn.hidden = true
    if (previewSheet) previewSheet.hidden = false
    sendBtn?.focus()
  } catch (err) {
    console.error("View-once normalization failed", err)
    announce("Could not prepare photo for View-Once presentation.")
    clearViewOncePreview()
  }
}

const MAX_VIDEO_BYTES = 5_242_880

async function handleViewOnceVideoSelected(file) {
  if (!file) return
  if (file.size > MAX_VIDEO_BYTES) {
    announce("Video must be 5 MB or smaller and 15 seconds or less.")
    return
  }

  try {
    app.viewOnce.activeBlob = file
    app.viewOnce.previewUrl = URL.createObjectURL(file)
    app.viewOnce.draft = {
      originConversationId: app.conversationId,
      originEpochId: app.currentEpochId
    }

    const previewSheet = $("#view-once-preview")
    const previewContainer = $("#view-once-preview-container")
    const previewTitle = $("#view-once-preview-title")
    const status = $("#view-once-preview-status")
    const sendBtn = $("#view-once-send")
    const sendTwiceBtn = $("#view-twice-send")
    const sendVideoBtn = $("#view-once-video-send")
    const sendTwiceVideoBtn = $("#view-twice-video-send")

    if (previewTitle) previewTitle.textContent = "Preview View-Once video"

    if (previewContainer) {
      const previewVideo = document.createElement("video")
      previewVideo.id = "view-once-preview-video"
      previewVideo.src = app.viewOnce.previewUrl
      previewVideo.controls = true
      previewVideo.playsInline = true
      previewVideo.setAttribute("aria-label", "View-once video preview")
      previewContainer.replaceChildren(previewVideo)
    }

    if (status) status.textContent = `${Math.round(file.size / 1024)} KB · Video ready`
    if (sendBtn) sendBtn.hidden = true
    if (sendTwiceBtn) sendTwiceBtn.hidden = true
    if (sendVideoBtn) {
      sendVideoBtn.hidden = false
      sendVideoBtn.disabled = false
    }
    if (sendTwiceVideoBtn) {
      sendTwiceVideoBtn.hidden = false
      sendTwiceVideoBtn.disabled = false
    }
    if (previewSheet) previewSheet.hidden = false
    sendVideoBtn?.focus()
  } catch (err) {
    console.error("View-once video preparation failed", err)
    announce("Could not prepare video for View-Once presentation.")
    clearViewOncePreview()
  }
}

async function sendViewOncePhoto(presentationLimit = 1) {
  if (!app.conversation || !app.conversationId || !app.viewOnce.activeBlob) return
  if (!viewOnceDraftMatchesRuntime(app.viewOnce.draft, app.conversationId, app.currentEpochId)) {
    announce("View-Once draft belongs to a different conversation state.")
    clearViewOncePreview()
    return
  }

  const sendBtn = $("#view-once-send")
  const sendTwiceBtn = $("#view-twice-send")
  if (sendBtn) sendBtn.disabled = true
  if (sendTwiceBtn) sendTwiceBtn.disabled = true

  const clientMessageId = crypto.randomUUID()
  const blob = app.viewOnce.activeBlob

  try {
    const response = await fetch(`/api/conversations/${app.conversationId}/view-once/stage`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${app.identity?.token}`,
        "Content-Type": "application/octet-stream"
      },
      body: blob
    })

    if (!response.ok) {
      const errJson = await response.json().catch(() => ({}))
      throw errJson
    }

    const {staging_token} = await response.json()

    // Render local message immediately for sender
    await renderMessage({
      type: "view_once_photo",
      client_message_id: clientMessageId,
      message_id: clientMessageId,
      presentation_limit: presentationLimit,
      views_remaining: presentationLimit,
      views_consumed: 0,
      view_once_state: "unviewed",
      media_type: blob.type,
      byte_size: blob.size,
      sent_at: now()
    }, true)

    clearViewOncePreview()

    const reply = await push(app.conversation, "message:send", {
      client_message_id: clientMessageId,
      message_id: clientMessageId,
      staging_token: staging_token,
      presentation_limit: presentationLimit
    })

    updateMessageStatus(reply)
    await markCanonicalSequenceApplied(reply.sequence)
  } catch (error) {
    console.error("Failed to send View-Once photo", error)
    updateMessageStatus({client_message_id: clientMessageId, message_id: clientMessageId, status: "failed"})
    handleDomainError(error)
    if (sendBtn) sendBtn.disabled = false
    if (sendTwiceBtn) sendTwiceBtn.disabled = false
  }
}

async function sendViewOnceVideo(presentationLimit = 1) {
  if (!app.conversation || !app.conversationId || !app.viewOnce.activeBlob) return
  if (!viewOnceDraftMatchesRuntime(app.viewOnce.draft, app.conversationId, app.currentEpochId)) {
    announce("View-Once draft belongs to a different conversation state.")
    clearViewOncePreview()
    return
  }

  const sendVideoBtn = $("#view-once-video-send")
  const sendTwiceVideoBtn = $("#view-twice-video-send")
  if (sendVideoBtn) sendVideoBtn.disabled = true
  if (sendTwiceVideoBtn) sendTwiceVideoBtn.disabled = true

  const clientMessageId = crypto.randomUUID()
  const blob = app.viewOnce.activeBlob

  try {
    const response = await fetch(`/api/conversations/${app.conversationId}/view-once/stage`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${app.identity?.token}`,
        "Content-Type": "application/octet-stream"
      },
      body: blob
    })

    if (!response.ok) {
      const errJson = await response.json().catch(() => ({}))
      throw errJson
    }

    const {staging_token} = await response.json()

    // Render local message immediately for sender
    await renderMessage({
      type: "view_once_video",
      client_message_id: clientMessageId,
      message_id: clientMessageId,
      presentation_limit: presentationLimit,
      views_remaining: presentationLimit,
      views_consumed: 0,
      view_once_state: "unviewed",
      media_type: "video/mp4",
      byte_size: blob.size,
      sent_at: now()
    }, true)

    clearViewOncePreview()

    const reply = await push(app.conversation, "message:send", {
      client_message_id: clientMessageId,
      message_id: clientMessageId,
      staging_token: staging_token,
      type: "view_once_video",
      presentation_limit: presentationLimit
    })

    updateMessageStatus(reply)
    await markCanonicalSequenceApplied(reply.sequence)
  } catch (error) {
    console.error("Failed to send View-Once video", error)
    updateMessageStatus({client_message_id: clientMessageId, message_id: clientMessageId, status: "failed"})
    handleDomainError(error)
    if (sendVideoBtn) sendVideoBtn.disabled = false
    if (sendTwiceVideoBtn) sendTwiceVideoBtn.disabled = false
  }
}

async function rememberRelationship(id) {
  const conversation = await getRecord(`conversation:${app.conversationId}`)
  await putRecord({id: `relationship:${id}`, type: "relationship", value: {relationship_id: id, status: "created", conversation_id: app.conversationId, abstract_signature_seed: conversation?.value.abstract_signature_seed || null, origin_door_type: conversation?.value.door_type || null, origin_door_label: conversation?.value.display_door || null, formed_at: conversation?.value.ended_at || now(), private_nickname: null}, updated_at: now()})
  renderLocalViews()
  await offerContinuity()
  await maybeAutoSync()
}

async function applyRetention(choice, summaryText) {
  const records = await listRecords()
  const next = chooseConversationRetention(records, app.conversationId, choice, {summaryText, now: now()})
  if (choice === "summary_only") await putRecord(next.find(({id}) => id === `summary:${app.conversationId}`))
  await replaceRecords(next)
  if (["kept", "summary_only"].includes(choice)) { await offerContinuity(); await maybeAutoSync() }
  releaseAllVoiceUrls()
  releaseConversationRuntime()
  app.conversationId = null
  if (choice === "kept") show("chats"); else show("doors")
}

async function renderChats() {
  const records = await listRecords()
  const active = activeConversations(records)
  const kept = keptConversations(records).sort((a, b) => b.updated_at.localeCompare(a.updated_at))
  renderChatCards($("#active-chat-list"), active, records, "Nothing happening right now. That's okay.", false)
  renderChatCards($("#kept-chat-list"), kept, records, "No Conversations kept on this device.", true)
}

function renderChatCards(container, conversations, records, emptyText, openable) {
  container.replaceChildren()
  if (!conversations.length) { container.textContent = emptyText; return }
  conversations.forEach((conversation) => {
    const article = document.createElement("article"); article.className = "chat-card"
    article.append(signatureRibbon(conversation.value.abstract_signature_seed))
    const title = document.createElement("h3"); title.textContent = conversation.value.display_door
    const date = document.createElement("time"); date.dateTime = conversation.value.started_at; date.textContent = new Date(conversation.value.started_at).toLocaleString()
    const summary = records.find(({id}) => id === conversation.value.summary_id)?.value.text
    const firstMessage = records.filter((record) => record.type === "local_message" && record.value.conversation_id === conversation.value.conversation_id).sort((a, b) => a.value.sent_at.localeCompare(b.value.sent_at))[0]?.value.content
    const preview = document.createElement("p"); preview.textContent = summary || firstMessage?.split("\n")[0] || "Conversation kept without a preview."
    const label = document.createElement("p"); label.className = "local-only"; label.textContent = "Local copy"
    article.append(title, date, preview, label)
    if (openable) { const open = document.createElement("button"); open.textContent = "Open local copy"; open.setAttribute("aria-label", `Open local copy: ${conversation.value.display_door}`); open.addEventListener("click", () => openHistory(conversation.value.conversation_id)); article.append(open) }
    container.append(article)
  })
}

function signatureRibbon(seed) {
  const ribbon = document.createElement("div"); ribbon.className = "signature-ribbon"; ribbon.setAttribute("aria-hidden", "true")
  const value = Number.parseInt((seed || "sig-77777777").slice(-8), 16); ribbon.style.setProperty("--signature-a", `hsl(${value % 360} 36% 48%)`); ribbon.style.setProperty("--signature-b", `hsl(${(value >>> 8) % 360} 48% 68%)`); return ribbon
}

function doorKeyForLabel(label) {
  if (!label) return "deep-talk"
  const doorObj = DOORS.find(({label: l}) => l === label)
  if (doorObj) {
    if (doorObj.value === "SOMETHING_REAL") return "deep-talk"
    if (doorObj.value === "JUST_TALK") return "vent"
    if (doorObj.value === "KEEP_IT_LIGHT") return "distract"
    if (doorObj.value === "EXPLORE") return "advice"
  }
  return label.toLowerCase().replace(/\s+/g, "-")
}

function updateDoorLabels() {
  if (!app.selectedDoor) return
  $("#queue-door").textContent = app.selectedDoor
  const queueLede = $("#queue-lede")
  if (queueLede) queueLede.textContent = `Looking for someone who chose ${app.selectedDoor} too.`
  $("#conversation-door").textContent = "StrangerTalks"
  const convTitle = $("section[data-screen='conversation'] .conversation-head h1")
  if (convTitle) convTitle.textContent = app.selectedDoor
  const convSection = $("section[data-screen='conversation']")
  if (convSection) {
    convSection.dataset.door = doorKeyForLabel(app.selectedDoor)
  }
}

async function startMatchingFor(doorLabel) {
  app.sessionReconciliationGuard.transition()
  app.selectedDoor = doorLabel
  updateDoorLabels()
  const payload = queuePayloadFor(app.selectedDoor, app.conversationLanguage)
  if (!payload) return announce("Choose a Conversation Language first.")
  show("queue")
  try {
    await ensureBootstrap()
    if (!app.participantJoined || !app.participant) {
      if (app.identity && !app.socket) {
        connectSocket()
      }
      announce("Connecting…")
      for (let i = 0; i < 50; i++) {
        if (app.participantJoined && app.participant) break
        await new Promise((resolve) => setTimeout(resolve, 100))
      }
    }
    if (!app.participantJoined || !app.participant) {
      throw new Error("connection_timeout")
    }
    const result = await push(app.participant, "queue:join", payload)
    bindQueueAttempt(result.queue_attempt_id)
  } catch (error) {
    console.error("startMatchingFor failed:", error)
    handleDomainError(error, {fallbackMessage: "Could not start matching right now. Please try again.", fallbackScreen: "doors"})
  }
}







function reducedMotionEnabled() {
  return document.body.classList.contains("reduce-motion") || window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

function timelineNearBottom() {
  const viewport = $("#message-viewport")
  return viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight <= 80
}

function scrollTimelineToNewest({smooth = false} = {}) {
  requestAnimationFrame(() => {
    const viewport = $("#message-viewport")
    viewport.scrollTo({top: viewport.scrollHeight, behavior: smooth && !reducedMotionEnabled() ? "smooth" : "auto"})
    app.timelinePinned = true
    $("#new-messages").hidden = true
  })
}

function scrollHistoryToNewest() {
  requestAnimationFrame(() => $("#history-messages").lastElementChild?.scrollIntoView({block: "end", behavior: "auto"}))
}

async function renderHistory(conversationId) {
  app.historyConversationId = conversationId; app.rendered.clear(); releaseAllVoiceUrls(); $("#history-messages").replaceChildren()
  const records = await listRecords(); const conversation = records.find(({id}) => id === `conversation:${conversationId}`)
  $("#history-title").textContent = conversation.value.display_door
  const ribbon = signatureRibbon(conversation.value.abstract_signature_seed); $("#history-signature").replaceWith(ribbon); ribbon.id = "history-signature"
  chronologicalTimeline(records.filter((record) => ["local_message", "local_voice_note"].includes(record.type) && record.value.conversation_id === conversationId)).forEach((record) => record.type === "local_voice_note" ? renderVoiceNoteNode(record.value, $("#history-messages"), true) : renderMessageNode(record.value, record.value.mine, $("#history-messages")))
  $("#history-summary").value = records.find(({id}) => id === `summary:${conversationId}`)?.value.text || ""
  presentScreen("history")
  scrollHistoryToNewest()
}

async function openHistory(conversationId) {
  return navigateToScreen("history", conversationId)
}

function releaseVoiceUrl(voiceNoteId) {
  const url = app.voiceUrls.get(voiceNoteId)
  if (url) URL.revokeObjectURL(url)
  app.voiceUrls.delete(voiceNoteId)
}

function releaseAllVoiceUrls() {
  for (const voiceNoteId of [...app.voiceUrls.keys()]) releaseVoiceUrl(voiceNoteId)
}

function clearVoicePreview() {
  if (app.voice.objectUrl) URL.revokeObjectURL(app.voice.objectUrl)
  app.voice.objectUrl = null; app.voice.blob = null; app.voice.voiceNoteId = null; app.voice.durationMs = 0; app.voice.originConversationId = null; app.voice.originEpochId = null
  $("#voice-preview-audio").removeAttribute("src"); $("#voice-preview-audio").load(); $("#voice-preview").hidden = true
}

function closeVoiceStream() {
  clearInterval(app.voice.timer); clearTimeout(app.voice.stopTimer); cancelAnimationFrame(app.voice.activityFrame)
  app.voice.timer = null; app.voice.stopTimer = null; app.voice.activityFrame = null
  stopMediaTracks(app.voice.stream)
  app.voice.stream = null; app.voice.recorder = null; $("#voice-recording").hidden = true
  $("#voice-recording-waveform")?.classList.remove("active")
}

async function requestVoiceRecording() {
  const warning = await getRecord("settings:voice-warning:v1")
  if (!warningAcknowledged(warning)) { $("#voice-warning").hidden = false; return }
  await startVoiceRecording()
}

async function startVoiceRecording() {
  $("#voice-warning").hidden = true; clearVoicePreview(); $("#voice-preview-status").textContent = ""
  if (!app.voice.mediaType || !navigator.mediaDevices?.getUserMedia) { announce("Voice recording is unavailable in this browser. Text messaging still works."); return }

  const captureRequestId = ++app.voice.captureRequestId
  const captureConversationId = app.conversationId
  const captureEpochId = app.currentEpochId

  try {
    const stream = await navigator.mediaDevices.getUserMedia({audio: true})
    if (!voiceCaptureStillAuthorized({
      requestId: captureRequestId,
      currentRequestId: app.voice.captureRequestId,
      conversationId: captureConversationId,
      currentConversationId: app.conversationId,
      epochId: captureEpochId,
      currentEpochId: app.currentEpochId,
      conversationAvailable: Boolean(app.conversation)
    })) {
      stopMediaTracks(stream)
      return
    }

    const recorder = new MediaRecorder(stream, {mimeType: app.voice.mediaType, audioBitsPerSecond: 64_000})
    Object.assign(app.voice, {stream, recorder, chunks: [], startedAt: Date.now(), discard: false, originConversationId: app.conversationId, originEpochId: app.currentEpochId})
    recorder.addEventListener("dataavailable", ({data}) => { if (data.size) app.voice.chunks.push(data) })
    recorder.addEventListener("stop", finishVoiceRecording, {once: true})
    recorder.start(); $("#voice-recording").hidden = false; $("#voice-recording-waveform")?.classList.add("active"); updateVoiceTimer()
    app.voice.timer = setInterval(updateVoiceTimer, 250)
    app.voice.stopTimer = setTimeout(() => { if (recorder.state === "recording") recorder.stop() }, MAX_VOICE_DURATION_MS)
  } catch {
    if (app.voice.captureRequestId === captureRequestId) {
      closeVoiceStream(); announce("Microphone access was not granted. Text messaging is still available.")
    }
  }
}

function updateVoiceTimer() {
  const seconds = Math.min(60, Math.floor((Date.now() - app.voice.startedAt) / 1000))
  $("#voice-timer").textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
  $("#voice-recording-status").textContent = `Recording, ${seconds} seconds elapsed`
}

function finishVoiceRecording() {
  try {
    const durationMs = Math.min(MAX_VOICE_DURATION_MS, Math.max(1, Date.now() - app.voice.startedAt))
    const discard = app.voice.discard; const blob = new Blob(app.voice.chunks, {type: baseMediaType(app.voice.mediaType)})
    closeVoiceStream()
    if (discard) { clearVoicePreview(); return }
    app.voice.blob = blob; app.voice.durationMs = durationMs; app.voice.voiceNoteId = crypto.randomUUID()
    app.voice.objectUrl = URL.createObjectURL(blob); $("#voice-preview-audio").src = app.voice.objectUrl; $("#voice-preview").hidden = false
    const valid = validVoiceBlob(blob); $("#voice-send").disabled = !valid
    $("#voice-preview-status").textContent = valid ? "Draft ready. Preview it before sending. Nothing is sent automatically." : `This recording is too large. Voice notes must be ${MAX_VOICE_BYTES.toLocaleString()} bytes or less.`
    $("#voice-preview-audio").focus()
  } catch {
    closeVoiceStream(); clearVoicePreview(); announce("Voice draft could not be finalized. Nothing was sent.")
  }
}

function cancelRecording() {
  app.voice.captureRequestId++
  app.voice.discard = true
  if (app.voice.recorder?.state === "recording") app.voice.recorder.stop()
  else { closeVoiceStream(); clearVoicePreview() }
}

async function sendVoicePreview() {
  if (!validVoiceBlob(app.voice.blob)) return
  if (!voiceDraftMatchesRuntime(app.voice, app.conversationId, app.currentEpochId)) {
    $("#voice-preview-status").textContent = "This draft belongs to an earlier Conversation. You can preview or discard it, but it cannot be sent here."
    $("#voice-send").disabled = true
    return
  }
  const id = app.voice.voiceNoteId; const sentAt = now(); $("#voice-send").disabled = true; $("#voice-preview-status").textContent = "Uploading…"
  const record = localVoiceNote({conversation_id: app.conversationId, voice_note_id: id, blob: app.voice.blob, mine: true, delivery_status: "sending", sent_at: sentAt, sequence: null, duration_ms: app.voice.durationMs, byte_size: app.voice.blob.size, media_type: baseMediaType(app.voice.mediaType)})
  await putRecord(record)
  try {
    const response = await fetch(`/api/conversations/${app.conversationId}/voice-notes/${id}`, {method: "POST", headers: {authorization: `Bearer ${app.identity.token}`, "content-type": baseMediaType(app.voice.mediaType), "x-voice-duration-ms": String(app.voice.durationMs)}, body: app.voice.blob})
    const result = await response.json()
    if (!response.ok) throw new Error(result.error || "upload_failed")
    const saved = {...record, value: {...record.value, delivery_status: result.status}, updated_at: now()}; await putRecord(saved)
    renderVoiceNoteNode(saved.value, $("#messages"), false); clearVoicePreview(); scrollTimelineToNewest({smooth: true})
  } catch { $("#voice-preview-status").textContent = "Voice note failed to send. Try again or re-record."; $("#voice-send").disabled = false; updateVoiceNoteStatus({voice_note_id: id, status: "failed"}) }
}

async function renderLocalViews() {
  const records = await listRecords(); renderRecordList($("#memory-list"), records.filter(({type}) => type === "memory" || type === "summary"))
  const relationships = records.filter(({type}) => type === "relationship"); const container = $("#relationship-list"); container.replaceChildren()
  if (!relationships.length) container.textContent = "No Bonds saved on this device."
  relationships.forEach((record) => {
    const article = document.createElement("article"); article.className = "bond-card"
    if (record.value.abstract_signature_seed) article.append(signatureRibbon(record.value.abstract_signature_seed))
    const title = document.createElement("h3"); title.textContent = record.value.private_nickname || "Private Bond"
    const details = document.createElement("p"); details.textContent = `${record.value.origin_door_label || "Conversation"} · ${new Date(record.value.formed_at || record.updated_at).toLocaleDateString()}`
    const reconnect = document.createElement("div"); reconnect.className = "bond-reconnect"; reconnect.dataset.relationshipId = record.value.relationship_id
    article.append(title, details, reconnect); container.append(article)
    renderReconnectState(reconnect, {relationship_id: record.value.relationship_id, status: "idle"})
    if (app.participantJoined) restoreReconnectStatus(record.value.relationship_id, reconnect)
  })
  startReconnectCountdown()
}

async function restoreReconnectStatus(relationshipId, container) {
  try {
    const result = await push(app.participant, "bond:reconnect_status", {relationship_id: relationshipId})
    const state = reconnectDisplayState(result, relationshipId)
    await putRecord(reconnectStateRecord(state, now()))
    if (state.status === "matched") await handleMatchedConversation(state, relationshipId)
    else renderReconnectState(container, state)
  } catch {
    const unavailable = unavailableReconnectState(relationshipId)
    await putRecord(reconnectStateRecord(unavailable, now()))
    renderReconnectState(container, unavailable)
  }
}

function renderReconnectState(container, state) {
  container.replaceChildren()
  if (state.status === "matched") { const message = document.createElement("p"); message.textContent = "Reconnecting to your Conversation…"; container.append(message); app.reconnectCountdown.stop(); return }
  if (state.status === "unavailable") { const message = document.createElement("p"); message.textContent = "Private reconnection is unavailable right now."; const retry = document.createElement("button"); retry.textContent = "Try again"; retry.addEventListener("click", () => restoreReconnectStatus(state.relationship_id, container)); container.append(message, retry); return }
  if (state.status !== "waiting_for_mutual_availability" || remainingAvailabilitySeconds(state.expires_at) === 0) {
    const button = document.createElement("button"); button.textContent = "Reconnect privately"; button.addEventListener("click", () => renderReconnectDoors(container, state.relationship_id)); container.append(button); return
  }
  const heading = document.createElement("strong"); heading.textContent = "Available to reconnect for 15 minutes."
  const privacy = document.createElement("p"); privacy.textContent = "They will never know unless they choose the same."
  const selected = document.createElement("p"); selected.textContent = `Selected Door: ${DOORS.find(({value}) => value === state.door_type)?.label || state.door_type}`
  const countdown = document.createElement("time"); countdown.dataset.expiresAt = state.expires_at; countdown.textContent = availabilityCopy(state.expires_at)
  const change = document.createElement("button"); change.textContent = "Change Door"; change.addEventListener("click", () => renderReconnectDoors(container, state.relationship_id))
  const cancel = document.createElement("button"); cancel.textContent = "Cancel"; cancel.addEventListener("click", async () => { try { await push(app.participant, "bond:reconnect_cancel", {relationship_id: state.relationship_id}); const idle = {relationship_id: state.relationship_id, status: "idle"}; await putRecord(reconnectStateRecord(idle, now())); renderReconnectState(container, idle); refreshReconnectCountdown() } catch { announce("Could not cancel private availability. Try again.") } })
  container.append(heading, privacy, selected, countdown, change, cancel)
  startReconnectCountdown()
}

function renderReconnectDoors(container, relationshipId) {
  container.replaceChildren()
  const prompt = document.createElement("p"); prompt.textContent = "What kind of Conversation do you need right now?"; container.append(prompt)
  DOORS.forEach((door) => { const button = document.createElement("button"); button.textContent = door.label; button.addEventListener("click", async () => { try { const result = await push(app.participant, "bond:reconnect_start", {relationship_id: relationshipId, door_type: door.value}); const state = reconnectDisplayState(result, relationshipId); await putRecord(reconnectStateRecord(state, now())); if (state.status === "matched") await handleMatchedConversation(state, relationshipId); else renderReconnectState(container, state) } catch { const unavailable = unavailableReconnectState(relationshipId); await putRecord(reconnectStateRecord(unavailable, now())); renderReconnectState(container, unavailable); announce("Private reconnection is unavailable right now.") } }); container.append(button) })
}

function availabilityCopy(expiresAt) {
  const seconds = remainingAvailabilitySeconds(expiresAt); return seconds ? `${Math.ceil(seconds / 60)} minutes remaining` : "Availability expired"
}

function startReconnectCountdown() {
  if (!document.querySelector("[data-expires-at]")) return app.reconnectCountdown.stop()
  if (!app.reconnectCountdown.active()) app.reconnectCountdown.start(updateReconnectCountdowns)
}
function refreshReconnectCountdown() { if (document.querySelector("[data-expires-at]")) startReconnectCountdown(); else app.reconnectCountdown.stop() }
function updateReconnectCountdowns() { document.querySelectorAll("[data-expires-at]").forEach((node) => { node.textContent = availabilityCopy(node.dataset.expiresAt); if (remainingAvailabilitySeconds(node.dataset.expiresAt) === 0) { const container = node.closest(".bond-reconnect"); renderReconnectState(container, {relationship_id: container.dataset.relationshipId, status: "idle"}) } }); refreshReconnectCountdown() }

function renderRecordList(container, records) { container.replaceChildren(); if (!records.length) { container.textContent = "Nothing saved locally yet."; return } records.forEach((record) => { const article = document.createElement("article"); const text = document.createElement("p"); text.textContent = record.value.text || record.type; const remove = document.createElement("button"); remove.textContent = "Delete"; remove.addEventListener("click", async () => { await putRecord(tombstoneFor(record, now())); renderLocalViews(); renderDataInventory(); await maybeAutoSync() }); article.append(text, remove); container.append(article) }) }
async function renderDataInventory() { const records = await listRecords(); const totals = records.reduce((counts, {type}) => ({...counts, [type]: (counts[type] || 0) + 1}), {}); $("#local-data-list").textContent = Object.keys(totals).length ? Object.entries(totals).map(([type, count]) => `${type}: ${count}`).join(" · ") : "No local data stored." }

async function renderAccountState() {
  $("#account-guest").hidden = !app.account.available || app.account.connected
  $("#account-connected").hidden = !app.account.connected
  $("#account-disabled").hidden = app.account.available
  const auto = await getRecord("settings:auto-sync")
  $("#auto-sync").checked = auto?.value.enabled === true
  if (!app.account.connected || !app.account.available) $("#continuity-suggestion").hidden = true
}

async function startGoogle(mode) {
  const headers = {accept: "application/json"}
  if (mode === "link") headers.authorization = `Bearer ${app.identity.token}`
  const response = await fetch(`/auth/google/start?mode=${mode}`, {headers, credentials: "same-origin"})
  const body = await response.json()
  if (!response.ok || !body.authorization_url) throw new Error(body.error?.reason || "oauth_start_failed")
  location.assign(body.authorization_url)
}

async function fetchRemoteSync() {
  const response = await fetch("/api/account/sync", {credentials: "same-origin", headers: {accept: "application/json"}})
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(body.error?.reason || "sync_failed")
  app.account.revision = body.revision
  app.account.envelope = body.envelope || null
  if (body.last_synced_at) { $("#sync-last").textContent = `Last synced ${new Date(body.last_synced_at).toLocaleString()}.`; $("#sync-status").textContent = "Encrypted Google sync is available." }
  return body
}

function requestRecoveryPassphrase({confirmChoice = false} = {}) {
  const passphrase = prompt("Enter a recovery passphrase. If you lose it and all unlocked devices, neither StrangerTalks nor Google can recover this encrypted data.")
  if (!passphrase) throw new Error("passphrase_required")
  if (confirmChoice && passphrase !== prompt("Enter the recovery passphrase again to confirm.")) throw new Error("passphrase_mismatch")
  app.account.passphrase = passphrase
  return passphrase
}

async function uploadSync(records, baseRevision, passphrase) {
  let envelope
  if (app.account.syncKey && app.account.envelope) {
    envelope = await encryptSyncWithKey(syncableRecords(records), app.account.syncKey, app.account.envelope, baseRevision)
  } else {
    const bundle = await encryptSyncBundle(syncableRecords(records), passphrase, baseRevision)
    envelope = bundle.envelope
    app.account.syncKey = bundle.syncKey
    if (await supportsPersistentCryptoKey().catch(() => false)) await storeSyncKey(bundle.syncKey, app.account.continuity_id).catch(() => {})
  }
  const response = await accountFetch("/api/account/sync", {method: "PUT", headers: {"content-type": "application/json"}, body: JSON.stringify({base_revision: baseRevision, envelope})})
  const body = await response.json().catch(() => ({}))
  if (response.status === 409) throw new Error("sync_conflict")
  if (!response.ok) throw new Error(body.error?.reason || "sync_failed")
  app.account.revision = body.revision
  app.account.envelope = {...envelope, revision: body.revision}
  $("#sync-status").textContent = "Encrypted retained data is protected in Google app data."
  $("#sync-last").textContent = `Last synced ${new Date(body.last_synced_at).toLocaleString()}.`
  return body
}

async function mergeRemoteRecords(remoteRecords) {
  const local = await listRecords()
  const selected = syncableRecords(local)
  const selectedIds = new Set(selected.map(({id}) => id))
  const merged = await mergeSyncRecords(selected, remoteRecords)
  const counts = merged.reduce((result, record) => ({...result, [record.type]: (result[record.type] || 0) + 1}), {})
  if (!confirm(`Restore these encrypted categories on this device? ${Object.entries(counts).map(([type, count]) => `${type}: ${count}`).join(", ") || "No retained records"}`)) return false
  await replaceRecords([...local.filter((record) => !selectedIds.has(record.id)), ...merged])
  await renderLocalViews(); await renderDataInventory()
  return true
}

async function restoreFromGoogle(automatic = false) {
  const remote = await fetchRemoteSync()
  if (remote.status === "empty") { if (!automatic) announce("No encrypted Google sync data exists yet."); return false }
  let records
  if (app.account.syncKey) {
    try { records = await decryptSyncWithKey(remote.envelope, app.account.syncKey) } catch { app.account.syncKey = null }
  }
  if (!records) {
    const unlocked = await unlockSync(remote.envelope, app.account.passphrase || requestRecoveryPassphrase())
    records = unlocked.records; app.account.syncKey = unlocked.syncKey
    if (await supportsPersistentCryptoKey().catch(() => false)) await storeSyncKey(unlocked.syncKey, app.account.continuity_id).catch(() => {})
  }
  if (await mergeRemoteRecords(records)) { announce("Encrypted Google data was restored and merged. Newer valid records won; deletions remained deleted."); return true }
  return false
}

async function syncNow() {
  const remote = await fetchRemoteSync()
  if (remote.status === "empty") {
    const passphrase = requestRecoveryPassphrase({confirmChoice: true})
    await uploadSync(await listRecords(), 0, passphrase)
    announce("Encrypted Google sync created. Keep your recovery passphrase safe.")
    return
  }
  let remoteRecords
  if (app.account.syncKey) {
    try { remoteRecords = await decryptSyncWithKey(remote.envelope, app.account.syncKey) } catch { app.account.syncKey = null }
  }
  if (!remoteRecords) {
    const unlocked = await unlockSync(remote.envelope, app.account.passphrase || requestRecoveryPassphrase())
    remoteRecords = unlocked.records; app.account.syncKey = unlocked.syncKey
    if (await supportsPersistentCryptoKey().catch(() => false)) await storeSyncKey(unlocked.syncKey, app.account.continuity_id).catch(() => {})
  }
  const passphrase = app.account.passphrase
  const local = await listRecords()
  const merged = await mergeSyncRecords(syncableRecords(local), remoteRecords)
  if (!confirm(`Merge ${merged.length} retained records and replace revision ${remote.revision}?`)) return
  try { await uploadSync([...local.filter((record) => !new Set(syncableRecords(local).map(({id}) => id)).has(record.id)), ...merged], remote.revision, passphrase); announce("Encrypted Google sync is current.") }
  catch (error) { if (error.message === "sync_conflict") { announce("A newer copy exists. Restore and review it before retrying."); const restored = await restoreFromGoogle(); if (restored && confirm("The newer copy was merged. Retry encrypted sync now?")) { await uploadSync(await listRecords(), app.account.revision, app.account.passphrase); announce("Encrypted Google sync is current.") } } else throw error }
}

async function maybeAutoSync() {
  const enabled = (await getRecord("settings:auto-sync"))?.value.enabled === true
  if (!enabled || !app.account.connected) return
  if (!app.account.passphrase && !app.account.syncKey) { $("#sync-status").textContent = "New saved data is waiting. Use Sync now to unlock encrypted sync for this browser session."; return }
  try {
    const remote = await fetchRemoteSync()
    if (remote.status === "empty" || !app.account.syncKey) { $("#sync-status").textContent = "Local changes are waiting. Use Sync now to finish setup."; return }
    const remoteRecords = await decryptSyncWithKey(remote.envelope, app.account.syncKey)
    const local = await listRecords()
    const selectedIds = new Set(syncableRecords(local).map(({id}) => id))
    const merged = await mergeSyncRecords(syncableRecords(local), remoteRecords)
    await uploadSync([...local.filter((record) => !selectedIds.has(record.id)), ...merged], remote.revision, null)
  } catch (error) {
    if (error.message === "google_reauthorization_required") $("#account-reauthorize").hidden = false
    $("#sync-status").textContent = error.message === "sync_conflict" ? "A newer encrypted copy exists. Use Restore from Google to review it." : "Local changes are waiting for a manual sync."
  }
}

async function offerContinuity() {
  if (!app.account.available || app.account.connected) return
  const dismissed = await getRecord("settings:continuity-suggestion")
  if (!dismissed?.value.dismissed) $("#continuity-suggestion").hidden = false
}

async function replaceWithSyncTombstones(before, after) {
  const remaining = new Set(after.map(({id}) => id))
  const tombstones = syncableRecords(before).filter(({id}) => !remaining.has(id)).map((record) => tombstoneFor(record, now()))
  await replaceRecords([...after, ...tombstones])
  await maybeAutoSync()
}

function filteredExpressiveItems(term = "") {
  const query = term.trim().toLocaleLowerCase()
  if (!query) return EXPRESSIVE_CATALOG
  return EXPRESSIVE_CATALOG.filter((item) => `${item.label} ${item.category} ${item.kind}`.toLocaleLowerCase().includes(query))
}

function renderExpressiveResults(term = "") {
  const results = $("#expressive-results")
  results.replaceChildren()
  filteredExpressiveItems(term).forEach((media, index) => {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "expressive-option"
    button.dataset.expressiveId = media.id
    button.setAttribute("role", "option")
    button.setAttribute("aria-label", media.label)
    button.tabIndex = index === 0 ? 0 : -1
    const image = document.createElement("img")
    image.src = media.asset_path
    image.alt = ""
    image.setAttribute("aria-hidden", "true")
    if (media.kind === "loop") image.classList.add("expressive-loop")
    const label = document.createElement("span")
    label.textContent = media.label
    button.append(image, label)
    button.addEventListener("click", () => sendExpressive(media.id))
    results.append(button)
  })
}

function openExpressivePicker() {
  renderExpressiveResults("")
  $("#expressive-picker").hidden = false
  $("#expressive-open").setAttribute("aria-expanded", "true")
  $("#expressive-search").value = ""
  $("#expressive-search").focus()
}

function closeExpressivePicker(returnFocus = true) {
  const picker = $("#expressive-picker")
  if (!picker) return
  picker.hidden = true
  $("#expressive-open")?.setAttribute("aria-expanded", "false")
  if (returnFocus && $("#expressive-open") && !$("#expressive-open").hidden) $("#expressive-open").focus()
}

async function sendExpressive(expressiveId) {
  const media = EXPRESSIVE_CATALOG.find((item) => item.id === expressiveId)
  if (!media || !app.conversation) return
  const client_message_id = crypto.randomUUID()
  closeExpressivePicker(false)
  await renderMessage({type: "expressive", expressive: media, client_message_id, message_id: client_message_id, status: "sending", sent_at: now()}, true)

  try {
    const reply = await push(app.conversation, "message:send", {client_message_id, message_id: client_message_id, expressive_id: expressiveId})
    updateMessageStatus(reply)
    await markCanonicalSequenceApplied(reply.sequence)
  } catch (error) {
    updateMessageStatus({client_message_id, message_id: client_message_id, status: "failed"})
    handleDomainError(error)
  }
}

initializeLifetimePresentation()

const initialNavigationRuntimeState = createRouteRuntimeState(location.pathname)
if (!initialNavigationRuntimeState.requiresCanonicalReadiness) {
  initializeOrReconcileNavigation(null).catch(() => announce("Navigation could not be initialized."))
}

DOORS.forEach((door) => { const button = document.createElement("button"); button.className = "door"; button.type = "button"; button.dataset.door = door.value; button.setAttribute("aria-pressed", "false"); const mark = document.createElement("i"); mark.className = "door-mark"; mark.setAttribute("aria-hidden", "true"); const title = document.createElement("strong"); title.textContent = door.label; const description = document.createElement("span"); description.textContent = door.description; button.append(mark, title, description); button.addEventListener("click", () => { document.querySelectorAll(".door").forEach((node) => node.setAttribute("aria-pressed", String(node === button))); startMatchingFor(door.label) }); $("#doors").append(button) })
document.addEventListener("click", (event) => { const target = event.target.closest("[data-go]"); if (target) navigateToScreen(target.dataset.go).catch(() => announce("Navigation could not be completed.")) })
window.addEventListener("popstate", () => { navigation.popstate().catch(() => announce("Navigation could not be restored.")) })
const joinQueueBtn = $("#join-queue"); if (joinQueueBtn) joinQueueBtn.addEventListener("click", () => startMatchingFor(app.selectedDoor))
$("#leave-queue").addEventListener("click", async () => {
  try {
    await push(app.participant, "queue:leave", {queue_attempt_id: app.queueAttemptId})
  } catch (error) {
    await handleDomainError(error, {fallbackMessage: "Could not cancel matching. Please try again."})
  }
})

$("#expressive-open").addEventListener("click", () => $("#expressive-picker").hidden ? openExpressivePicker() : closeExpressivePicker())
$("#expressive-close").addEventListener("click", () => closeExpressivePicker())
$("#expressive-search").addEventListener("input", (event) => renderExpressiveResults(event.target.value))
$("#expressive-picker").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault()
    closeExpressivePicker()
    return
  }
  const options = Array.from(document.querySelectorAll("#expressive-results .expressive-option"))
  const current = options.indexOf(document.activeElement)
  if (["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"].includes(event.key) && options.length) {
    event.preventDefault()
    const direction = ["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : -1
    const next = options[(current + direction + options.length) % options.length]
    options.forEach((option) => { option.tabIndex = option === next ? 0 : -1 })
    next.focus()
  }
})

$("#message-form").addEventListener("submit", async (event) => {
  event.preventDefault()
  const input = $("#message-input")
  const content = input.value.trim()
  if (!content) return
  const client_message_id = crypto.randomUUID()

  const replyContext = app.replyState
  const reply_to_client_message_id = replyContext ? replyContext.reply_to_client_message_id : null
  const reply_author_relation = replyContext ? replyContext.reply_author_relation : null
  const reply_snippet = replyContext ? replyContext.reply_snippet : null

  cancelReplyStaging()

  const message = {
    client_message_id,
    message_id: client_message_id,
    content,
    status: "sending",
    sent_at: now(),
    reply_to_client_message_id,
    reply_author_relation,
    reply_snippet
  }
  await renderMessage(message, true)
  input.value = ""
  renderPromptDraftAvailability()

  const payload = {
    client_message_id,
    message_id: client_message_id,
    content
  }
  if (reply_to_client_message_id) {
    payload.reply_to_client_message_id = reply_to_client_message_id
  }

  try {
    const reply = await push(app.conversation, "message:send", payload)
    updateMessageStatus(reply)
    await markCanonicalSequenceApplied(reply.sequence)
  } catch (error) {
    const errorCode = error?.error?.code || error?.code
    if (errorCode && ["RATE_LIMITED", "MESSAGE_BUFFER_FULL", "CONVERSATION_BUSY", "NOT_CONVERSATION_MEMBER", "CONVERSATION_UNAVAILABLE", "INVALID_MESSAGE_ID", "INVALID_PAYLOAD", "MESSAGE_ID_CONFLICT", "CONVERSATION_TERMINATING", "INVALID_REQUEST"].includes(errorCode)) {
      updateMessageStatus({client_message_id, message_id: client_message_id, status: "failed"})
    }
    handleDomainError(error)
  }
})
$("#message-input").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault()
    $("#message-form").requestSubmit()
  } else if (event.key === "Escape" && app.replyState) {
    event.preventDefault()
    cancelReplyStaging()
  }
})
$("#reply-cancel")?.addEventListener("click", () => {
  cancelReplyStaging()
  $("#message-input").focus()
})
$("#message-viewport").addEventListener("keydown", (event) => {
  const messages = Array.from(document.querySelectorAll("#messages .message"))
  if (!messages.length) return
  const active = document.activeElement.closest(".message")
  const currentIndex = active ? messages.indexOf(active) : -1

  if (event.key === "ArrowDown") {
    event.preventDefault()
    const nextIndex = currentIndex < messages.length - 1 ? currentIndex + 1 : 0
    messages[nextIndex].focus()
  } else if (event.key === "ArrowUp") {
    event.preventDefault()
    const prevIndex = currentIndex > 0 ? currentIndex - 1 : messages.length - 1
    messages[prevIndex].focus()
  } else if ((event.key === "r" || event.key === "R") && active && event.target.tagName !== "TEXTAREA" && event.target.tagName !== "INPUT") {
    event.preventDefault()
    const msgId = active.dataset.messageId
    if (msgId) startReplyCheck(msgId)
  } else if ((event.key === "e" || event.key === "E") && active && event.target.tagName !== "TEXTAREA" && event.target.tagName !== "INPUT") {
    event.preventDefault()
    const msgId = active.dataset.messageId
    if (msgId) openReactionPicker(msgId, active)
  } else if (event.key === "Escape") {
    if (app.activeReactionPickerTarget) {
      event.preventDefault()
      closeReactionPicker()
    } else if (app.replyState) {
      event.preventDefault()
      cancelReplyStaging()
    }
  }
})
document.addEventListener("click", (event) => {
  if (!event.target.closest(".reaction-picker") && !event.target.closest(".react-action-btn")) {
    closeReactionPicker()
  }
})
$("#messages").addEventListener("click", (event) => {
  const quote = event.target.closest(".reply-quote")
  if (quote) {
    event.preventDefault()
    jumpToOriginalMessage(quote.dataset.replyTo)
  }
})
$("#messages").addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    const quote = event.target.closest(".reply-quote")
    if (quote) {
      event.preventDefault()
      jumpToOriginalMessage(quote.dataset.replyTo)
    }
  }
})
$("#pinned-messages-control")?.addEventListener("click", () => {
  const panel = $("#pinned-messages-panel")
  if (!panel) return
  const isHidden = panel.hasAttribute("hidden")
  if (isHidden) {
    panel.removeAttribute("hidden")
    panel.style.display = ""
    $("#pinned-messages-control")?.setAttribute("aria-expanded", "true")
  } else {
    panel.setAttribute("hidden", "")
    panel.style.display = "none"
    $("#pinned-messages-control")?.setAttribute("aria-expanded", "false")
  }
})
$("#pinned-panel-close")?.addEventListener("click", () => {
  const panel = $("#pinned-messages-panel")
  if (panel) {
    panel.setAttribute("hidden", "")
    panel.style.display = "none"
  }
  $("#pinned-messages-control")?.setAttribute("aria-expanded", "false")
})
$("#quiet-mode-control")?.addEventListener("click", () => {
  toggleQuietMode()
})
$("#ambient-audio-control")?.addEventListener("click", toggleAmbientAudio)
$("#atmosphere-control")?.addEventListener("click", openAtmosphereChooser)
$("#atmosphere-close")?.addEventListener("click", () => closeAtmosphereChooser())
$("#atmosphere-reset")?.addEventListener("click", () => setAtmosphere(null))
$("#atmosphere-chooser")?.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault()
    closeAtmosphereChooser()
  }
})
$("#prompt-control")?.addEventListener("click", () => {
  if (app.promptCards.open) closePromptCards()
  else openPromptCards()
})
$("#prompt-close")?.addEventListener("click", () => closePromptCards())
document.querySelectorAll("[data-prompt-category]").forEach((button) => {
  button.addEventListener("click", () => selectPromptCategory(button.dataset.promptCategory))
})
$("#prompt-use")?.addEventListener("click", useSelectedPrompt)
$("#icebreaker-dismiss")?.addEventListener("click", locallyDismissIcebreaker)
$("#prompt-helper")?.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault()
    closePromptCards()
  }
})
$("#message-input").addEventListener("input", () => {
  renderPromptDraftAvailability()
  const conversation = app.conversation
  if (!conversation || !app.conversationId) {
    clearConversationTypingRuntime()
    return
  }
  push(conversation, "typing:start").catch(() => {})
  clearTimeout(app.typingTimer)
  app.typingTimer = setTimeout(() => {
    if (app.conversation !== conversation || !app.conversationId) return
    app.typingTimer = null
    push(conversation, "typing:stop").catch(() => {})
  }, 1500)
})
$("#voice-start").addEventListener("click", requestVoiceRecording)
$("#voice-warning-help").addEventListener("click", () => { $("#voice-warning").hidden = false })
$("#voice-warning-cancel").addEventListener("click", () => { $("#voice-warning").hidden = true })
$("#voice-warning-continue").addEventListener("click", async () => { await putRecord({id: "settings:voice-warning:v1", type: "settings", value: {voice_warning_version: VOICE_WARNING_VERSION}, updated_at: now()}); await startVoiceRecording() })
$("#voice-stop").addEventListener("click", () => { if (app.voice.recorder?.state === "recording") app.voice.recorder.stop() })
$("#voice-record-cancel").addEventListener("click", cancelRecording)
$("#voice-preview-cancel").addEventListener("click", clearVoicePreview)
$("#voice-rerecord").addEventListener("click", startVoiceRecording)
$("#voice-send").addEventListener("click", sendVoicePreview)
$("#voice-preview-audio").after(createVoicePlayerControls($("#voice-preview-audio"), 0))
$("#message-viewport").addEventListener("scroll", () => { app.timelinePinned = timelineNearBottom(); if (app.timelinePinned) $("#new-messages").hidden = true })
$("#new-messages").addEventListener("click", () => scrollTimelineToNewest({smooth: true}))
window.visualViewport?.addEventListener("resize", () => { if (app.timelinePinned) scrollTimelineToNewest() })
document.querySelectorAll("[data-lifetime-details]").forEach((trigger) => trigger.addEventListener("click", () => {
  openDisclosureDialog($("#lifetime-details-backdrop"), trigger, $("#lifetime-details-close"))
}))
$("#lifetime-details-close").addEventListener("click", () => closeDisclosureDialog())
$("#lifetime-details-backdrop").addEventListener("keydown", handleDisclosureDialogKeydown)
$("#end-confirmation-backdrop").addEventListener("keydown", handleDisclosureDialogKeydown)
$("#end-conversation").addEventListener("click", () => {
  openDisclosureDialog($("#end-confirmation-backdrop"), $("#end-conversation"), $("#end-cancel"))
})
$("#end-cancel").addEventListener("click", () => closeDisclosureDialog())
$("#end-confirm").addEventListener("click", async () => {
  closeDisclosureDialog({restoreFocus: false})
  await push(app.conversation, "conversation:end")
})
$("#unsend-cancel").addEventListener("click", () => closeMessageUnsend())
$("#unsend-confirm").addEventListener("click", confirmMessageUnsend)
$("#unsend-confirmation-backdrop").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault()
    closeMessageUnsend()
  }
})
$("#keep-conversation").addEventListener("click", () => applyRetention("kept").catch(() => announce("Could not keep this local copy.")))
$("#summary-choice-form").addEventListener("submit", (event) => { event.preventDefault(); applyRetention("summary_only", $("#summary-choice-text").value).catch(() => announce("Enter and save a summary before removing the transcript.")) })
$("#fade-conversation").addEventListener("click", () => applyRetention("faded").catch(() => announce("Could not clear this local copy.")))
function openReportForm({targetMessageId = null, trigger = $("#report-open")} = {}) {
  app.reportTargetMessageId = targetMessageId
  app.reportReturnFocus = trigger
  const evidence = $("#report-evidence")
  const disclosure = $("#report-target-disclosure")
  evidence.disabled = Boolean(targetMessageId)
  if (targetMessageId) {
    evidence.value = ""
    disclosure.hidden = false
    disclosure.textContent = "This report will use only the server-authoritative text for this specific message if it is still available for safety evidence."
  } else {
    disclosure.hidden = true
    disclosure.textContent = ""
  }
  $("#report-form").hidden = false
  $("#report-form h2").focus()
}

function closeReportForm() {
  $("#report-form").hidden = true
  $("#report-evidence").disabled = false
  app.reportTargetMessageId = null
  const target = app.reportReturnFocus
  app.reportReturnFocus = null
  target?.focus()
}

$("#report-open").addEventListener("click", () => openReportForm())
$("#report-cancel").addEventListener("click", closeReportForm)
$("#report-form").addEventListener("submit", async (event) => {
  event.preventDefault()
  const category = $("#report-category").value
  if (!category) return
  const payload = {category, evidence: app.reportTargetMessageId ? null : ($("#report-evidence").value || null)}
  if (app.reportTargetMessageId) payload.target_client_message_id = app.reportTargetMessageId
  try {
    await push(app.conversation, "conversation:report", payload)
    closeReportForm()
    announce("Report submitted for pending review.")
  } catch (error) {
    handleDomainError(error, {fallbackMessage: "Could not submit the report. Please try again."})
  }
})
$("#block").addEventListener("click", async () => { if (confirm("Block this person from future matches? Reporting is separate.")) { app.liveCall?.teardown("blocked_by_user"); cancelRecording(); await push(app.conversation, "conversation:block"); announce("This person is blocked from future matching.") } })
$("#consent").addEventListener("click", async () => { const result = await push(app.conversation, "relationship:consent"); $("#consent-status").textContent = result.status === "created" ? "Bond created." : "Waiting for mutual consent."; if (result.relationship_id) rememberRelationship(result.relationship_id) })
$("#history-summary-form").addEventListener("submit", async (event) => { event.preventDefault(); const text = $("#history-summary").value.trim(); const summaryId = `summary:${app.historyConversationId}`; if (text) await putRecord({id: summaryId, type: "summary", value: {conversation_id: app.historyConversationId, text}, updated_at: now()}); else { const prior = await getRecord(summaryId); if (prior) await putRecord(tombstoneFor(prior, now())) } const conversation = await getRecord(`conversation:${app.historyConversationId}`); await putRecord({...conversation, value: {...conversation.value, summary_id: text ? summaryId : null}, updated_at: now()}); await maybeAutoSync(); announce("Local summary updated.") })
$("#history-memory").addEventListener("click", async () => { const text = prompt("Memory to save separately on this device:"); if (text?.trim()) { await putRecord({id: `memory:${crypto.randomUUID()}`, type: "memory", value: {text: text.trim(), conversation_id: app.historyConversationId}, updated_at: now()}); await offerContinuity(); await maybeAutoSync(); announce("Memory saved separately.") } })
$("#history-delete").addEventListener("click", async () => { if (!confirm("Delete this kept local conversation and transcript?")) return; const records = await listRecords(); const hasSummary = records.some(({id}) => id === `summary:${app.historyConversationId}`); const deleteSummary = hasSummary && confirm("Also delete its associated summary? Separate Memories will remain."); await replaceWithSyncTombstones(records, deleteKeptConversation(records, app.historyConversationId, {deleteSummary})); releaseAllVoiceUrls(); show("chats") })
$("#delete-kept-all").addEventListener("click", async () => { if (!confirm("Delete all kept local conversations and transcripts?")) return; const records = await listRecords(); const hasSummaries = keptConversations(records).some(({value}) => records.some(({id}) => id === `summary:${value.conversation_id}`)); const deleteSummaries = hasSummaries && confirm("Also delete their associated summaries? Separate Memories will remain."); await replaceWithSyncTombstones(records, deleteAllKeptConversations(records, {deleteSummaries})); releaseAllVoiceUrls(); renderChats() })
$("#memory-form").addEventListener("submit", async (event) => { event.preventDefault(); const text = $("#memory-note").value.trim(); if (!text) return; await putRecord({id: `memory:${crypto.randomUUID()}`, type: "memory", value: {text}, updated_at: now()}); event.target.reset(); renderLocalViews(); await offerContinuity(); await maybeAutoSync() })
$("#reduced-motion").addEventListener("change", async (event) => { document.body.classList.toggle("reduce-motion", event.target.checked); await putRecord({id: "settings:privacy", type: "settings", value: {reduced_motion: event.target.checked}, updated_at: now()}) })
$("#view-data").addEventListener("click", renderDataInventory)
$("#delete-all").addEventListener("click", async () => { if (!confirm("Delete all local StrangerTalks data from this browser? This cannot be undone without an exported backup.")) return; await clearRecords(); releaseAllVoiceUrls(); clearVoicePreview(); app.socket?.disconnect(); app.identity = null; await createIdentity(false); connectSocket(); renderLocalViews(); renderDataInventory(); announce("All prior local data was deleted. A new anonymous identity was created.") })
$("#export-data").addEventListener("click", async () => { const passphrase = prompt("Choose a backup passphrase. It cannot be recovered if lost."); if (!passphrase) return; const envelope = await encryptBackup(await listRecords(), passphrase); const link = document.createElement("a"); link.href = URL.createObjectURL(new Blob([JSON.stringify(envelope)], {type: "application/json"})); link.download = `strangertalks-backup-${now().slice(0, 10)}.json`; link.click(); URL.revokeObjectURL(link.href); announce("Encrypted backup exported. Keep its passphrase safe.") })
$("#import-data").addEventListener("change", async (event) => { const file = event.target.files[0]; if (!file) return; const passphrase = prompt("Enter this backup’s passphrase."); if (!passphrase) return; try { await importRecords(await decryptBackup(JSON.parse(await file.text()), passphrase)); await renderLocalViews(); await renderDataInventory(); announce("Backup merged. Newer records won for matching stable IDs.") } catch { announce("Backup could not be opened. Check the file and passphrase.") } finally { event.target.value = "" } })
$("#account-link").addEventListener("click", () => startGoogle("link").catch(() => announce("Private Google connection could not start.")))
$("#account-login").addEventListener("click", () => startGoogle("login").catch(() => announce("Private Google sign-in could not start.")))
$("#account-reauthorize").addEventListener("click", () => startGoogle("login").catch(() => announce("Google reauthorization could not start. Local data remains.")))
$("#suggest-connect").addEventListener("click", () => startGoogle("link").catch(() => announce("Private Google connection could not start.")))
$("#suggest-dismiss").addEventListener("click", async () => { await putRecord({id: "settings:continuity-suggestion", type: "settings", value: {dismissed: true}, updated_at: now()}); $("#continuity-suggestion").hidden = true })
$("#sync-now").addEventListener("click", () => syncNow().catch((error) => announce(error.message === "passphrase_mismatch" ? "Recovery passphrases did not match." : error.message === "google_reauthorization_required" ? "Google needs to be connected again. Local data was not changed." : "Encrypted sync could not complete.")))
$("#sync-restore").addEventListener("click", () => restoreFromGoogle().catch((error) => announce(error.message === "google_reauthorization_required" ? "Google needs to be connected again. Local data was not changed." : "Encrypted data could not be restored. Check the recovery passphrase.")))
$("#auto-sync").addEventListener("change", async (event) => { await putRecord({id: "settings:auto-sync", type: "settings", value: {enabled: event.target.checked}, updated_at: now()}); announce(event.target.checked ? "Automatic protection is enabled after encrypted sync is unlocked in this browser session." : "Automatic protection is off.") })
$("#sync-delete").addEventListener("click", async () => { if (!confirm("Permanently delete only the encrypted StrangerTalks sync file from Google app data? Local browser data and your private connection will remain.")) return; const response = await accountFetch("/api/account/sync", {method: "DELETE"}); if (response.ok) { app.account.revision = 0; $("#sync-status").textContent = "Encrypted Google sync data was deleted. Local data remains."; announce("Google sync data deleted; this device was not changed.") } })
$("#account-logout").addEventListener("click", async () => { if (!confirm("Sign out only this device? Local browser data remains.")) return; await accountFetch("/api/account/session", {method: "DELETE"}); location.reload() })
$("#account-logout-all").addEventListener("click", async () => { if (!confirm("Sign out every connected device? Local and Google sync data remain.")) return; await accountFetch("/api/account/sessions", {method: "DELETE"}); location.reload() })
$("#account-disconnect").addEventListener("click", async () => { if (!confirm("Disconnect Google and sign out all devices? Bonds and local data remain. Google sync data is not deleted.")) return; await accountFetch("/api/account/google-link", {method: "DELETE"}); location.reload() })

$("#view-once-picker-btn")?.addEventListener("click", () => {
  const input = document.createElement("input")
  input.type = "file"
  input.accept = "image/jpeg,image/png,image/webp"
  input.addEventListener("change", (event) => {
    if (event.target.files && event.target.files[0]) {
      handleViewOnceFileSelected(event.target.files[0])
    }
  })
  input.click()
})
$("#view-once-video-picker-btn")?.addEventListener("click", () => {
  const input = document.createElement("input")
  input.type = "file"
  input.accept = "video/mp4"
  input.addEventListener("change", (event) => {
    if (event.target.files && event.target.files[0]) {
      handleViewOnceVideoSelected(event.target.files[0])
    }
  })
  input.click()
})
$("#view-once-send")?.addEventListener("click", () => sendViewOncePhoto(1))
$("#view-twice-send")?.addEventListener("click", () => sendViewOncePhoto(2))
$("#view-once-video-send")?.addEventListener("click", () => sendViewOnceVideo(1))
$("#view-twice-video-send")?.addEventListener("click", () => sendViewOnceVideo(2))
$("#view-once-preview-cancel")?.addEventListener("click", () => clearViewOncePreview())
$("#view-once-viewer-close")?.addEventListener("click", () => closeViewOnceModal())
$("#view-once-viewer-backdrop")?.addEventListener("click", (event) => {
  if (event.target === event.currentTarget) closeViewOnceModal()
})
window.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !$("#view-once-viewer-backdrop")?.hidden) {
    closeViewOnceModal()
  }
})
window.addEventListener("beforeunload", () => {
  app.liveCall?.teardown()
  closeViewOnceModal()
  clearViewOncePreview()
})

let strangerRingInstance = null

function getStrangerRing() {
  if (!strangerRingInstance) {
    const el = $("#stranger-call-ring")
    const a11yEl = $("#ring-a11y-status")
    if (el) {
      strangerRingInstance = new StrangerTalksRing(el, a11yEl)
    }
  }
  return strangerRingInstance
}

function displayReaction(payload) {
  const container = $("#live-call-reaction-display")
  if (!container) return

  const item = document.createElement("div")
  item.className = "floating-reaction"
  item.setAttribute("role", "status")
  item.innerHTML = `<span>${payload.emoji || "❤️"}</span> <span class="sr-only">${payload.label || "Reaction"}</span>`
  container.appendChild(item)

  const ring = getStrangerRing()
  ring?.pulseReaction()

  setTimeout(() => {
    try {
      if (item.parentNode === container) {
        container.removeChild(item)
      }
    } catch {}
  }, 2000)
}

function initLiveCallCoordinator() {
  if (app.liveCall) return app.liveCall

  const localVideoEl = $("#live-call-local-video")
  const remoteVideoEl = $("#live-call-remote-video")

  app.liveCall = new LiveCallCoordinator({
    participantId: app.identity?.participant_id,
    conversationId: app.conversationId,
    onStateChange: (state) => {
      renderLiveCallState(state)
      const ring = getStrangerRing()
      ring?.update(state)
    },
    onReaction: (payload) => {
      displayReaction(payload)
    },
    onReturnToVoice: () => {
      announce("Returned to voice. Video is closed.")
    },
    onRemoteStream: (stream) => {
      const audioEl = $("#live-call-remote-audio")
      if (audioEl) {
        attachMediaStream(audioEl, stream)
      }
      const videoEl = $("#live-call-remote-video")
      if (videoEl) {
        const hasVideo = stream.getVideoTracks && stream.getVideoTracks().length > 0
        if (hasVideo && !app.liveCall?.localVisualFloorClosed) {
          videoEl.hidden = false
          attachMediaStream(videoEl, stream)
        } else {
          videoEl.hidden = true
        }
      }
      if (app.ambient && app.ambient.isPlaying) {
        app.ambient.pause()
      }
    },
    onLocalStream: (stream) => {
      const videoEl = $("#live-call-local-video")
      if (videoEl) {
        const hasVideo = stream.getVideoTracks && stream.getVideoTracks().length > 0
        if (hasVideo && !app.liveCall?.localVisualFloorClosed) {
          videoEl.hidden = false
          attachMediaStream(videoEl, stream)
        } else {
          videoEl.hidden = true
        }
      }
      cancelRecording()
    },
    onError: () => {
      announce("Live call encountered an issue.")
    }
  })

  app.liveCall.setVideoElements(localVideoEl, remoteVideoEl)
  return app.liveCall
}

function renderLiveCallState(state) {
  const incomingModal = $("#live-call-incoming")
  const activePanel = $("#live-call-active")
  const statusEl = $("#live-call-status")
  const muteBtn = $("#btn-call-toggle-mute")
  const peerMutedBadge = $("#live-call-peer-muted-badge")
  const peerEffectBadge = $("#live-call-peer-effect-badge")
  const effectSelect = $("#live-call-voice-expression")
  const videoToggleBtn = $("#btn-call-toggle-video")
  const returnToVoiceBtn = $("#btn-call-return-to-voice")
  const ring = getStrangerRing()

  if (state.status === CALL_STATUS.PENDING_INCOMING) {
    if (incomingModal) incomingModal.hidden = false
    if (activePanel) activePanel.hidden = true
    cancelRecording()
    ring?.update(state)
  } else if (state.status === CALL_STATUS.PENDING_OUTGOING) {
    if (incomingModal) incomingModal.hidden = true
    if (activePanel) activePanel.hidden = false
    if (statusEl) statusEl.textContent = "Calling…"
    ring?.update(state)
  } else if (state.status === CALL_STATUS.CONNECTING || state.status === CALL_STATUS.ACTIVE) {
    if (incomingModal) incomingModal.hidden = true
    if (activePanel) activePanel.hidden = false
    if (statusEl) statusEl.textContent = state.status === CALL_STATUS.CONNECTING ? "Connecting…" : "Call Active"
    if (muteBtn) {
      muteBtn.setAttribute("aria-pressed", state.selfMuted ? "true" : "false")
      muteBtn.textContent = state.selfMuted ? "Unmute" : "Mute"
    }
    if (peerMutedBadge) {
      peerMutedBadge.hidden = !state.peerMuted
    }
    if (peerEffectBadge) {
      peerEffectBadge.hidden = !state.peerVoiceEffectActive
    }
    if (effectSelect && effectSelect.value !== state.voiceEffectPreset) {
      effectSelect.value = state.voiceEffectPreset || "plain"
    }

    // Return to Voice button visibility
    const isVideoActive = (state.selfVideo || state.peerVideo) && !state.localVisualFloorClosed
    if (returnToVoiceBtn) {
      returnToVoiceBtn.hidden = !isVideoActive
    }
    if (videoToggleBtn) {
      videoToggleBtn.hidden = isVideoActive
    }

    ring?.update(state)
  } else {
    if (incomingModal) incomingModal.hidden = true
    if (activePanel) activePanel.hidden = true
    if (effectSelect) {
      effectSelect.value = "plain"
    }
    if (returnToVoiceBtn) {
      returnToVoiceBtn.hidden = true
    }
    if (videoToggleBtn) {
      videoToggleBtn.hidden = false
    }
    const remoteVideo = $("#live-call-remote-video")
    if (remoteVideo) { remoteVideo.hidden = true; remoteVideo.srcObject = null }
    const localVideo = $("#live-call-local-video")
    if (localVideo) { localVideo.hidden = true; localVideo.srcObject = null }
    const remoteAudio = $("#live-call-remote-audio")
    if (remoteAudio) { remoteAudio.srcObject = null }
    const reactionDisplay = $("#live-call-reaction-display")
    if (reactionDisplay) { reactionDisplay.innerHTML = "" }
    ring?.update(state)
  }
}

function applyCallStateSync(callState) {
  if (!callState) return
  const coord = initLiveCallCoordinator()
  if (callState.status === "ACTIVE" || callState.status === "CONNECTING") {
    coord.callAttemptId = callState.call_attempt_id
    coord.role = callState.role
    coord.callType = callState.call_type
    coord.mediaGeneration = callState.media_generation || 1
    coord.selfMuted = callState.self_muted || false
    coord.peerMuted = callState.peer_muted || false
    coord.activeAt = callState.active_at
    coord.status = callState.status === "ACTIVE" ? CALL_STATUS.ACTIVE : CALL_STATUS.CONNECTING
    renderLiveCallState(coord.getState())
  } else if (callState.status === "PENDING") {
    coord.callAttemptId = callState.call_attempt_id
    coord.role = callState.role
    coord.callType = callState.call_type
    coord.status = callState.role === "caller" ? CALL_STATUS.PENDING_OUTGOING : CALL_STATUS.PENDING_INCOMING
    renderLiveCallState(coord.getState())
  }
}

$("#btn-voice-call")?.addEventListener("click", async () => {
  try {
    initLiveCallCoordinator()
    await app.liveCall.initiate("voice")
  } catch {
    announce("Could not start voice call.")
  }
})

$("#btn-video-call")?.addEventListener("click", async () => {
  try {
    initLiveCallCoordinator()
    await app.liveCall.initiate("video")
  } catch {
    announce("Could not start video call.")
  }
})

$("#btn-call-accept")?.addEventListener("click", async () => {
  try {
    await app.liveCall?.accept()
  } catch {
    announce("Could not accept call.")
  }
})

$("#btn-call-decline")?.addEventListener("click", async () => {
  await app.liveCall?.decline()
})

$("#btn-call-toggle-mute")?.addEventListener("click", async () => {
  await app.liveCall?.toggleMute()
})

$("#live-call-voice-expression")?.addEventListener("change", async (e) => {
  await app.liveCall?.setVoiceExpression(e.target.value)
})

$("#btn-call-toggle-video")?.addEventListener("click", async () => {
  await app.liveCall?.requestMediaUpgrade("video_upgrade")
})

$("#btn-call-return-to-voice")?.addEventListener("click", async () => {
  try {
    await app.liveCall?.returnToVoice()
  } catch {
    announce("Could not return to voice.")
  }
})



document.querySelectorAll(".btn-call-reaction")?.forEach((btn) => {
  btn.addEventListener("click", async () => {
    const reaction = btn.dataset.reaction || "heart"
    try {
      await app.liveCall?.sendReaction(reaction)
    } catch {
      // Ignore reaction errors
    }
  })
})

$("#btn-call-end")?.addEventListener("click", async () => {
  await app.liveCall?.end()
})

function initReflectionManager() {
  if (!app.reflections) {
    app.reflections = new ReflectionManager({
      apiBase: "/api",
      getAuthToken: () => app.identity?.token || app.identity?.participant_token,
      onNotify: (event) => {
        if (event === "undo_window_closed") {
          $("#reflection-toast").hidden = true
        }
      }
    })
  }
  return app.reflections
}

async function openReflectionComposerForMessage(message) {
  const manager = initReflectionManager()
  const messageId = message.client_message_id || message.message_id
  const content = message.content || ""

  const totalGraphemes = Array.from(content).length
  const endGrapheme = Math.min(totalGraphemes, 280)
  const excerpt = Array.from(content).slice(0, endGrapheme).join("")

  try {
    const grantInfo = await manager.requestGrant({
      conversationId: app.conversationId,
      clientMessageId: messageId,
      expectedRevision: message.content_revision || 0,
      startGrapheme: 0,
      endGrapheme: endGrapheme
    })

    $("#reflection-source-text").textContent = grantInfo.excerpt || excerpt
    $("#reflection-source-preview").hidden = false
  } catch (err) {
    manager.clearGrant()
    $("#reflection-source-preview").hidden = true
  }

  $("#reflection-note-input").value = ""
  $("#reflection-char-count").textContent = "0"
  $("#reflection-composer-backdrop").hidden = false
  $("#reflection-note-input").focus()
}

async function loadAndRenderReflections() {
  const manager = initReflectionManager()
  try {
    const list = await manager.listReflections()
    const container = $("#reflections-list")
    const emptyState = $("#reflections-empty")
    if (!container) return
    container.replaceChildren()
    if (!list || list.length === 0) {
      if (emptyState) emptyState.hidden = false
      return
    }
    if (emptyState) emptyState.hidden = true
    for (const item of list) {
      const card = document.createElement("div")
      card.className = "reflection-card"
      card.dataset.reflectionId = item.reflection_id
      card.dataset.revision = String(item.revision)

      if (item.source_excerpt) {
        const quote = document.createElement("blockquote")
        quote.textContent = item.source_excerpt
        card.append(quote)
      }

      const note = document.createElement("p")
      note.className = "reflection-note-text"
      note.textContent = item.own_reflection_text
      card.append(note)

      const time = document.createElement("time")
      time.textContent = new Date(item.saved_at).toLocaleString()
      time.style.fontSize = "0.75rem"
      time.style.color = "rgba(255, 252, 235, 0.5)"
      card.append(time)

      const actions = document.createElement("div")
      actions.className = "reflection-card-actions"

      if (item.source_excerpt) {
        const removeExcerptBtn = document.createElement("button")
        removeExcerptBtn.type = "button"
        removeExcerptBtn.className = "quiet-action"
        removeExcerptBtn.textContent = "Remove excerpt"
        removeExcerptBtn.addEventListener("click", async () => {
          try {
            await manager.removeExcerpt(item.reflection_id, item.revision)
            await loadAndRenderReflections()
            announce("Excerpt removed.")
          } catch (err) {
            announce("Could not remove excerpt.")
          }
        })
        actions.append(removeExcerptBtn)
      }

      const deleteBtn = document.createElement("button")
      deleteBtn.type = "button"
      deleteBtn.className = "danger-action"
      deleteBtn.textContent = "Delete"
      deleteBtn.addEventListener("click", async () => {
        try {
          await manager.deleteReflection(item.reflection_id, item.revision)
          await loadAndRenderReflections()
          announce("Reflection deleted.")
        } catch (err) {
          announce("Could not delete reflection.")
        }
      })
      actions.append(deleteBtn)

      card.append(actions)
      container.append(card)
    }
  } catch (err) {
    // Ignore fetch error in local view
  }
}

$("#reflection-note-input")?.addEventListener("input", (e) => {
  const count = Array.from(e.target.value).length
  $("#reflection-char-count").textContent = String(count)
})

$("#reflection-form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  const note = $("#reflection-note-input").value.trim()
  if (!note) return
  const manager = initReflectionManager()
  try {
    $("#reflection-save-btn").disabled = true
    await manager.saveReflection({ ownReflectionText: note })
    $("#reflection-composer-backdrop").hidden = true
    $("#reflection-note-input").value = ""
    $("#reflection-toast").hidden = false
    $("#reflection-toast-msg").textContent = "Saved to Reflections"
    announce("Reflection saved.")
  } catch (err) {
    announce("Could not save reflection: " + (err.message || "error"))
  } finally {
    $("#reflection-save-btn").disabled = false
  }
})

$("#reflection-undo-btn")?.addEventListener("click", async () => {
  const manager = initReflectionManager()
  try {
    await manager.undoLastSave()
    $("#reflection-toast").hidden = true
    announce("Reflection save undone.")
  } catch (err) {
    announce("Could not undo save: " + (err.message || "error"))
  }
})

$("#reflection-composer-close")?.addEventListener("click", () => {
  $("#reflection-composer-backdrop").hidden = true
})

$("#reflection-cancel-btn")?.addEventListener("click", () => {
  $("#reflection-composer-backdrop").hidden = true
})

$("#reflection-clear-source")?.addEventListener("click", () => {
  const manager = initReflectionManager()
  manager.clearGrant()
  $("#reflection-source-preview").hidden = true
})

initializeAmbientAudio()
renderAtmosphereCatalog()
renderPromptCardsUI()
renderLocalViews().catch(() => {})
app.voice.mediaType = selectVoiceMediaType(globalThis.MediaRecorder)
if (!app.voice.mediaType || !navigator.mediaDevices?.getUserMedia) { $("#voice-start").disabled = true; $("#voice-unavailable").hidden = false; $("#voice-unavailable").textContent = "Voice recording is unavailable in this browser. Text messaging still works." }
const languageSelect = $("#conversation-language")
CONVERSATION_LANGUAGES.forEach(({label, value}) => {
  const option = document.createElement("option")
  option.value = value
  option.textContent = label
  languageSelect.append(option)
})
if (CONVERSATION_LANGUAGES.some(({value}) => value === app.conversationLanguage)) languageSelect.value = app.conversationLanguage
languageSelect.addEventListener("change", () => {
  app.conversationLanguage = languageSelect.value || null
  if (app.conversationLanguage) localStorage.setItem(conversationLanguageKey, app.conversationLanguage)
  else localStorage.removeItem(conversationLanguageKey)
})

ensureBootstrap().then(async () => { const settings = await getRecord("settings:privacy"); if (settings?.value.reduced_motion) { $("#reduced-motion").checked = true; document.body.classList.add("reduce-motion") } const accountResult = new URLSearchParams(location.search).get("account"); if (accountResult === "connected" && app.account.connected) await restoreFromGoogle(true).catch(() => announce("Connected privately. Unlock encrypted sync from You when you are ready.")); if (accountResult) history.replaceState(history.state, "", location.pathname) }).catch(() => announce("StrangerTalks could not start. Please reload."))
