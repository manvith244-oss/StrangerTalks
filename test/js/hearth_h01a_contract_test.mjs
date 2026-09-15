import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"

const html = fs.readFileSync("priv/static/hearth_lab.html", "utf8")
const js = fs.readFileSync("priv/static/assets/hearth_lab.mjs", "utf8")

const frozenPrompt = "What did you buy convinced you'd use it, that is currently just taking up space?"
const retiredPrompt = "What did you buy thinking, “I’m definitely using this,” and then barely touched?"
const attemptKey = "strangertalks:h01a:attempted:v1"

test("H-01a lab renders the exact frozen pilot prompt and a terminal done surface", () => {
  assert.ok(html.includes(frozenPrompt), "frozen H-01a prompt must be rendered verbatim")
  assert.ok(!html.includes(retiredPrompt), "retired Prototype 1 prompt must not remain")
  assert.ok(html.includes('id="done-screen"'), "single-shot pilot needs a terminal done screen")
})

test("browser latch is checked before a new participant identity is issued", () => {
  assert.ok(js.includes(attemptKey), "pilot attempt latch must be versioned")

  const checkIndex = js.indexOf("localStorage.getItem(attemptKey)")
  const issueIndex = js.indexOf('fetch("/api/participants"')

  assert.ok(checkIndex >= 0, "bootstrap must inspect the H-01a latch")
  assert.ok(issueIndex >= 0, "participant issuance call must remain present")
  assert.ok(checkIndex < issueIndex, "used browser must be stopped before participant issuance")
})

test("attempt latch is written only after server accepts the first cohort action", () => {
  const controlStart = js.indexOf('$("control-connect").addEventListener')
  const hearthStart = js.indexOf('$("hearth-form").addEventListener')
  const stepInStart = js.indexOf('$("step-in").addEventListener')

  assert.ok(controlStart >= 0 && hearthStart > controlStart && stepInStart > hearthStart)

  const controlBlock = js.slice(controlStart, hearthStart)
  const hearthBlock = js.slice(hearthStart, stepInStart)

  assert.ok(controlBlock.indexOf('await push("control:connect"') >= 0)
  assert.ok(controlBlock.indexOf("markAttempted()") > controlBlock.indexOf('await push("control:connect"')))

  assert.ok(hearthBlock.indexOf('await push("hearth:submit"') >= 0)
  assert.ok(hearthBlock.indexOf("markAttempted()") > hearthBlock.indexOf('await push("hearth:submit"')))
})

test("all post-attempt exits terminalize instead of offering another encounter", () => {
  assert.ok(!js.includes("You can try again"))
  assert.ok(!js.includes("next encounter starts clean"))

  assert.ok(js.includes('channel.on("bridge:dissolved", () => finishPilot('))
  assert.ok(js.includes('channel.on("experiment:reset", () => finishPilot('))
  assert.ok(js.includes('$("pass").addEventListener'))
  assert.ok(js.includes('$("close-feedback").addEventListener("click", () => finishPilot('))
})
