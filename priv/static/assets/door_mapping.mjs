import "./arrival_first_minute.mjs"
import "./secondary_flow.mjs"
import {DOORS} from "./conversation_catalog.mjs"

export {DOORS}

export function backendDoorFor(label) {
  return DOORS.find((door) => door.label === label)?.value ?? null
}

export function doorLabelForBackend(value) {
  return DOORS.find((door) => door.value === value)?.label ?? null
}

export function queuePayloadFor(label) {
  const door_type = backendDoorFor(label)
  return door_type ? {door_type} : null
}
