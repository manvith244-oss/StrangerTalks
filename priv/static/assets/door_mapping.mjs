// V1 presentation aliases for the existing canonical backend Door values.
export const DOORS = Object.freeze([
  {label: "Deep Talk", value: "SOMETHING_REAL", description: "Talk about something real."},
  {label: "Vent", value: "JUST_TALK", description: "Say what's on your mind."},
  {label: "Distract", value: "KEEP_IT_LIGHT", description: "Keep things light."},
  {label: "Advice", value: "EXPLORE", description: "Get another perspective."}
])

export const CONVERSATION_LANGUAGES = Object.freeze([
  {label: "English", value: "en"},
  {label: "Telugu", value: "te"},
  {label: "Hindi", value: "hi"}
])

export function backendDoorFor(label) {
  return DOORS.find((door) => door.label === label)?.value ?? null
}

export function doorLabelForBackend(value) {
  return DOORS.find((door) => door.value === value)?.label ?? null
}

export function queuePayloadFor(label, conversationLanguage) {
  const door_type = backendDoorFor(label)
  const validLanguage = CONVERSATION_LANGUAGES.some(({value}) => value === conversationLanguage)
  return door_type && validLanguage ? {door_type, conversation_language: conversationLanguage} : null
}
