// Pure current-product catalog shared by presentation, queue construction and privacy-bounded analytics.
// This module has no DOM/runtime side effects so downstream observers can consume canonical values safely.
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
