export {messageSendTimeoutDisposition} from "./message_retry_policy.mjs"

if (typeof window !== "undefined") {
  await import("./message_failed_retry.mjs")
}

export const FLOW_PHASE = Object.freeze({
  APP_BOOT: "app_boot",
  MATCHMAKING_ADMISSION: "matchmaking_admission",
  MATCHMAKING_WAITING: "matchmaking_waiting",
  MATCHMAKING_CANCELLING: "matchmaking_cancelling",
  MATCHMAKING_CANCELLED: "matchmaking_cancelled",
  ENTERING_CONVERSATION: "entering_conversation"
})

export function loadingPresentation(phase, context = {}) {
  switch (phase) {
    case FLOW_PHASE.APP_BOOT:
      return {
        title: "Opening StrangerTalks…",
        detail: "Checking your current session…",
        interaction: "blocked"
      }

    case FLOW_PHASE.MATCHMAKING_ADMISSION:
      return {
        title: "Starting matchmaking…",
        detail: "Confirming your place in the queue.",
        interaction: "blocked",
        leaveEnabled: false
      }

    case FLOW_PHASE.MATCHMAKING_WAITING:
      return {
        title: "Finding someone…",
        detail: context.door
          ? `Looking for someone who chose ${context.door} too.`
          : "Looking for someone compatible with your choice.",
        interaction: "queue",
        leaveEnabled: true
      }

    case FLOW_PHASE.MATCHMAKING_CANCELLING:
      return {
        title: "Leaving queue…",
        detail: "Confirming you left matchmaking.",
        interaction: "blocked",
        leaveEnabled: false
      }

    case FLOW_PHASE.MATCHMAKING_CANCELLED:
      return {
        title: "You left matchmaking.",
        detail: "Matchmaking is no longer active.",
        interaction: "blocked",
        leaveEnabled: false
      }

    case FLOW_PHASE.ENTERING_CONVERSATION:
      return {
        title: "Found someone.",
        detail: "Opening your temporary conversation…",
        interaction: "blocked",
        leaveEnabled: false
      }

    default:
      throw new Error(`Unknown F-07 flow phase: ${phase}`)
  }
}

export function createOperationGuard() {
  let generation = 0

  return {
    begin(scope) {
      generation += 1
      return Object.freeze({scope, generation})
    },

    current(token) {
      return Boolean(token) && token.generation === generation
    },

    invalidate() {
      generation += 1
    },

    generation() {
      return generation
    }
  }
}