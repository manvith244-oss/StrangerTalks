import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

const html = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const app = readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")
const ordinaryCopy = "This is a temporary Conversation, not a permanent chat-history thread."
const localCopy = "If a participant chooses to keep a local Conversation copy on their own device, that copy has a separate local lifetime; Fade removes that participant-local transcript and summary."
const safetyScheduleCopy = "Limited safety evidence is minimized or deleted on its own safety-retention schedule."
const safetySeparationCopy = "Unsend or Fade can remove participant-visible or local content, but they do not erase safety evidence already authorized for safety handling."
const mediaSafetyCopy = "If you report a View-Once photo while StrangerTalks still has its server-owned safety copy, the photo may be stored separately as limited safety evidence. That sensitive evidence is minimized or deleted on its own safety-retention schedule."

const lifetimeReportsCopy = () => html.match(/<section aria-labelledby="lifetime-reports-title">[\s\S]*?<\/section>/)?.[0] || ""
const staticReportCopy = () => html.match(/<form id="report-form"[\s\S]*?<\/form>/)?.[0] || ""
const dynamicReportCopy = () => app.match(/reportForm\.insertAdjacentHTML\("afterbegin",[\s\S]*?\)\n/)?.[0] || ""

test("T03 PRIV-002 distinguishes ordinary, participant-local, and separately authorized safety retention", () => {
  const lifetime = lifetimeReportsCopy()
  const staticReport = staticReportCopy()
  const dynamicReport = dynamicReportCopy()
  assert.ok(html.includes(ordinaryCopy), "ordinary live Conversation is not described as permanent history")
  assert.ok(html.includes(localCopy), "participant-retained local copy has its own local lifetime and Fade boundary")
  assert.ok(lifetime.includes(safetyScheduleCopy), "lifetime dialog describes bounded safety-evidence cleanup")
  assert.ok(lifetime.includes(safetySeparationCopy), "lifetime dialog separates Unsend/Fade from safety authority")
  assert.ok(staticReport.includes(mediaSafetyCopy), "View-Once report disclosure describes limited safety evidence")
  assert.ok(dynamicReport.includes(safetyScheduleCopy), "rendered report disclosure describes bounded safety-evidence cleanup")
  assert.ok(dynamicReport.includes(safetySeparationCopy), "rendered report disclosure separates participant disappearance from safety authority")
})

test("T03 PRIV-002 user-facing privacy surfaces reject stale indefinite and unsupported legal guarantees", () => {
  const uiCopy = [lifetimeReportsCopy(), staticReportCopy(), dynamicReportCopy()].join("\n")
  assert.doesNotMatch(uiCopy, /no automatic expiry|no automatic cleanup|no automatic expiry or cleanup/i)
  assert.doesNotMatch(uiCopy, /fully compliant|legally required for|we never retain anything|deletion is immediate everywhere/i)
})
