import {deleteRecord, getRecord, putRecord} from "./local_data.mjs"

const DRAFT_TYPE = "conversation_draft"
const DRAFT_SCHEMA_VERSION = 1
const RESTORE_RETRY_MS = 25
const RESTORE_ATTEMPTS = 80

const runtime = {
  installed: false,
  activeConversationId: null,
  pendingSubmit: null,
  storageTail: Promise.resolve()
}

export function conversationDraftKey(conversationId) {
  return `${DRAFT_TYPE}:${conversationId}`
}

export function conversationDraftRecord(conversationId, text, updatedAt = new Date().toISOString()) {
  return {
    id: conversationDraftKey(conversationId),
    type: DRAFT_TYPE,
    schema_version: DRAFT_SCHEMA_VERSION,
    value: {conversation_id: conversationId, text},
    updated_at: updatedAt
  }
}

function enqueueStorage(operation) {
  const next = runtime.storageTail.then(operation, operation)
  runtime.storageTail = next.catch(() => {})
  return next
}

function validDraft(record, conversationId) {
  return record?.id === conversationDraftKey(conversationId) &&
    record?.type === DRAFT_TYPE &&
    record?.schema_version === DRAFT_SCHEMA_VERSION &&
    record?.value?.conversation_id === conversationId &&
    typeof record?.value?.text === "string"
}

function persistDraft(conversationId, text) {
  return enqueueStorage(async () => {
    if (text.length === 0) {
      await deleteRecord(conversationDraftKey(conversationId))
      return null
    }
    return putRecord(conversationDraftRecord(conversationId, text))
  })
}

function clearDraft(conversationId) {
  return enqueueStorage(() => deleteRecord(conversationDraftKey(conversationId)))
}

function clearMatchingDraft(conversationId, submittedText) {
  return enqueueStorage(async () => {
    const key = conversationDraftKey(conversationId)
    const record = await getRecord(key)
    if (!validDraft(record, conversationId)) return false
    if (record.value.text !== submittedText) return false
    await deleteRecord(key)
    return true
  })
}

async function restoreDraft(conversationId) {
  const record = await enqueueStorage(() => getRecord(conversationDraftKey(conversationId)))
  if (runtime.activeConversationId !== conversationId) return false
  if (!record) return false

  if (!validDraft(record, conversationId)) {
    await clearDraft(conversationId)
    return false
  }

  const screen = document.querySelector('section[data-screen="conversation"].active')
  const input = document.querySelector("#message-input")
  if (!screen || !input || input.value !== "") return false
  input.value = record.value.text
  return true
}

function scheduleRestore(conversationId) {
  let attempts = 0
  const tryRestore = () => {
    if (runtime.activeConversationId !== conversationId) return
    const screen = document.querySelector('section[data-screen="conversation"].active')
    const input = document.querySelector("#message-input")
    if (!screen || !input) {
      attempts += 1
      if (attempts < RESTORE_ATTEMPTS) setTimeout(tryRestore, RESTORE_RETRY_MS)
      return
    }
    restoreDraft(conversationId).catch(() => {})
  }
  setTimeout(tryRestore, 0)
}

function deferredChannelPush(beforeStart, startPush) {
  let actualPush = null
  const receivers = []

  const proxy = {
    receive(status, callback) {
      if (actualPush) actualPush.receive(status, callback)
      else receivers.push([status, callback])
      return proxy
    }
  }

  Promise.resolve()
    .then(beforeStart)
    .catch(() => {})
    .then(() => {
      actualPush = startPush()
      for (const [status, callback] of receivers) actualPush.receive(status, callback)
    })

  return proxy
}

function consumePendingTextSubmit(conversationId, payload) {
  const pending = runtime.pendingSubmit
  if (!pending) return null
  if (pending.conversationId !== conversationId) return null
  if (typeof payload?.content !== "string" || payload.content !== pending.content) return null
  runtime.pendingSubmit = null
  return pending
}

function patchConversationChannel(channel, conversationId) {
  if (channel.__conversationDraftPersistencePatched) return channel
  channel.__conversationDraftPersistencePatched = true

  const originalPush = channel.push.bind(channel)
  channel.push = function(event, payload = {}, timeout) {
    if (event === "message:send" && typeof payload?.content === "string") {
      const pending = consumePendingTextSubmit(conversationId, payload)
      if (pending) {
        return deferredChannelPush(
          () => clearMatchingDraft(conversationId, pending.rawText),
          () => originalPush(event, payload, timeout)
        )
      }
    }
    return originalPush(event, payload, timeout)
  }

  const originalJoin = channel.join.bind(channel)
  channel.join = function(timeout) {
    const joinPush = originalJoin(timeout)
    joinPush.receive("ok", () => scheduleRestore(conversationId))
    return joinPush
  }

  channel.on("conversation:ended", () => {
    if (runtime.activeConversationId === conversationId) runtime.activeConversationId = null
    if (runtime.pendingSubmit?.conversationId === conversationId) runtime.pendingSubmit = null
    clearDraft(conversationId).catch(() => {})
  })

  scheduleRestore(conversationId)
  return channel
}

function installComposerListeners() {
  document.addEventListener("input", event => {
    const input = event.target
    if (!(input instanceof HTMLTextAreaElement) || input.id !== "message-input") return
    const conversationId = runtime.activeConversationId
    if (!conversationId) return
    persistDraft(conversationId, input.value).catch(() => {})
  }, true)

  document.addEventListener("submit", event => {
    if (!(event.target instanceof HTMLFormElement) || event.target.id !== "message-form") return
    const input = document.querySelector("#message-input")
    const conversationId = runtime.activeConversationId
    const rawText = input?.value ?? ""
    const content = rawText.trim()
    if (!conversationId || !content) {
      runtime.pendingSubmit = null
      return
    }

    const pending = {
      conversationId,
      rawText,
      content,
      messageCount: document.querySelectorAll("#messages > .message").length
    }
    runtime.pendingSubmit = pending

    queueMicrotask(() => {
      if (runtime.pendingSubmit !== pending || runtime.activeConversationId !== conversationId) return
      const composer = document.querySelector("#message-input")
      const messageCount = document.querySelectorAll("#messages > .message").length
      if (!composer || composer.value !== rawText || messageCount <= pending.messageCount) return
      composer.value = ""
      clearMatchingDraft(conversationId, rawText).catch(() => {})
    })
  }, true)
}

export function installConversationDraftRuntime({SocketClass}) {
  if (runtime.installed) return runtime
  if (!SocketClass?.prototype?.channel) throw new TypeError("SocketClass with channel() is required")
  runtime.installed = true

  const originalSocketChannel = SocketClass.prototype.channel
  SocketClass.prototype.channel = function(topic, params) {
    const channel = originalSocketChannel.call(this, topic, params)
    if (typeof topic !== "string" || !topic.startsWith("conversation:")) return channel
    const conversationId = topic.slice("conversation:".length)
    if (!conversationId) return channel
    runtime.activeConversationId = conversationId
    return patchConversationChannel(channel, conversationId)
  }

  installComposerListeners()
  return runtime
}
