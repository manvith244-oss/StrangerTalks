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

export function initializeDesktopFlow() {
  const report = document.querySelector("#report-form")
  if (!report || report.dataset.f10KeyboardReady === "true") return

  report.dataset.f10KeyboardReady = "true"
  configureReportSemantics(report)
  report.addEventListener("keydown", handleReportKeydown)

  new MutationObserver(() => configureReportSemantics(report)).observe(report, {
    childList: true,
    subtree: true
  })
}

initializeDesktopFlow()
