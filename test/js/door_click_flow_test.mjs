import assert from "node:assert/strict"
import test from "node:test"
import fs from "node:fs"
import path from "node:path"
import { execFileSync } from "node:child_process"

test("app.js has valid syntax and exports/imports cleanly", () => {
  const appJsPath = path.resolve("priv/static/assets/app.js")
  const code = fs.readFileSync(appJsPath, "utf8")
  assert.ok(code.includes("function show(name) {"))
  assert.ok(code.includes("function push(channel, event, payload = {}) {"))
  assert.ok(code.includes("function ensureBootstrap() {"))
  assert.ok(code.includes("async function startMatchingFor(doorLabel) {"))
  
  // Syntax check via node -c
  assert.doesNotThrow(() => {
    execFileSync(process.execPath, ["-c", appJsPath], { encoding: "utf8" })
  })
})

test("startMatchingFor awaits bootstrap and handles socket channel readiness", () => {
  const appJsPath = path.resolve("priv/static/assets/app.js")
  const code = fs.readFileSync(appJsPath, "utf8")
  const startMatchingSnippet = code.slice(code.indexOf("async function startMatchingFor"), code.indexOf("function reducedMotionEnabled"))
  assert.ok(startMatchingSnippet.includes("await ensureBootstrap()"), "startMatchingFor must await ensureBootstrap()")
  assert.ok(startMatchingSnippet.includes("show(\"queue\")"), "startMatchingFor must show queue screen")
  assert.ok(startMatchingSnippet.includes("push(app.participant, \"queue:join\", payload)"), "startMatchingFor must push queue:join")
})
