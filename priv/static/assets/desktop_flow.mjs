function configureReportSemantics(report) {
  const heading = report.querySelector(".report-disclosure h2, h2")
  if (!heading) return

  heading.id = "report-title"
  report.setAttribute("role", "dialog")
  report.setAttribute("aria-modal", "false")
  report.setAttribute("aria-labelledby", heading.id)
}

function handleReportKeydown(event) {
  const report = event.currentTarget
  if (report.hidden || event.key !== "Escape") return

  event.preventDefault()
  event.stopPropagation()
  report.querySelector("#report-cancel")?.click()
}

function configureEndConfirmationFocus() {
  const backdrop = document.querySelector("#end-confirmation-backdrop")
  const trigger = document.querySelector("#end-conversation")
  if (!backdrop || !trigger || backdrop.dataset.f10FocusReturnReady === "true") return

  backdrop.dataset.f10FocusReturnReady = "true"
  let wasOpen = !backdrop.hidden

  new MutationObserver(() => {
    const isOpen = !backdrop.hidden
    const justClosed = wasOpen && !isOpen
    wasOpen = isOpen
    if (!justClosed) return

    requestAnimationFrame(() => {
      if (!backdrop.hidden || !trigger.isConnected) return
      trigger.focus()
    })
  }).observe(backdrop, {attributes: true, attributeFilter: ["hidden"]})
}

export function initializeDesktopFlow() {
  const report = document.querySelector("#report-form")
  if (report && report.dataset.f10KeyboardReady !== "true") {
    report.dataset.f10KeyboardReady = "true"
    configureReportSemantics(report)
    report.addEventListener("keydown", handleReportKeydown)

    new MutationObserver(() => configureReportSemantics(report)).observe(report, {
      childList: true,
      subtree: true
    })
  }

  configureEndConfirmationFocus()
}

initializeDesktopFlow()
