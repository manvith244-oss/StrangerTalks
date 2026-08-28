import {deleteRecord, getRecord, putRecord} from "./local_data.mjs"
import {createPreferenceSaveQueue, saveBooleanPreference} from "./preference_saves.mjs"

const preferenceQueue = createPreferenceSaveQueue()
let installed = false

function announce(documentRef, message) {
  const status = documentRef.querySelector("#status")
  if (status) status.textContent = message
}

function storageDurability() {
  try {
    const status = globalThis.indexedDB?.storageStatus?.()
    return typeof status?.durable === "boolean" ? status.durable : null
  } catch (_error) {
    return null
  }
}

function afterInteractionSettles() {
  return new Promise((resolve) => setTimeout(resolve, 25))
}

async function restorePreviousRecord(recordId, record) {
  if (record) await putRecord(record)
  else await deleteRecord(recordId)
}

export function ensureSecondaryEntries(documentRef = document) {
  const settings = documentRef.querySelector('section[data-screen="settings"]')
  if (!settings) return null

  const existing = settings.querySelector('[data-go="reflections"]')
  if (existing) return existing

  const memoryEntry = settings.querySelector('[data-go="memories"]')
  if (!memoryEntry) return null

  const reflectionsEntry = documentRef.createElement("button")
  reflectionsEntry.type = "button"
  reflectionsEntry.dataset.go = "reflections"
  reflectionsEntry.textContent = "Open Private Reflections"
  reflectionsEntry.setAttribute("aria-label", "Open Private Reflections")
  memoryEntry.insertAdjacentElement("afterend", reflectionsEntry)
  return reflectionsEntry
}

function markConfirmed(control) {
  control.removeAttribute("aria-invalid")
  delete control.dataset.persistenceState
}

function markUnconfirmed(control) {
  control.setAttribute("aria-invalid", "true")
  control.dataset.persistenceState = "unconfirmed"
}

async function persistToggle({
  documentRef,
  control,
  key,
  recordId,
  valueKey,
  desired,
  apply,
  successMessage,
  failureMessage
}) {
  let previousRecord = null
  try { previousRecord = await getRecord(recordId) } catch (_error) {}
  const durableBeforeSave = storageDurability()

  const result = await saveBooleanPreference({
    queue: preferenceQueue,
    key,
    recordId,
    valueKey,
    desired,
    putRecord,
    getRecord
  })

  if (result.status === "saved") {
    const lostDurability = durableBeforeSave === true && storageDurability() === false
    if (lostDurability && preferenceQueue.isCurrent(key, result.version)) {
      const canonical = previousRecord?.value?.[valueKey] === true

      // Let the originating checkbox interaction commit first, then reconcile
      // the optimistic UI once the persistence boundary has declared the write
      // non-durable. This keeps browser-native change semantics intact while
      // still restoring canonical state immediately after a failed save.
      await afterInteractionSettles()
      if (!preferenceQueue.isCurrent(key, result.version)) return

      try { await restorePreviousRecord(recordId, previousRecord) } catch (_error) {}
      if (!preferenceQueue.isCurrent(key, result.version)) return

      control.checked = canonical
      apply(canonical)
      markConfirmed(control)
      announce(documentRef, `${failureMessage} Restored your saved preference.`)
      return
    }

    markConfirmed(control)
    announce(documentRef, successMessage(desired))
    return
  }

  if (result.status === "superseded" || result.status === "superseded_failed") return

  if (result.canonical === null) {
    markUnconfirmed(control)
    announce(documentRef, `${failureMessage} Reload You before relying on this setting.`)
    return
  }

  control.checked = result.canonical
  apply(result.canonical)
  markConfirmed(control)
  announce(documentRef, `${failureMessage} Restored your saved preference.`)
}

function installPreferenceHandlers(documentRef) {
  documentRef.addEventListener("change", (event) => {
    const control = event.target
    if (!control || (control.id !== "reduced-motion" && control.id !== "auto-sync")) return

    event.stopImmediatePropagation()
    const desired = control.checked === true

    if (control.id === "reduced-motion") {
      documentRef.body.classList.toggle("reduce-motion", desired)
      void persistToggle({
        documentRef,
        control,
        key: "reduced-motion",
        recordId: "settings:privacy",
        valueKey: "reduced_motion",
        desired,
        apply: canonical => documentRef.body.classList.toggle("reduce-motion", canonical),
        successMessage: enabled => enabled ? "Reduce motion is on." : "Reduce motion is off.",
        failureMessage: "Reduce motion wasn't saved."
      })
      return
    }

    void persistToggle({
      documentRef,
      control,
      key: "auto-sync",
      recordId: "settings:auto-sync",
      valueKey: "enabled",
      desired,
      apply: () => {},
      successMessage: enabled => enabled
        ? "Automatic protection is enabled after encrypted sync is unlocked in this browser session."
        : "Automatic protection is off.",
      failureMessage: "Automatic protection wasn't saved."
    })
  }, true)
}

export function initializeSecondaryFlow(documentRef = document) {
  if (installed || !documentRef?.querySelector) return
  installed = true
  ensureSecondaryEntries(documentRef)
  installPreferenceHandlers(documentRef)
}

if (typeof document !== "undefined") initializeSecondaryFlow(document)
