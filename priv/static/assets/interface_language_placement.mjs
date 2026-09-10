const STYLE_ID = "st-interface-language-placement-style"
const CONTROL_ID = "conversation-language-control"

function installStyles(documentRef) {
  if (documentRef.getElementById(STYLE_ID)) return

  const style = documentRef.createElement("style")
  style.id = STYLE_ID
  style.textContent = `
    .site-header.st-language-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: var(--st-space-3, 0.75rem);
    }

    #${CONTROL_ID} {
      position: relative;
      flex: 0 1 auto;
      min-width: 0;
      margin-inline-start: auto;
    }

    #${CONTROL_ID} > label,
    #${CONTROL_ID} > #conversation-language-help {
      position: absolute !important;
      width: 1px !important;
      height: 1px !important;
      padding: 0 !important;
      margin: -1px !important;
      overflow: hidden !important;
      clip: rect(0, 0, 0, 0) !important;
      white-space: nowrap !important;
      border: 0 !important;
    }

    #${CONTROL_ID} > #conversation-language {
      width: auto;
      min-width: 9.5rem;
      max-width: min(12rem, 44vw);
      padding-block: var(--st-space-2, 0.5rem);
      padding-inline: var(--st-space-3, 0.75rem);
    }

    #${CONTROL_ID} > #arrival-feedback:not([hidden]) {
      position: absolute;
      z-index: 30;
      top: calc(100% + var(--st-space-2, 0.5rem));
      right: 0;
      width: min(22rem, calc(100vw - 2rem));
      margin: 0;
      padding: var(--st-space-3, 0.75rem) var(--st-space-4, 1rem);
      border: 1px solid var(--st-border, rgba(255, 255, 255, 0.15));
      border-radius: var(--st-radius-small, 12px);
      background: var(--st-surface-raised, #20242f);
      color: var(--st-text, #fff);
      box-shadow: 0 0.75rem 2rem rgba(0, 0, 0, 0.28);
    }

    @media (max-width: 28rem) {
      #${CONTROL_ID} > #conversation-language {
        min-width: 7.5rem;
        max-width: 42vw;
        font-size: var(--st-small, 0.875rem);
      }
    }
  `
  documentRef.head.append(style)
}

function moveSupportText(documentRef, control) {
  const help = documentRef.getElementById("conversation-language-help")
  const feedback = documentRef.getElementById("arrival-feedback")
  if (help && help.parentElement !== control) control.append(help)
  if (feedback && feedback.parentElement !== control) control.append(feedback)
  return Boolean(help && feedback)
}

function syncLanguageAvailability(documentRef, control, languageSelect) {
  const doorsScreen = documentRef.querySelector('section[data-screen="doors"]')
  const available = Boolean(doorsScreen?.classList.contains("active") && !doorsScreen.hidden)
  languageSelect.disabled = !available
  control.dataset.languageSelectionAvailable = available ? "true" : "false"
}

export function installInterfaceLanguagePlacement(documentRef = globalThis.document) {
  if (!documentRef || documentRef.documentElement?.dataset.interfaceLanguagePlacementInstalled === "true") return null

  const header = documentRef.querySelector(".site-header")
  const languageSelect = documentRef.getElementById("conversation-language")
  const languageLabel = documentRef.querySelector('label[for="conversation-language"]')
  if (!header || !languageSelect || !languageLabel) return null

  documentRef.documentElement.dataset.interfaceLanguagePlacementInstalled = "true"
  installStyles(documentRef)

  let control = documentRef.getElementById(CONTROL_ID)
  if (!control) {
    control = documentRef.createElement("div")
    control.id = CONTROL_ID
    control.setAttribute("data-interface-language-placement", "global-secondary")
  }

  header.classList.add("st-language-header")
  control.append(languageLabel, languageSelect)
  moveSupportText(documentRef, control)
  header.append(control)
  syncLanguageAvailability(documentRef, control, languageSelect)

  const doorsScreen = documentRef.querySelector('section[data-screen="doors"]')
  if (doorsScreen && typeof MutationObserver !== "undefined") {
    const screenObserver = new MutationObserver(() => syncLanguageAvailability(documentRef, control, languageSelect))
    screenObserver.observe(doorsScreen, {attributes: true, attributeFilter: ["class", "hidden"]})
  }

  if (!moveSupportText(documentRef, control) && typeof MutationObserver !== "undefined") {
    const observer = new MutationObserver(() => {
      if (moveSupportText(documentRef, control)) observer.disconnect()
    })
    observer.observe(documentRef.body, {childList: true, subtree: true})
  }

  return {control, languageSelect}
}

if (typeof document !== "undefined") {
  installInterfaceLanguagePlacement(document)
}
