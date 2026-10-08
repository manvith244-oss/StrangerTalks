// Team 2E: real Phoenix WebSocket protocol test, isolated local test server only.
// No production endpoint or credentials; user identities are freshly issued by the disposable test DB.
import assert from "node:assert/strict"
import fs from "node:fs"

const base = process.env.STRANGERTALKS_BROWSER_BASE_URL || "http://127.0.0.1:4002"
const wsUrl = base.replace(/^http/, "ws") + "/socket/websocket?vsn=2.0.0"

function withTimeout(message, callback, ms = 7500) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(message + " timed out")), ms)
    callback(
      value => { clearTimeout(timeout); resolve(value) },
      error => { clearTimeout(timeout); reject(error) }
    )
  })
}

async function createParticipant() {
  const response = await fetch(base + "/api/participants", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: "{}",
    signal: AbortSignal.timeout(10000)
  })
  assert.equal(response.status, 201, "fixture participant must be issued by the real HTTP endpoint")
  const {participant_id, token} = await response.json()
  assert.match(participant_id, /^[0-9a-f-]{36}$/i)
  assert.ok(token && typeof token === "string")
  return {participant_id, token}
}

async function connect(token) {
  // Same subprotocol construction as Phoenix JS 1.8:
  // phoenix + base64url.bearer.phx.<base64(authToken) without padding>.
  const protocol = "base64url.bearer.phx." + Buffer.from(token, "utf8").toString("base64").replace(/=/g, "")
  const socket = new WebSocket(wsUrl, ["phoenix", protocol])
  await withTimeout("authenticated WebSocket handshake", (resolve, reject) => {
    socket.addEventListener("open", resolve, {once: true})
    socket.addEventListener("error", reject, {once: true})
    socket.addEventListener("close", () => reject(new Error("socket closed before handshake")), {once: true})
  })
  const pending = new Map()
  socket.addEventListener("message", event => {
    let message
    try { message = JSON.parse(String(event.data)) } catch { return }
    if (!Array.isArray(message) || message[3] !== "phx_reply") return
    const ref = message[1]
    const waiter = pending.get(ref)
    if (waiter) {
      pending.delete(ref)
      waiter(message)
    }
  })
  let ref = 0
  return {
    socket,
    async join(topic, payload = {}) {
      const reference = String(++ref)
      const answer = withTimeout("phx_join: " + topic, (resolve, reject) => {
        pending.set(reference, resolve)
        if (socket.readyState !== WebSocket.OPEN) {
          pending.delete(reference)
          reject(new Error("socket is no longer open"))
          return
        }
        socket.send(JSON.stringify([reference, reference, topic, "phx_join", payload]))
      })
      const result = await answer
      assert.equal(result[2], topic, "reply must be for requested topic")
      return result[4]
    },
    close() { socket.close() }
  }
}

async function main() {
  const gate = process.env.STRANGERTALKS_TEAM2E_GATE || "unknown"
  // Reuse disposable CI identities across restarts. Creating fresh participants each time
  // would hit the actual issuance-rate limiter and misclassify a healthy rate limit as a gate failure.
  const fixturePath = process.env.STRANGERTALKS_TEAM2E_FIXTURE_PATH
  let fixtures
  if (fixturePath && fs.existsSync(fixturePath)) {
    fixtures = JSON.parse(fs.readFileSync(fixturePath, "utf8"))
  } else {
    fixtures = [await createParticipant(), await createParticipant()]
    if (fixturePath) fs.writeFileSync(fixturePath, JSON.stringify(fixtures), {mode: 0o600})
  }
  const [alice, bob] = fixtures
  const session = await connect(alice.token)
  try {
    const cases = [
      ["direct own lobby", "hangout_lobby:" + alice.participant_id, {}, "feature_unavailable"],
      ["other participant lobby", "hangout_lobby:" + bob.participant_id, {}, "feature_unavailable"],
      ["direct valid room UUID", "hangout:00000000-0000-4000-8000-000000000001", {}, "feature_unavailable"],
      ["direct unknown room UUID", "hangout:00000000-0000-4000-8000-000000000002", {}, "feature_unavailable"],
      ["malformed room ID", "hangout:not-a-uuid", {}, "feature_unavailable"],
      ["client-supplied lease", "hangout:00000000-0000-4000-8000-000000000001", {presence_lease_id: "forged"}, "invalid_request"]
    ]
    for (const [label, topic, payload, expectedReason] of cases) {
      const result = await session.join(topic, payload)
      assert.equal(result.status, "error", label + ": join unexpectedly accepted")
      assert.equal(result.response?.reason, expectedReason, label + ": unexpected rejection category")
      console.log("PASS gate=" + gate + " case=" + label + " reply=" + result.response.reason)
    }
    assert.equal(session.socket.readyState, WebSocket.OPEN, "rejected joins must not destroy authenticated transport")
    console.log("PASS gate=" + gate + " authenticated transport survived rejected joins")
  } finally {
    session.close()
  }
}

main().catch(error => {
  console.error("FAIL: " + error.message)
  process.exitCode = 1
})
