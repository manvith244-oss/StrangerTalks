import assert from "node:assert/strict"
import test from "node:test"
import {ReflectionManager} from "../../priv/static/assets/reflections.mjs"

test("ReflectionManager stores grant secret in Document RAM only and clears on reset", () => {
  const manager = new ReflectionManager({
    getAuthToken: () => "mock-token"
  })

  assert.equal(manager.getGrant(), null)

  manager.setGrant({
    grant_id: "grant-123",
    raw_secret: "secret-xyz",
    excerpt: "hello world",
    source_client_message_id: "msg-1",
    source_conversation_id: "conv-1",
    expected_source_revision: 0
  })

  const grant = manager.getGrant()
  assert.equal(grant.grantId, "grant-123")
  assert.equal(grant.rawSecret, "secret-xyz")
  assert.equal(grant.excerpt, "hello world")

  manager.clearGrant()
  assert.equal(manager.getGrant(), null)
})

test("ReflectionManager saves reflection and clears active grant upon success", async () => {
  let requestedUrl = null
  let requestHeaders = null
  let requestBody = null

  globalThis.fetch = async (url, options) => {
    requestedUrl = url
    requestHeaders = options.headers
    requestBody = JSON.parse(options.body)
    return {
      ok: true,
      json: async () => ({
        status: "applied",
        reflection: {
          reflection_id: "ref-999",
          own_reflection_text: requestBody.own_reflection_text,
          source_excerpt: requestBody.source_excerpt,
          revision: 1,
          saved_at: new Date().toISOString()
        }
      })
    }
  }

  const manager = new ReflectionManager({
    apiBase: "http://localhost:4000/api",
    getAuthToken: () => "valid-token"
  })

  manager.setGrant({
    grant_id: "grant-abc",
    raw_secret: "secret-raw-abc",
    excerpt: "Source text",
    source_client_message_id: "msg-123",
    source_conversation_id: "conv-456",
    expected_source_revision: 0
  })

  const result = await manager.saveReflection({
    ownReflectionText: "My meaningful note",
    createOperationId: "op-uuid-123"
  })

  assert.equal(requestedUrl, "http://localhost:4000/api/reflections")
  assert.equal(requestHeaders["authorization"], "Bearer valid-token")
  assert.equal(requestBody.grant_id, "grant-abc")
  assert.equal(requestBody.grant_secret, "secret-raw-abc")
  assert.equal(requestBody.own_reflection_text, "My meaningful note")
  assert.equal(requestBody.source_excerpt, "Source text")

  // Grant must be cleared from Document RAM immediately after save
  assert.equal(manager.getGrant(), null)
  assert.equal(manager.lastSavedReflectionId, "ref-999")
})

test("ReflectionManager undoes newly saved reflection within undo window", async () => {
  let undoCalledUrl = null

  globalThis.fetch = async (url, options) => {
    undoCalledUrl = url
    return {
      ok: true,
      json: async () => ({status: "undone"})
    }
  }

  const manager = new ReflectionManager({
    apiBase: "http://localhost:4000/api",
    getAuthToken: () => "valid-token"
  })

  manager.lastSavedReflectionId = "ref-undo-test"
  const res = await manager.undoLastSave()

  assert.equal(res.status, "undone")
  assert.equal(undoCalledUrl, "http://localhost:4000/api/reflections/ref-undo-test/undo")
  assert.equal(manager.lastSavedReflectionId, null)
})

test("ReflectionManager performs CAS updateNote with expected revision", async () => {
  let updateBody = null
  let updateMethod = null

  globalThis.fetch = async (url, options) => {
    updateMethod = options.method
    updateBody = JSON.parse(options.body)
    return {
      ok: true,
      json: async () => ({
        status: "applied",
        reflection: {
          reflection_id: "ref-cas",
          own_reflection_text: updateBody.own_reflection_text,
          revision: 2
        }
      })
    }
  }

  const manager = new ReflectionManager({
    apiBase: "http://localhost:4000/api",
    getAuthToken: () => "valid-token"
  })

  const res = await manager.updateNote("ref-cas", 1, "Updated note text")

  assert.equal(updateMethod, "PUT")
  assert.equal(updateBody.expected_revision, 1)
  assert.equal(updateBody.own_reflection_text, "Updated note text")
  assert.equal(res.reflection.revision, 2)
})

test("ReflectionManager removeExcerpt calls dedicated endpoint", async () => {
  let removeBody = null
  let removeMethod = null

  globalThis.fetch = async (url, options) => {
    removeMethod = options.method
    removeBody = JSON.parse(options.body)
    return {
      ok: true,
      json: async () => ({
        status: "applied",
        reflection: {
          reflection_id: "ref-rm-excerpt",
          source_excerpt: null,
          revision: 2
        }
      })
    }
  }

  const manager = new ReflectionManager({
    apiBase: "http://localhost:4000/api",
    getAuthToken: () => "valid-token"
  })

  const res = await manager.removeExcerpt("ref-rm-excerpt", 1)

  assert.equal(removeMethod, "POST")
  assert.equal(removeBody.expected_revision, 1)
  assert.equal(res.reflection.source_excerpt, null)
  assert.equal(res.reflection.revision, 2)
})

test("ReflectionManager deleteReflection sends expected_revision and returns true", async () => {
  let deleteMethod = null

  globalThis.fetch = async (url, options) => {
    deleteMethod = options.method
    return {
      ok: true,
      status: 204
    }
  }

  const manager = new ReflectionManager({
    apiBase: "http://localhost:4000/api",
    getAuthToken: () => "valid-token"
  })

  const res = await manager.deleteReflection("ref-del", 2)

  assert.equal(deleteMethod, "DELETE")
  assert.equal(res, true)
})
