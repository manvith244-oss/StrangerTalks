import "./arrival_first_minute.mjs"
import "./interface_language_placement.mjs"
import "./secondary_flow.mjs"
import {futureConversationLanguageForQueue} from "./f11_persistence_runtime.mjs"
import {DOORS, CONVERSATION_LANGUAGES} from "./conversation_catalog.mjs"

export {DOORS, CONVERSATION_LANGUAGES}

export function backendDoorFor(label) {
  return DOORS.find((door) => door.label === label)?.value ?? null
}

export function doorLabelForBackend(value) {
  return DOORS.find((door) => door.value === value)?.label ?? null
}

export function queuePayloadFor(label, conversationLanguage) {
  const door_type = backendDoorFor(label)
  const futureLanguage = futureConversationLanguageForQueue(conversationLanguage)
  const validLanguage = CONVERSATION_LANGUAGES.some(({value}) => value === futureLanguage)
  return door_type && validLanguage ? {door_type, conversation_language: futureLanguage} : null
}
