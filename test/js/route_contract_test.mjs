import assert from "node:assert/strict"
import test from "node:test"

const contract = await import("../../priv/static/assets/route_contract.mjs")

const {
  CANONICAL_ROUTE_PATTERNS,
  parseRoute,
  resolveRequestedRoute,
  screenForRoute
} = contract

const UUID = "123e4567-e89b-42d3-a456-426614174000"

const STATIC_ROUTES = [
  ["/", "doors"],
  ["/matchmaking", "queue"],
  ["/conversation", "conversation"],
  ["/conversation/ended", "ended"],
  ["/conversation/unavailable", "unrecoverable"],
  ["/chats", "chats"],
  ["/bonds", "relationships"],
  ["/you", "settings"],
  ["/you/memories", "memories"],
  ["/you/reflections", "reflections"]
]

test("frozen route table parses to the existing product screens", () => {
  assert.equal(CANONICAL_ROUTE_PATTERNS.length, 11)

  for (const [path, screen] of STATIC_ROUTES) {
    const route = parseRoute(path)
    assert.equal(route.valid, true, path)
    assert.equal(route.path, path)
    assert.equal(screenForRoute(route), screen, path)
  }

  const detail = parseRoute(`/chats/${UUID}`)
  assert.equal(detail.valid, true)
  assert.equal(detail.path, `/chats/${UUID}`)
  assert.equal(detail.params.conversationId, UUID)
  assert.equal(screenForRoute(detail), "history")
})

test("route parser rejects non-canonical aliases and malformed saved Conversation ids", () => {
  for (const path of [
    "/matching",
    "/settings",
    "/settings/memories",
    "/talk",
    "/home",
    "/conversation/123",
    "/chats/not-a-uuid",
    "/unknown"
  ]) {
    assert.equal(parseRoute(path).valid, false, path)
  }
})

test("a single trailing slash canonicalizes without creating a second route", () => {
  const route = parseRoute("/you/")
  assert.equal(route.valid, true)
  assert.equal(route.path, "/you")
  assert.equal(route.needsCanonicalReplace, true)
})

test("QUEUED activity may coexist with another valid route", () => {
  const queued = {canonical_state: "QUEUED", queue: {queue_attempt_id: "attempt-1"}}

  assert.equal(resolveRequestedRoute(parseRoute("/you"), queued).path, "/you")
  assert.equal(resolveRequestedRoute(parseRoute("/chats"), queued).path, "/chats")
  assert.equal(resolveRequestedRoute(parseRoute("/bonds"), queued).path, "/bonds")
  assert.equal(resolveRequestedRoute(parseRoute("/matchmaking"), queued).path, "/matchmaking")
})

test("ACTIVE text Conversation activity may coexist with another permitted route", () => {
  const active = {canonical_state: "CONVERSATION", conversation: {conversation_id: UUID}}

  assert.equal(resolveRequestedRoute(parseRoute("/you"), active).path, "/you")
  assert.equal(resolveRequestedRoute(parseRoute("/chats"), active).path, "/chats")
  assert.equal(resolveRequestedRoute(parseRoute("/bonds"), active).path, "/bonds")
  assert.equal(resolveRequestedRoute(parseRoute("/conversation"), active).path, "/conversation")
})

test("activity-specific routes validate authority without taking over unrelated routes", () => {
  const idle = {canonical_state: "IDLE"}
  const queued = {canonical_state: "QUEUED", queue: {queue_attempt_id: "attempt-1"}}
  const active = {canonical_state: "CONVERSATION", conversation: {conversation_id: UUID}}

  assert.deepEqual(resolveRequestedRoute(parseRoute("/matchmaking"), idle), {
    path: "/",
    screen: "doors",
    replace: true,
    reason: "matchmaking_not_queued"
  })
  assert.deepEqual(resolveRequestedRoute(parseRoute("/matchmaking"), active), {
    path: "/conversation",
    screen: "conversation",
    replace: true,
    reason: "matchmaking_advanced_to_conversation"
  })
  assert.deepEqual(resolveRequestedRoute(parseRoute("/conversation"), idle), {
    path: "/conversation/unavailable",
    screen: "unrecoverable",
    replace: true,
    reason: "conversation_not_available"
  })
  assert.equal(resolveRequestedRoute(parseRoute("/conversation"), queued).path, "/conversation/unavailable")
})

test("terminal and unavailable Conversation routes remain canonical locations", () => {
  for (const path of ["/conversation/ended", "/conversation/unavailable"]) {
    const resolved = resolveRequestedRoute(parseRoute(path), {canonical_state: "IDLE"})
    assert.equal(resolved.path, path)
    assert.equal(resolved.replace, false)
  }
})
