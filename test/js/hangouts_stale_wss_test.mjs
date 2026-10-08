// Team 2E: real authenticated Phoenix WebSocket stale-client proof.
// The only room and participants used here are test-only fixtures from local ephemeral PostgreSQL.
import assert from "node:assert/strict"
import fs from "node:fs"

const base = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4002"
const fixturePath = process.env.STRANGERTALKS_TEAM2E_STALE_FIXTURE_PATH
const triggerPath = process.env.STRANGERTALKS_TEAM2E_DISABLE_TRIGGER
const ackPath = process.env.STRANGERTALKS_TEAM2E_DISABLE_ACK
assert.ok(fixturePath && triggerPath && ackPath, "test-only fixture/control paths required")

const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"))
const websocketUrl = base.replace(/^http/, "ws") + "/socket/websocket?vsn=2.0.0"

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

function timeoutPromise(label, body, ms = 7500) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(label + " timed out")), ms)
    body(
      value => { clearTimeout(timer); resolve(value) },
      error => { clearTimeout(timer); reject(error) }
    )
  })
}

async function openSocket(token) {
  // Phoenix JS v1.8 auth token transport: the authenticated client never uses query-string tokens.
  const protocol = "base64url.bearer.phx." + Buffer.from(token).toString("base64").replace(/=/g, "")
  const socket = new WebSocket(websocketUrl, ["phoenix", protocol])
  await timeoutPromise("authenticated WebSocket open", (resolve, reject) => {
    socket.addEventListener("open", resolve, {once: true})
    socket.addEventListener("error", reject, {once: true})
    socket.addEventListener("close", () => reject(new Error("socket closed")), {once: true})
  })
  let seq = 0
  const pending = new Map()
  const joined = new Map()
  socket.addEventListener("message", ({data}) => {
    let message
    try { message = JSON.parse(String(data)) } catch { return }
    if (!Array.isArray(message) || message[3] !== "phx_reply") return
    const resolve = pending.get(message[1])
    if (resolve) {
      pending.delete(message[1])
      resolve(message)
    }
  })
  return {
    socket,
    async request(topic, event, payload = {}) {
      const ref = String(++seq)
      const joinRef = event === "phx_join" ? ref : joined.get(topic)
      assert.ok(joinRef, "client must join before sending channel events")
      const messagePromise = timeoutPromise(event + " on " + topic, (resolve, reject) => {
        pending.set(ref, resolve)
        if (socket.readyState !== WebSocket.OPEN) return reject(new Error("socket closed"))
        socket.send(JSON.stringify([joinRef, ref, topic, event, payload]))
      })
      const reply = await messagePromise
      assert.equal(reply[2], topic)
      if (event === "phx_join" && reply[4].status === "ok") joined.set(topic, ref)
      return reply[4]
    },
    close() { socket.close() }
  }
}

function expectResponse(result, expected, label) {
  assert.equal(result.status, expected.status, label + ": unexpected status")
  if (expected.reason) {
    assert.equal(result.response?.reason, expected.reason, label + ": wrong rejection reason")
  }
  console.log("PASS " + label + ": " + result.status + (result.response?.reason ? " " + result.response.reason : ""))
}

async function main() {
  const [alice, bob] = fixture.members
  const topic = "hangout:" + fixture.room_id
  const active = await openSocket(alice.token)
  let afterDisable
  try {
    const joinResult = await active.request(topic, "phx_join")
    expectResponse(joinResult, {status: "ok"}, "authenticated initial room join")
    const members = joinResult.response?.members
    assert.ok(Array.isArray(members) && members.length >= 3)
    const target = members.find(member => !member.self)
    assert.ok(Number.isInteger(target?.identity?.slot), "room snapshot contains temporary slot only")
    const targetSlot = target.identity.slot

    const sent = await active.request(topic, "message:send", {
      client_message_id: "team2e-pre-disable-synthetic-message",
      body: "Synthetic fixture message before disabling Hangouts"
    })
    expectResponse(sent, {status: "ok"}, "synthetic message accepted before disable")

    fs.writeFileSync(triggerPath, "disable", {mode: 0o600})
    let acknowledged = false
    for (let attempts = 0; attempts < 150; attempts++) {
      if (fs.existsSync(ackPath)) { acknowledged = true; break }
      await wait(40)
    }
    assert.ok(acknowledged, "isolated Phoenix process acknowledged gate disable")
    console.log("PASS runtime gate changed after existing channel admission")

    for (const [event, payload] of [
      ["message:send", {client_message_id: "team2e-post-disable", body: "MUST NOT PERSIST"}],
      ["reaction:add", {expected_content_sequence: 0, reaction: "❤️"}],
      ["content:skip_vote", {expected_content_sequence: 0}]
    ]) {
      const result = await active.request(topic, event, payload)
      expectResponse(result, {status: "error", reason: "feature_unavailable"}, "existing socket " + event)
    }
    assert.equal(active.socket.readyState, WebSocket.OPEN)

    afterDisable = await openSocket(bob.token)
    expectResponse(
      await afterDisable.request(topic, "phx_join"),
      {status: "error", reason: "feature_unavailable"},
      "fresh socket rejected from previously active room"
    )
    expectResponse(
      await afterDisable.request("hangout_lobby:" + bob.participant_id, "phx_join"),
      {status: "error", reason: "feature_unavailable"},
      "fresh lobby join after disable"
    )

    expectResponse(
      await active.request(topic, "safety:report", {
        client_report_id: "team2e-synthetic-report-after-disable",
        target_identity_slot: targetSlot,
        category: "other",
        evidence: null
      }),
      {status: "ok"},
      "authorized safety report preserved"
    )
    expectResponse(
      await active.request(topic, "safety:block", {target_identity_slot: targetSlot}),
      {status: "ok"},
      "authorized safety block preserved"
    )
    expectResponse(
      await active.request(topic, "room:leave"),
      {status: "ok"},
      "authorized leave preserved"
    )
  } finally {
    active.close()
    afterDisable?.close()
  }
}

main().catch(error => {
  console.error("FAIL: " + error.message)
  process.exitCode = 1
})
