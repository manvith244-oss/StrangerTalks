const FOUR_DOOR_INTENTS = new Set(["SOMETHING_REAL", "JUST_TALK", "KEEP_IT_LIGHT", "EXPLORE"])
const TALK_LANGUAGE_CODES = new Set(["en", "te", "hi"])
const TALK_LANGUAGE_OPEN_TRIGGERS = new Set(["direct", "required_after_intent"])
const TALK_LANGUAGE_SOURCES = new Set(["remembered", "new", "changed"])
const DEVICE_CLASSES = new Set(["mobile", "tablet", "desktop", "unknown"])
const FLOW_CANCELLATIONS = new Set(["queue:user_requested"])

const EVENT_SCHEMAS = Object.freeze({
  st_entrance_ready: Object.freeze({
    required: Object.freeze(["remembered_talk_language", "device_class"]),
    properties: Object.freeze({
      remembered_talk_language: (value) => typeof value === "boolean",
      device_class: (value) => DEVICE_CLASSES.has(value),
      build_id: (value) => typeof value === "string" && value.length > 0
    })
  }),
  st_intent_selected: Object.freeze({
    required: Object.freeze(["intent_family", "intent_value", "selection_kind"]),
    properties: Object.freeze({
      intent_family: (value) => value === "four_doors",
      intent_value: (value) => FOUR_DOOR_INTENTS.has(value),
      selection_kind: (value) => value === "first"
    })
  }),
  st_intent_changed: Object.freeze({
    required: Object.freeze(["from_intent", "to_intent"]),
    properties: Object.freeze({
      from_intent: (value) => FOUR_DOOR_INTENTS.has(value),
      to_intent: (value) => FOUR_DOOR_INTENTS.has(value)
    }),
    validate: (properties) => properties.from_intent !== properties.to_intent
  }),
  st_talk_language_opened: Object.freeze({
    required: Object.freeze(["trigger"]),
    properties: Object.freeze({
      trigger: (value) => TALK_LANGUAGE_OPEN_TRIGGERS.has(value)
    })
  }),
  st_talk_language_selected: Object.freeze({
    required: Object.freeze(["language_code", "source"]),
    properties: Object.freeze({
      language_code: (value) => TALK_LANGUAGE_CODES.has(value),
      source: (value) => TALK_LANGUAGE_SOURCES.has(value),
      trigger: (value) => TALK_LANGUAGE_OPEN_TRIGGERS.has(value)
    })
  }),
  st_queue_requested: Object.freeze({
    required: Object.freeze(["intent_code", "interaction_language"]),
    properties: Object.freeze({
      intent_code: (value) => FOUR_DOOR_INTENTS.has(value),
      interaction_language: (value) => TALK_LANGUAGE_CODES.has(value)
    })
  }),
  st_queue_joined: Object.freeze({
    required: Object.freeze(["intent_code"]),
    properties: Object.freeze({intent_code: (value) => FOUR_DOOR_INTENTS.has(value)})
  }),
  st_match_created: Object.freeze({
    required: Object.freeze(["intent_code"]),
    properties: Object.freeze({intent_code: (value) => FOUR_DOOR_INTENTS.has(value)})
  }),
  st_first_message_accepted: Object.freeze({
    required: Object.freeze([]),
    properties: Object.freeze({})
  }),
  st_flow_cancelled: Object.freeze({
    required: Object.freeze(["stage", "reason_code"]),
    properties: Object.freeze({
      stage: (value) => value === "queue",
      reason_code: (value) => value === "user_requested"
    }),
    validate: (properties) => FLOW_CANCELLATIONS.has(`${properties.stage}:${properties.reason_code}`)
  })
})

export const PRODUCT_EVENT_NAMES = Object.freeze(Object.keys(EVENT_SCHEMAS))

