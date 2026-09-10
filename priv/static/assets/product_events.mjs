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
