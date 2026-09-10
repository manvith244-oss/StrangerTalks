const EVENT_PROPERTIES = Object.freeze({
  st_entrance_ready: Object.freeze(["remembered_talk_language", "device_class", "build_id"]),
  st_intent_selected: Object.freeze(["intent_family", "intent_value", "selection_kind"]),
  st_intent_changed: Object.freeze(["from_intent", "to_intent"]),
  st_talk_language_opened: Object.freeze(["trigger"]),
  st_talk_language_selected: Object.freeze(["language_code", "source", "trigger"]),
  st_queue_requested: Object.freeze(["intent_code", "interaction_language"]),
  st_queue_admitted: Object.freeze(["intent_code"]),
  st_match_created: Object.freeze(["intent_code"]),
  st_first_message_accepted: Object.freeze(["message_type"]),
  st_flow_cancelled: Object.freeze(["stage", "reason_code"])
})

const TALK_LANGUAGE_OPEN_TRIGGERS = new Set(["direct", "required_after_intent"])

export const PRODUCT_EVENT_NAMES = Object.freeze(Object.keys(EVENT_PROPERTIES))

function defaultUuid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()
  return `flow-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function sanitizeEvent(name, properties, flowAttemptId, testTraffic) {
  const allowedProperties = EVENT_PROPERTIES[name]
  if (!allowedProperties) return null

  const source = properties && typeof properties === "object" ? properties : {}
  const sanitized = {
    flow_attempt_id: flowAttemptId,
    test_traffic: testTraffic
  }

  for (const property of allowedProperties) {
    if (Object.hasOwn(source, property)) sanitized[property] = source[property]
  }

  return {name, properties: sanitized}
}

export function createProductEventTracker(options = {}) {
  const uuid = typeof options.uuid === "function" ? options.uuid : defaultUuid
  const sink = typeof options.sink === "function" ? options.sink : async () => {}
  const testTraffic = options.testTraffic === true
  const capturedOnce = new Set()
  let flowAttemptId = uuid()

  async function capture(name, properties = {}) {
    const event = sanitizeEvent(name, properties, flowAttemptId, testTraffic)
    if (!event) return false

    try {
      await sink(event)
      return true
    } catch (_error) {
      return false
    }
  }

  async function captureOnce(name, properties = {}) {
    if (!EVENT_PROPERTIES[name] || capturedOnce.has(name)) return false
    capturedOnce.add(name)
    return capture(name, properties)
  }

  function resetFlow() {
    flowAttemptId = uuid()
    capturedOnce.clear()
    return flowAttemptId
  }

  return {
    get flowAttemptId() {
      return flowAttemptId
    },
    capture,
    captureOnce,
    resetFlow
  }
}

export function createIntentSelectionObserver(tracker) {
  let selectedIntent = null
  let queueAdmitted = false

  return {
    async select(intentValue) {
      if (queueAdmitted || typeof intentValue !== "string" || !intentValue) return false
      if (intentValue === selectedIntent) return false

      if (selectedIntent === null) {
        selectedIntent = intentValue
        return tracker.capture("st_intent_selected", {
          intent_family: "four_doors",
          intent_value: intentValue,
          selection_kind: "first"
        })
      }

      const fromIntent = selectedIntent
      selectedIntent = intentValue
      return tracker.capture("st_intent_changed", {
        from_intent: fromIntent,
        to_intent: intentValue
      })
    },
    markQueueAdmitted() {
      queueAdmitted = true
    }
  }
}

function validLanguageCode(languageCode, validLanguages) {
  if (typeof languageCode !== "string" || !languageCode) return false
  if (validLanguages instanceof Set) return validLanguages.has(languageCode)
  return Array.isArray(validLanguages) && validLanguages.includes(languageCode)
}

export function createTalkLanguageObserver(tracker) {
  let currentLanguage = null
  let rememberedRecorded = false

  return {
    opened(trigger) {
      if (!TALK_LANGUAGE_OPEN_TRIGGERS.has(trigger)) return Promise.resolve(false)
      return tracker.capture("st_talk_language_opened", {trigger})
    },
    async remembered(languageCode, validLanguages) {
      if (!validLanguageCode(languageCode, validLanguages)) return false
      if (rememberedRecorded && currentLanguage === languageCode) return false
      currentLanguage = languageCode
      rememberedRecorded = true
      return tracker.capture("st_talk_language_selected", {
        language_code: languageCode,
        source: "remembered"
      })
    },
    async selected(languageCode, validLanguages) {
      if (!validLanguageCode(languageCode, validLanguages)) return false
      if (currentLanguage === languageCode) return false
      const source = currentLanguage ? "changed" : "new"
      currentLanguage = languageCode
      return tracker.capture("st_talk_language_selected", {
        language_code: languageCode,
        source
      })
    }
  }
}

export function createQueueEventObserver(tracker) {
  let intentCode = null
  let interactionLanguage = null

  return {
    requested(nextIntentCode, nextInteractionLanguage) {
      if (typeof nextIntentCode !== "string" || !nextIntentCode) return Promise.resolve(false)
      if (typeof nextInteractionLanguage !== "string" || !nextInteractionLanguage) return Promise.resolve(false)
      intentCode = nextIntentCode
      interactionLanguage = nextInteractionLanguage
      return tracker.capture("st_queue_requested", {
        intent_code: intentCode,
        interaction_language: interactionLanguage
      })
    },
    admitted() {
      if (!intentCode || !interactionLanguage) return Promise.resolve(false)
      return tracker.captureOnce("st_queue_admitted", {intent_code: intentCode})
    },
    matched() {
      if (!intentCode || !interactionLanguage) return Promise.resolve(false)
      return tracker.captureOnce("st_match_created", {intent_code: intentCode})
    }
  }
}

export function captureFirstMessageAccepted(tracker) {
  return tracker.captureOnce("st_first_message_accepted")
}

export function deviceClassForWidth(width) {
  if (!Number.isFinite(width) || width < 0) return "unknown"
  if (width < 768) return "mobile"
  if (width < 1024) return "tablet"
  return "desktop"
}

export function captureEntranceReady(tracker, options = {}) {
  const properties = {
    remembered_talk_language: Boolean(options.rememberedTalkLanguage),
    device_class: deviceClassForWidth(options.viewportWidth)
  }
  if (typeof options.buildId === "string" && options.buildId) properties.build_id = options.buildId
  return tracker.captureOnce("st_entrance_ready", properties)
}

async function runtimeSink(event) {
  const sink = globalThis.__strangerTalksProductEventSink
  if (typeof sink === "function") return sink(event)
}

export const productEvents = createProductEventTracker({
  sink: runtimeSink,
  testTraffic: globalThis.__strangerTalksTestTraffic === true
})

export const talkLanguageEvents = createTalkLanguageObserver(productEvents)
export const queueEvents = createQueueEventObserver(productEvents)
