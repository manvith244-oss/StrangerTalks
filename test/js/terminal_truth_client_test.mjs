import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"

const appSource = fs.readFileSync(new URL("../../priv/static/assets/app.js", import.meta.url), "utf8")

test("terminal events are scoped to the Conversation that registered the handler", () => {
  assert.match(
    appSource,
    /const runtimeIsCurrent = \(\) => app\.conversation === channel && app\.conversationId === id/
  )

  const onCurrentHelper = appSource.match(
    /const onCurrent = \(event, handler\) => \{([\s\S]*?)\n  \}\n  channel\.__f04ReleaseRuntimeBindings/
  )?.[1] || ""

  assert.match(onCurrentHelper, /channel\.on\(event, \(\.\.\.args\) => \{/)
  assert.match(onCurrentHelper, /if \(!runtimeIsCurrent\(\)\) return/)
  assert.match(
    appSource,
    /onCurrent\("conversation:ended", async \(\) => \{\s*if \(app\.conversationId !== id\) return/
  )
})

test("terminal UI teardown closes transient interaction authority and clears the composer", () => {
  const terminalHandler = appSource.match(
    /onCurrent\("conversation:ended", async \(\) => \{([\s\S]*?)\n  \}\)\n\n  channel\.join\(\)/
  )?.[1] || ""

  assert.match(terminalHandler, /closeReactionPicker\(\)/)
  assert.match(terminalHandler, /closeReportForm\(\)/)
  assert.match(terminalHandler, /message-form/)
  assert.match(terminalHandler, /ig-tray-open/)
  assert.match(terminalHandler, /message-input/)
  assert.match(terminalHandler, /\.value = ""/)
})
