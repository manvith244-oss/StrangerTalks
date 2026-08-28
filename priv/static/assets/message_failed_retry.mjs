import {Socket} from "/vendor/phoenix.mjs"
import {getRecord, putRecord} from "./local_data.mjs"
import {messageSendTimeoutDisposition} from "./message_retry_policy.mjs"

const retryableMessages = new Map()
let retryInteractionInstalled = false

function messageId(payload) {
  return payload?.client_message_id || payload?.message_id || null
}

function conversationId(channel) {
  const topic = channel?.topic || ""
  return topic.startsWith("conversation:") ? topic.slice("conversation:".length) : null
}

function isTextMessageSend(event, payload) {
  return event === "message:send" && typeof payload?.content === "string" && Boolean(messageId(payload))
}

function messageNode(id) {
  if (!id) return null
  return document.querySelector(`#messages li.message[data-message-id="${CSS.escape(id)}"]`)
}

function normalizeDeliveryStatus(status) {
  return status === "sent_to_server" ? "sent" : (status || "sent")
}

function renderState(id, state) {
  const item = messageNode(id)
  if (!item) return
  const status = item.querySelector(":scope > .message-status")
  if (!status) return

  if (state === "failed") {
    item.dataset.failedTextRetry = "true"
    item.style.cursor = "pointer"
    status.textContent = "Failed · Tap to retry"
    status.style.color = "var(--st-danger)"
    status.style.fontWeight = "700"
    return
  }

  delete item.dataset.failedTextRetry
  item.style.removeProperty("cursor")
  status.style.removeProperty("color")
  status.style.removeProperty("font-weight")
  status.textContent = state
}

async function persistState(entry, state, result = null) {
  if (!entry?.conversationId || !entry?.id) return
  const key = `message:${entry.conversationId}:${entry.id}`
  const record = await getRecord(key).catch(() => null)
  if (!record || record.type !== "local_message" || !record.value?.mine || record.value?.type !== "text") return

  const sequence = Number.isInteger(result?.sequence) ? result.sequence : record.value.sequence
  await putRecord({
    ...record,
    value: {...record.value, delivery_status: normalizeDeliveryStatus(state), sequence},
    updated_at: new Date().toISOString()
  }).catch(() => {})
}

function announceRetryFailure(error) {
  const status = document.querySelector("#status")
  if (!status) return
  const code = (error?.error?.code || error?.code || error?.reason || "").toUpperCase().replace(/[\s-]+/g, "_")
  if (["RATE_LIMITED", "MESSAGE_BUFFER_FULL"].includes(code)) {
    status.textContent = "Sending too quickly. Please wait a moment."
  } else if (code === "CONVERSATION_BUSY") {
    status.textContent = "The Conversation is busy. Please wait a moment."
  } else {
    status.textContent = "An unexpected error occurred. Please try again."
  }
}

function markFailed(entry, error, manualRetry) {
  entry.retryInFlight = false
  retryableMessages.set(entry.id, entry)
  persistState(entry, "failed")
  setTimeout(() => renderState(entry.id, "failed"), 0)
  if (manualRetry) announceRetryFailure(error)
}

function markAccepted(entry, result) {
  entry.retryInFlight = false
  retryableMessages.delete(entry.id)
  const state = normalizeDeliveryStatus(result?.status || "sent")
  persistState(entry, state, result)
  renderState(entry.id, state)
}

function timeoutIsDefinitive(channel) {
  return messageSendTimeoutDisposition({
    socketConnected: channel?.socket?.isConnected?.() === true,
    channelState: channel?.state
  }) === "failed"
}

function observeTextPush(channel, event, payload, push) {
  if (!isTextMessageSend(event, payload)) return
  const id = messageId(payload)
  const entry = retryableMessages.get(id) || {
    id,
    conversationId: conversationId(channel),
    channel,
    payload: {...payload},
    retryInFlight: false
  }
  entry.channel = channel
  entry.payload = {...payload}
  const manualRetry = entry.retryInFlight === true

  push.receive("ok", (result) => markAccepted(entry, result))
  push.receive("error", (error) => markFailed(entry, error, manualRetry))
  push.receive("timeout", () => {
    if (timeoutIsDefinitive(channel)) {
      markFailed(entry, {reason: "timeout"}, manualRetry)
    } else {
      entry.retryInFlight = false
      retryableMessages.delete(id)
    }
  })
}

async function retryMessage(item) {
  const id = item?.dataset?.messageId
  const entry = retryableMessages.get(id)
  if (!entry || entry.retryInFlight) return

  entry.retryInFlight = true
  renderState(id, "sending")
  await persistState(entry, "sending")
  entry.channel.push("message:send", {...entry.payload})
}

function retryTarget(event) {
  const item = event.target?.closest?.('#messages li.message[data-failed-text-retry="true"]')
  if (!item) return null
  if (event.target.closest("button, a, input, textarea, select, [role=button]")) return null
  return item
}

function installRetryInteraction() {
  if (retryInteractionInstalled) return
  retryInteractionInstalled = true

  document.addEventListener("click", (event) => {
    const item = retryTarget(event)
    if (!item) return
    event.preventDefault()
    retryMessage(item)
  })

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return
    const item = retryTarget(event)
    if (!item || event.target !== item) return
    event.preventDefault()
    retryMessage(item)
  })
}

function patchConversationChannel(channel) {
  if (channel.__failedTextRetryPatched) return channel
  channel.__failedTextRetryPatched = true
  const originalPush = channel.push.bind(channel)
  channel.push = function(event, payload = {}, timeout) {
    const push = originalPush(event, payload, timeout)
    observeTextPush(channel, event, payload, push)
    return push
  }
  return channel
}

installRetryInteraction()

const originalSocketChannel = Socket.prototype.channel
Socket.prototype.channel = function(topic, params) {
  const channel = originalSocketChannel.call(this, topic, params)
  if (typeof topic === "string" && topic.startsWith("conversation:")) return patchConversationChannel(channel)
  return channel
}