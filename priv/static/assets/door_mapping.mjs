// V1 presentation aliases for the existing canonical backend Door values.
export const DOORS = Object.freeze([
  {label: "Deep Talk", value: "SOMETHING_REAL", description: "A meaningful or emotionally deeper conversation."},
  {label: "Vent", value: "JUST_TALK", description: "Space to speak and be heard."},
  {label: "Distract", value: "KEEP_IT_LIGHT", description: "A light conversation to take your mind off things."},
  {label: "Advice", value: "EXPLORE", description: "Explore options, perspectives, and possible next steps."}
])

export function backendDoorFor(label) {
  return DOORS.find((door) => door.label === label)?.value ?? null
}
