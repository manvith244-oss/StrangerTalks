const REPORT_FOCUSABLE_SELECTOR = [
  "button:not([disabled])",
  "[href]",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])'
].join(", ")

function visibleFocusableElements(container) {
  return Array.from(container.querySelectorAll(REPORT_FOCUSABLE_SELECTOR)).filter((element) => {
    if (element.hidden) return false
    const style = getComputedStyle(element)
    return style.display !== "none" && style.visibility !== "hidden"
  })
}

function configureReportSemantics(report) {
  const heading = report.querySelector(".report-disclosure h2, h2")
  if (!heading) return

  heading.id = "report-title"
  report.setAttribute("role", "dialog")
  report.setAttribute("aria-modal", "true")
  report.setAttribute("aria-labelledby", heading.id)
}

function handleReportKeydown(event) {
  const report = event.currentTarget
  if (report.hidden) return

  if (event.key === "Escape") {
    event.preventDefault()
    event.stopPropagation()
    report.querySelector("#report-cancel")?.click()
    return
  }

  if (event.key !== "Tab") return

  const focusables = visibleFocusableElements(report)
  if (!focusables.length) {
    event.preventDefault()
    report.querySelector("#report-title")?.focus()
    return
  }

  const first = focusables[0]
  const last = focusables[focusables.length - 1]
  const active = document.activeElement
  const heading = report.querySelector("#report-title")

  if (event.shiftKey && (active === first || active === heading || !report.contains(active))) {
    event.preventDefault()
    last.focus()
  } else if (!event.shiftKey && (active === last || !report.contains(active))) {
    event.preventDefault()
    first.focus()
  }
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
