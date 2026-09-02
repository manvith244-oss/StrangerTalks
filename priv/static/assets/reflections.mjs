// Feature 1T — Private Save / Reflection
// Pure client-side manager with document-RAM only raw grant secret storage.

export class ReflectionManager {
  constructor({apiBase = "/api", getAuthToken = () => null, onNotify = () => {}} = {}) {
    this.apiBase = apiBase
    this.getAuthToken = getAuthToken
    this.onNotify = onNotify
    // Raw grant secret stored in Document RAM only (never localStorage/sessionStorage/IndexedDB)
    this.activeGrant = null
    this.undoTimeout = null
    this.lastSavedReflectionId = null
    this.cachedReflections = []
  }

  setGrant(grantInfo) {
    if (!grantInfo) {
      this.activeGrant = null
      return
    }
    this.activeGrant = {
      grantId: grantInfo.grant_id || grantInfo.grantId,
      rawSecret: grantInfo.raw_secret || grantInfo.rawSecret,
      excerpt: grantInfo.excerpt || null,
      sourceClientMessageId: grantInfo.source_client_message_id || grantInfo.sourceClientMessageId,
      sourceConversationId: grantInfo.source_conversation_id || grantInfo.sourceConversationId,
      expectedSourceRevision: Number.isInteger(grantInfo.expected_source_revision)
        ? grantInfo.expected_source_revision
        : (Number.isInteger(grantInfo.expectedSourceRevision) ? grantInfo.expectedSourceRevision : null)
    }
  }

  clearGrant() {
    this.activeGrant = null
  }

  getGrant() {
    return this.activeGrant
  }

  async requestGrant({conversationId, clientMessageId, expectedRevision, startGrapheme, endGrapheme}) {
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const res = await fetch(`${this.apiBase}/reflections/grants`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${token}`
      },
      body: JSON.stringify({
        source_conversation_id: conversationId,
        source_client_message_id: clientMessageId,
        expected_source_revision: expectedRevision,
        selection_start_grapheme: startGrapheme,
        selection_end_grapheme: endGrapheme
      })
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error((err && err.error && err.error.reason) || "grant_request_failed")
    }

    const data = await res.json()
    this.setGrant({
      ...data,
      source_conversation_id: conversationId
    })
    return data
  }

  async saveReflection({ownReflectionText, createOperationId = crypto.randomUUID()}) {
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const payload = {
      create_operation_id: createOperationId,
      own_reflection_text: ownReflectionText
    }

    if (this.activeGrant && this.activeGrant.grantId) {
      payload.grant_id = this.activeGrant.grantId
      payload.grant_secret = this.activeGrant.rawSecret
      if (this.activeGrant.sourceConversationId) {
        payload.source_conversation_id = this.activeGrant.sourceConversationId
      }
      if (this.activeGrant.sourceClientMessageId) {
        payload.source_client_message_id = this.activeGrant.sourceClientMessageId
      }
      if (this.activeGrant.expectedSourceRevision !== null) {
        payload.expected_source_revision = this.activeGrant.expectedSourceRevision
      }
      if (this.activeGrant.excerpt) {
        payload.source_excerpt = this.activeGrant.excerpt
      }
    }

    const res = await fetch(`${this.apiBase}/reflections`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${token}`
      },
      body: JSON.stringify(payload)
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error((err && err.error && err.error.reason) || "save_failed")
    }

    const data = await res.json()
    // Grant is consumed, clear active document-RAM grant
    this.clearGrant()

    const reflection = data.reflection
    this.lastSavedReflectionId = reflection.reflection_id
    this.scheduleUndoTimer(reflection.reflection_id)
    return data
  }

  scheduleUndoTimer(reflectionId) {
    if (this.undoTimeout) {
      clearTimeout(this.undoTimeout)
    }
    this.undoTimeout = setTimeout(() => {
      if (this.lastSavedReflectionId === reflectionId) {
        this.lastSavedReflectionId = null
      }
      this.onNotify("undo_window_closed", {reflectionId})
    }, 10000)
  }

  async undoLastSave() {
    if (!this.lastSavedReflectionId) {
      throw new Error("no_active_undo")
    }
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const reflectionId = this.lastSavedReflectionId
    const res = await fetch(`${this.apiBase}/reflections/${reflectionId}/undo`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${token}`
      }
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error((err && err.error && err.error.reason) || "undo_failed")
    }

    this.lastSavedReflectionId = null
    if (this.undoTimeout) clearTimeout(this.undoTimeout)
    return await res.json()
  }

  async listReflections() {
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const res = await fetch(`${this.apiBase}/reflections`, {
      headers: {
        "authorization": `Bearer ${token}`
      }
    })

    if (!res.ok) {
      throw new Error("fetch_failed")
    }

    const data = await res.json()
    this.cachedReflections = data.reflections || []
    return this.cachedReflections
  }

  async updateNote(reflectionId, expectedRevision, newText) {
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const res = await fetch(`${this.apiBase}/reflections/${reflectionId}`, {
      method: "PUT",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${token}`
      },
      body: JSON.stringify({
        expected_revision: expectedRevision,
        own_reflection_text: newText
      })
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error((err && err.error && err.error.reason) || "update_failed")
    }

    return await res.json()
  }

  async removeExcerpt(reflectionId, expectedRevision) {
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const res = await fetch(`${this.apiBase}/reflections/${reflectionId}/remove-excerpt`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${token}`
      },
      body: JSON.stringify({
        expected_revision: expectedRevision
      })
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error((err && err.error && err.error.reason) || "remove_excerpt_failed")
    }

    return await res.json()
  }

  async deleteReflection(reflectionId, expectedRevision = null) {
    const token = this.getAuthToken()
    if (!token) throw new Error("unauthorized")

    const headers = {
      "authorization": `Bearer ${token}`
    }
    if (expectedRevision !== null) {
      headers["content-type"] = "application/json"
    }

    const res = await fetch(`${this.apiBase}/reflections/${reflectionId}`, {
      method: "DELETE",
      headers,
      body: expectedRevision !== null ? JSON.stringify({expected_revision: expectedRevision}) : undefined
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error((err && err.error && err.error.reason) || "delete_failed")
    }

    return true
  }
}