function defaultUuid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()
  return `flow-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function isIntentCode(value) {
  return FOUR_DOOR_INTENTS.has(value)
}

function isTalkLanguageCode(value) {
  return TALK_LANGUAGE_CODES.has(value)
}

function sanitizeEvent(name, properties, flowAttemptId, testTraffic) {
  const schema = EVENT_SCHEMAS[name]
  if (!schema) return null

  const source = properties && typeof properties === "object" ? properties : {}
  const sanitized = {flow_attempt_id: flowAttemptId, test_traffic: testTraffic}

  for (const [property, validator] of Object.entries(schema.properties)) {
    if (!Object.hasOwn(source, property)) continue
    const value = source[property]
    if (!validator(value)) return null
    sanitized[property] = value
  }

  for (const property of schema.required) {
    if (!Object.hasOwn(sanitized, property)) return null
  }

  if (schema.validate && !schema.validate(sanitized)) return null
  return {name, properties: sanitized}
}

function createFlowSynchronizer(tracker, resetState) {
  let flowAttemptId = tracker.flowAttemptId
  return () => {
    if (flowAttemptId === tracker.flowAttemptId) return
    flowAttemptId = tracker.flowAttemptId
    resetState()
  }
}

export function createProductEventTracker(options = {}) {
  const uuid = typeof options.uuid === "function" ? options.uuid : defaultUuid
  const sink = typeof options.sink === "function" ? options.sink : async () => {}
  const testTraffic = options.testTraffic === true
  const capturedOnce = new Set()
  let flowAttemptId = uuid()

  async function deliver(event) {
    try {
      await sink(event)
      return true
    } catch (_error) {
      return false
    }
  }

  async function capture(name, properties = {}) {
    const event = sanitizeEvent(name, properties, flowAttemptId, testTraffic)
    if (!event) return false
    return deliver(event)
  }

  async function captureOnce(name, properties = {}) {
    const event = sanitizeEvent(name, properties, flowAttemptId, testTraffic)
    if (!event || capturedOnce.has(name)) return false
    capturedOnce.add(name)
    return deliver(event)
  }

  function resetFlow() {
    flowAttemptId = uuid()
    capturedOnce.clear()
    return flowAttemptId
  }

  return {
    get flowAttemptId() { return flowAttemptId },
    capture,
    captureOnce,
    resetFlow
  }
}

export function createIntentSelectionObserver(tracker) {
  let selectedIntent = null
  let queueJoined = false
  const syncFlow = createFlowSynchronizer(tracker, () => {
    selectedIntent = null
    queueJoined = false
  })

  return {
    async select(intentValue) {
      syncFlow()
      if (queueJoined || !isIntentCode(intentValue)) return false
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
      return tracker.capture("st_intent_changed", {from_intent: fromIntent, to_intent: intentValue})
    },
    markQueueJoined() {
      syncFlow()
      queueJoined = true
    }
  }
}

function validLanguageCode(languageCode, validLanguages) {
  if (!isTalkLanguageCode(languageCode)) return false
  if (validLanguages instanceof Set) return validLanguages.has(languageCode)
  return Array.isArray(validLanguages) && validLanguages.includes(languageCode)
}

export function createTalkLanguageObserver(tracker) {
  let currentLanguage = null
  let rememberedRecorded = false
  const syncFlow = createFlowSynchronizer(tracker, () => {
    currentLanguage = null
    rememberedRecorded = false
  })

  return {
    opened(trigger) {
      syncFlow()
      if (!TALK_LANGUAGE_OPEN_TRIGGERS.has(trigger)) return Promise.resolve(false)
      return tracker.capture("st_talk_language_opened", {trigger})
    },
    async remembered(languageCode, validLanguages) {
      syncFlow()
      if (!validLanguageCode(languageCode, validLanguages)) return false
      if (rememberedRecorded && currentLanguage === languageCode) return false
      currentLanguage = languageCode
      rememberedRecorded = true
      return tracker.capture("st_talk_language_selected", {language_code: languageCode, source: "remembered"})
    },
    async selected(languageCode, validLanguages) {
      syncFlow()
      if (!validLanguageCode(languageCode, validLanguages)) return false
      if (currentLanguage === languageCode) return false
      const source = currentLanguage ? "changed" : "new"
      currentLanguage = languageCode
      return tracker.capture("st_talk_language_selected", {language_code: languageCode, source})
    }
  }
}

export function createQueueEventObserver(tracker) {
  let intentCode = null
  let interactionLanguage = null
  let requestCapturePromise = null
  let joinedCapturePromise = null
  let matchedCapturePromise = null
  let queueJoinedInFlow = false
  let matchedInFlow = false

  const resetState = () => {
    intentCode = null
    interactionLanguage = null
    requestCapturePromise = null
    joinedCapturePromise = null
    matchedCapturePromise = null
    queueJoinedInFlow = false
    matchedInFlow = false
  }
  const syncFlow = createFlowSynchronizer(tracker, resetState)

  return {
    requested(nextIntentCode, nextInteractionLanguage) {
      syncFlow()
      if (!isIntentCode(nextIntentCode) || !isTalkLanguageCode(nextInteractionLanguage)) return Promise.resolve(false)
      if (queueJoinedInFlow || joinedCapturePromise) return Promise.resolve(false)

      intentCode = nextIntentCode
      interactionLanguage = nextInteractionLanguage
      matchedCapturePromise = null
      matchedInFlow = false

      const flowAttemptId = tracker.flowAttemptId
      const capturedIntentCode = nextIntentCode
      const capturedLanguage = nextInteractionLanguage
      const capturePromise = tracker.capture("st_queue_requested", {
        intent_code: capturedIntentCode,
        interaction_language: capturedLanguage
      })
      requestCapturePromise = capturePromise
      return capturePromise.then((recorded) => {
        if (tracker.flowAttemptId !== flowAttemptId || requestCapturePromise !== capturePromise) return false
        return recorded
      })
    },
    joined() {
      syncFlow()
      if (!intentCode || !interactionLanguage || !requestCapturePromise) return Promise.resolve(false)
      if (queueJoinedInFlow || joinedCapturePromise) return Promise.resolve(false)

      const flowAttemptId = tracker.flowAttemptId
      const prerequisite = requestCapturePromise
      const capturedIntentCode = intentCode
      const capturePromise = (async () => {
        if (!(await prerequisite)) return false
        if (tracker.flowAttemptId !== flowAttemptId || requestCapturePromise !== prerequisite) return false
        const recorded = await tracker.captureOnce("st_queue_joined", {intent_code: capturedIntentCode})
        if (recorded && tracker.flowAttemptId === flowAttemptId && joinedCapturePromise === capturePromise) {
          queueJoinedInFlow = true
        }
        return recorded
      })()
      joinedCapturePromise = capturePromise
      return capturePromise
    },
    matched() {
      syncFlow()
      if (!intentCode || !interactionLanguage) return Promise.resolve(false)
      if ((!queueJoinedInFlow && !joinedCapturePromise) || matchedInFlow || matchedCapturePromise) return Promise.resolve(false)

      const flowAttemptId = tracker.flowAttemptId
      const prerequisite = joinedCapturePromise
      const capturedIntentCode = intentCode
      const capturePromise = (async () => {
        if (prerequisite && !(await prerequisite)) return false
        if (tracker.flowAttemptId !== flowAttemptId) return false
        if (!queueJoinedInFlow) return false
        const recorded = await tracker.captureOnce("st_match_created", {intent_code: capturedIntentCode})
        if (recorded && tracker.flowAttemptId === flowAttemptId && matchedCapturePromise === capturePromise) {
          matchedInFlow = true
        }
        return recorded
      })()
      matchedCapturePromise = capturePromise
      return capturePromise
    },
    firstMessageAccepted() {
      syncFlow()
      if (!matchedInFlow && !matchedCapturePromise) return Promise.resolve(false)

      const flowAttemptId = tracker.flowAttemptId
      const prerequisite = matchedCapturePromise
      return (async () => {
        if (prerequisite && !(await prerequisite)) return false
        if (tracker.flowAttemptId !== flowAttemptId || !matchedInFlow) return false
        return tracker.captureOnce("st_first_message_accepted")
      })()
    }
  }
}

export function captureFlowCancelled(tracker, options = {}) {
  const stage = options.stage
  const reasonCode = options.reasonCode
  if (!FLOW_CANCELLATIONS.has(`${stage}:${reasonCode}`)) return Promise.resolve(false)

  const captured = tracker.captureOnce("st_flow_cancelled", {stage, reason_code: reasonCode})
  tracker.resetFlow()
  return captured
}

export function deviceClassForWidth(width) {
  if (!Number.isFinite(width) || width < 0) return "unknown"
  if (width < 768) return "mobile"
  if (width < 1024) return "tablet"
  return "desktop"
}

export function captureEntranceReady(tracker, options = {}) {
  const properties = {
    remembered_talk_language: isTalkLanguageCode(options.rememberedTalkLanguage),
    device_class: deviceClassForWidth(options.viewportWidth)
  }
  if (typeof options.buildId === "string" && options.buildId) properties.build_id = options.buildId
  return tracker.captureOnce("st_entrance_ready", properties)
}

export function createEntranceAttemptCoordinator(tracker) {
  let lastEntranceFlowAttemptId = null

  return {
    entranceReady(options = {}, {newAttempt = false} = {}) {
      if (newAttempt && (lastEntranceFlowAttemptId === null || tracker.flowAttemptId === lastEntranceFlowAttemptId)) {
        tracker.resetFlow()
      }
      lastEntranceFlowAttemptId = tracker.flowAttemptId
      return captureEntranceReady(tracker, options)
    }
  }
}

async function runtimeSink(event) {
  const sink = globalThis.__strangerTalksProductEventSink
  if (typeof sink === "function") return sink(event)
}

export const productEvents = createProductEventTracker({
  sink: runtimeSink,
  testTraffic: globalThis.__strangerTalksTestTraffic === true
})

export const entranceAttempts = createEntranceAttemptCoordinator(productEvents)
export const intentEvents = createIntentSelectionObserver(productEvents)
export const talkLanguageEvents = createTalkLanguageObserver(productEvents)
export const queueEvents = createQueueEventObserver(productEvents)
