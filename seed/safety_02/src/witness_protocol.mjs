import {
  bytesToHex,
  createCoseSign1,
  decodeCosePayload,
  digestBytes,
  equalBytes,
  generateEd25519Pair,
  protocolError,
  verifyCoseSign1
} from "./cose.mjs"
import {acceptanceLeafBytes, merkleRoot, verifyInclusionProof} from "./merkle.mjs"

export {createCoseSign1, decodeCosePayload, digestBytes}

export async function generateEndpointKey({endpointId, participantSlot}) {
  if (typeof endpointId !== "string" || !endpointId || !["A", "B"].includes(participantSlot)) {
    throw protocolError("invalid_endpoint_identity")
  }
  const pair = await generateEd25519Pair()
  return {
    endpointId,
    participantSlot,
    ...pair,
    fingerprint: bytesToHex(await digestBytes(pair.publicKeyBytes))
  }
}

export async function createServerAuthority({kid = "server-k1"} = {}) {
  const keys = new Map()
  let activeKid = kid

  async function add(keyId) {
    if (typeof keyId !== "string" || !keyId || keys.has(keyId)) throw protocolError("invalid_server_key_rotation")
    keys.set(keyId, await generateEd25519Pair())
  }
  await add(activeKid)

  return {
    get activeKid() { return activeKid },
    async sign(payload) {
      return createCoseSign1({payload, privateKey: keys.get(activeKid).privateKey, kid: activeKid})
    },
    async rotate(nextKid) {
      await add(nextKid)
      activeKid = nextKid
      return activeKid
    },
    verificationKeys() {
      return new Map([...keys].map(([keyId, pair]) => [keyId, new Uint8Array(pair.publicKeyBytes)]))
    }
  }
}

async function verifyServerObject(coseBytes, keyring, expectedKind) {
  const verified = await verifyCoseSign1({
    coseBytes,
    resolvePublicKey: kid => keyring.get(kid),
    missingKeyCode: "unknown_server_key",
    invalidSignatureCode: "invalid_server_signature"
  })
  if (verified.payload?.kind !== expectedKind) throw protocolError("unexpected_server_object")
  return verified
}

export function createSessionAuthority({serverAuthority, enforceKeyFreshness = true}) {
  if (!serverAuthority?.sign) throw protocolError("invalid_server_authority")
  const active = new Map()
  const keyUse = new Map()

  async function issueSessionCertificate({sessionId, epoch, endpoints, issuedAt, expiresAt}) {
    if (typeof sessionId !== "string" || !sessionId || !Number.isInteger(epoch) || epoch < 1 ||
        !Array.isArray(endpoints) || endpoints.length < 2 || !Number.isInteger(issuedAt) ||
        !Number.isInteger(expiresAt) || expiresAt <= issuedAt) throw protocolError("invalid_session_certificate_input")

    const endpointIds = new Set()
    for (const endpoint of endpoints) {
      if (!endpoint || typeof endpoint.endpointId !== "string" || !endpoint.endpointId ||
          !["A", "B"].includes(endpoint.participantSlot) || !(endpoint.publicKeyBytes instanceof Uint8Array) ||
          typeof endpoint.fingerprint !== "string" || endpointIds.has(endpoint.endpointId)) throw protocolError("invalid_session_endpoint")
      endpointIds.add(endpoint.endpointId)
      const previousSession = keyUse.get(endpoint.fingerprint)
      if (enforceKeyFreshness && previousSession && previousSession !== sessionId) throw protocolError("endpoint_key_reuse")
    }

    const previous = active.get(sessionId)
    if (previous && epoch <= previous.epoch) throw protocolError("non_monotonic_certificate_epoch")
    const payload = {
      kind: "session_certificate",
      version: 1,
      session_id: sessionId,
      epoch,
      issued_at: issuedAt,
      expires_at: expiresAt,
      endpoints: [...endpoints]
        .sort((a, b) => a.endpointId.localeCompare(b.endpointId))
        .map(endpoint => ({
          endpoint_id: endpoint.endpointId,
          participant_slot: endpoint.participantSlot,
          public_key: endpoint.publicKeyBytes,
          public_key_fingerprint: endpoint.fingerprint
        }))
    }
    const certificate = await serverAuthority.sign(payload)
    const certificateDigest = await digestBytes(certificate)
    for (const endpoint of endpoints) keyUse.set(endpoint.fingerprint, sessionId)
    active.set(sessionId, {epoch, digest: certificateDigest})
    return certificate
  }

  return {
    issueSessionCertificate,
    async rotateSessionCertificate({sessionId, endpoints, issuedAt, expiresAt}) {
      const current = active.get(sessionId)
      if (!current) throw protocolError("unknown_session")
      return issueSessionCertificate({sessionId, epoch: current.epoch + 1, endpoints, issuedAt, expiresAt})
    },
    isActiveCertificate(sessionId, digest) {
      const current = active.get(sessionId)
      return Boolean(current && equalBytes(current.digest, digest))
    },
    reuseRegistrySize() { return keyUse.size }
  }
}

export async function signMessageEnvelope({
  endpoint,
  sessionCertificate,
  senderSequence,
  previousSenderDigest = null,
  clientMessageId,
  messageType = "text",
  content
}) {
  if (!endpoint?.privateKey || !Number.isInteger(senderSequence) || senderSequence < 1 ||
      (previousSenderDigest !== null && !(previousSenderDigest instanceof Uint8Array)) ||
      typeof clientMessageId !== "string" || !clientMessageId || typeof messageType !== "string" ||
      typeof content !== "string") throw protocolError("invalid_message_input")

  const certificate = decodeCosePayload(sessionCertificate)
  const member = certificate.endpoints?.find(item => item.endpoint_id === endpoint.endpointId)
  if (!member || member.participant_slot !== endpoint.participantSlot || !equalBytes(member.public_key, endpoint.publicKeyBytes)) {
    throw protocolError("endpoint_not_in_certificate")
  }
  return createCoseSign1({
    privateKey: endpoint.privateKey,
    kid: endpoint.endpointId,
    payload: {
      kind: "witness_message",
      version: 1,
      session_id: certificate.session_id,
      certificate_digest: await digestBytes(sessionCertificate),
      endpoint_id: endpoint.endpointId,
      sender_sequence: senderSequence,
      previous_sender_digest: previousSenderDigest,
      client_message_id: clientMessageId,
      message_type: messageType,
      content
    }
  })
}

export function createAcceptanceAuthority({serverAuthority, sessionAuthority}) {
  if (!serverAuthority?.sign || !sessionAuthority?.isActiveCertificate) throw protocolError("invalid_acceptance_authority")
  const states = new Map()

  function stateFor(sessionId) {
    if (!states.has(sessionId)) {
      states.set(sessionId, {global: 0, senders: new Map(), digests: new Set(), ids: new Set(), accepted: []})
    }
    return states.get(sessionId)
  }

  return {
    async acceptMessage({sessionCertificate, messageEnvelope, acceptedAt}) {
      if (!Number.isInteger(acceptedAt)) throw protocolError("invalid_acceptance_time")
      const certVerified = await verifyServerObject(sessionCertificate, serverAuthority.verificationKeys(), "session_certificate")
      const certificate = certVerified.payload
      if (!sessionAuthority.isActiveCertificate(certificate.session_id, certVerified.digest)) throw protocolError("stale_certificate")
      if (acceptedAt < certificate.issued_at) throw protocolError("certificate_not_yet_valid")
      if (acceptedAt > certificate.expires_at) throw protocolError("certificate_expired")

      const endpointMap = new Map(certificate.endpoints.map(endpoint => [endpoint.endpoint_id, endpoint]))
      let messageVerified
      try {
        messageVerified = await verifyCoseSign1({
          coseBytes: messageEnvelope,
          resolvePublicKey: kid => endpointMap.get(kid)?.public_key ?? null,
          missingKeyCode: "unknown_endpoint_key",
          invalidSignatureCode: "invalid_endpoint_signature"
        })
      } catch (error) {
        if (["malformed_cose", "malformed_cose_payload"].includes(error?.code)) throw error
        if (["unknown_endpoint_key", "invalid_endpoint_signature"].includes(error?.code)) throw protocolError("invalid_endpoint_signature", error)
        throw error
      }
      const message = messageVerified.payload
      if (message.kind !== "witness_message" || message.version !== 1 || messageVerified.kid !== message.endpoint_id ||
          !endpointMap.has(message.endpoint_id) || message.session_id !== certificate.session_id ||
          !equalBytes(message.certificate_digest, certVerified.digest)) throw protocolError("message_certificate_mismatch")

      const state = stateFor(certificate.session_id)
      const digestHex = bytesToHex(messageVerified.digest)
      if (state.digests.has(digestHex) || state.ids.has(message.client_message_id)) throw protocolError("message_replay")
      const sender = state.senders.get(message.endpoint_id) ?? {sequence: 0, digest: null}
      if (message.sender_sequence !== sender.sequence + 1) throw protocolError("sender_sequence_gap")
      if (message.sender_sequence === 1) {
        if (message.previous_sender_digest !== null) throw protocolError("sender_chain_mismatch")
      } else if (!equalBytes(message.previous_sender_digest, sender.digest)) {
        throw protocolError("sender_chain_mismatch")
      }

      const globalSequence = ++state.global
      const receipt = await serverAuthority.sign({
        kind: "acceptance_receipt",
        version: 1,
        session_id: certificate.session_id,
        certificate_digest: certVerified.digest,
        global_sequence: globalSequence,
        message_digest: messageVerified.digest,
        endpoint_id: message.endpoint_id,
        accepted_at: acceptedAt
      })
      state.digests.add(digestHex)
      state.ids.add(message.client_message_id)
      state.senders.set(message.endpoint_id, {sequence: message.sender_sequence, digest: messageVerified.digest})
      state.accepted.push({global_sequence: globalSequence, message_digest: messageVerified.digest, endpoint_id: message.endpoint_id, acceptance_receipt: receipt})
      return {acceptanceReceipt: receipt, messageDigest: messageVerified.digest, globalSequence}
    },
    acceptedRecords(sessionId) {
      return (states.get(sessionId)?.accepted ?? []).map(record => ({
        ...record,
        message_digest: new Uint8Array(record.message_digest),
        acceptance_receipt: new Uint8Array(record.acceptance_receipt)
      }))
    }
  }
}

function reportSkeleton() {
  return {
    cryptographic_authenticity: "INVALID",
    safety_adjudication: "NOT_DETERMINED",
    human_authorship: "NOT_PROVEN",
    context_completeness: "UNESTABLISHED",
    messages: [],
    warnings: [],
    errors: [],
    limitations: [
      "endpoint_compromise_not_detectable",
      "cryptographic_authenticity_does_not_establish_context_or_aggressor"
    ]
  }
}

function addOnce(array, value) {
  if (!array.includes(value)) array.push(value)
}

async function verifyEvidenceItem(item, certificate, certDigest, endpointMap, serverVerificationKeys) {
  const messageVerified = await verifyCoseSign1({
    coseBytes: item.messageEnvelope,
    resolvePublicKey: kid => endpointMap.get(kid)?.public_key ?? null,
    missingKeyCode: "unknown_endpoint_key",
    invalidSignatureCode: "invalid_endpoint_signature"
  })
  const message = messageVerified.payload
  const endpoint = endpointMap.get(message.endpoint_id)
  if (!endpoint || messageVerified.kid !== message.endpoint_id || message.kind !== "witness_message" ||
      message.session_id !== certificate.session_id || !equalBytes(message.certificate_digest, certDigest)) {
    throw protocolError("message_certificate_mismatch")
  }

  const receiptVerified = await verifyServerObject(item.acceptanceReceipt, serverVerificationKeys, "acceptance_receipt")
  const receipt = receiptVerified.payload
  if (receipt.session_id !== certificate.session_id || receipt.endpoint_id !== message.endpoint_id ||
      !equalBytes(receipt.certificate_digest, certDigest) || !equalBytes(receipt.message_digest, messageVerified.digest) ||
      !Number.isInteger(receipt.global_sequence) || receipt.global_sequence < 1 || !Number.isInteger(receipt.accepted_at) ||
      receipt.accepted_at < certificate.issued_at || receipt.accepted_at > certificate.expires_at) {
    throw protocolError("invalid_acceptance_receipt")
  }
  return {
    endpoint_id: message.endpoint_id,
    participant_slot: endpoint.participant_slot,
    content: message.content,
    sender_sequence: message.sender_sequence,
    previous_sender_digest: message.previous_sender_digest,
    global_sequence: receipt.global_sequence,
    accepted_at: receipt.accepted_at,
    message_digest: messageVerified.digest,
    inclusionProof: item.inclusionProof ?? null
  }
}

function assessSequenceWarnings(messages, report) {
  const submitted = messages.map(message => message.global_sequence)
  for (let i = 1; i < submitted.length; i += 1) {
    if (submitted[i] <= submitted[i - 1]) addOnce(report.warnings, "submitted_cross_sender_reorder")
  }
  const global = [...messages].sort((a, b) => a.global_sequence - b.global_sequence)
  for (let i = 1; i < global.length; i += 1) {
    if (global[i].global_sequence > global[i - 1].global_sequence + 1) addOnce(report.warnings, "global_sequence_gap")
  }
  const byEndpoint = new Map()
  for (const message of messages) {
    const rows = byEndpoint.get(message.endpoint_id) ?? []
    rows.push(message)
    byEndpoint.set(message.endpoint_id, rows)
  }
  for (const rows of byEndpoint.values()) {
    rows.sort((a, b) => a.sender_sequence - b.sender_sequence)
    if (rows[0]?.sender_sequence > 1) addOnce(report.warnings, "sender_sequence_gap")
    for (let i = 1; i < rows.length; i += 1) {
      if (rows[i].sender_sequence !== rows[i - 1].sender_sequence + 1 ||
          !equalBytes(rows[i].previous_sender_digest, rows[i - 1].message_digest)) addOnce(report.warnings, "sender_sequence_gap")
    }
  }
}

export async function verifyEvidenceReport({
  mode,
  serverVerificationKeys,
  sessionCertificate,
  evidence,
  finalCommitment = null,
  claimedComplete = false,
  reportCreatedAt = Date.now()
}) {
  const report = reportSkeleton()
  if (!(serverVerificationKeys instanceof Map) || !["A", "B"].includes(mode) || !Array.isArray(evidence) || !Number.isFinite(reportCreatedAt)) {
    report.errors.push("invalid_report_input")
    return report
  }

  let certVerified
  try {
    certVerified = await verifyServerObject(sessionCertificate, serverVerificationKeys, "session_certificate")
  } catch (error) {
    report.errors.push(error?.code ?? "invalid_session_certificate")
    return report
  }
  const certificate = certVerified.payload
  const endpointMap = new Map(certificate.endpoints.map(endpoint => [endpoint.endpoint_id, endpoint]))
  const verified = []
  for (const item of evidence) {
    try {
      verified.push(await verifyEvidenceItem(item, certificate, certVerified.digest, endpointMap, serverVerificationKeys))
    } catch (error) {
      report.errors.push(error?.code ?? "invalid_evidence")
      return report
    }
  }

  assessSequenceWarnings(verified, report)
  report.cryptographic_authenticity = "VERIFIED"
  report.messages = verified.map(({message_digest, previous_sender_digest, inclusionProof, ...visible}) => visible)

  if (mode === "A") {
    report.context_completeness = claimedComplete ? "UNPROVABLE_IN_MODE_A" : "SELECTIVE_AUTHENTIC_EXCERPT"
    if (claimedComplete) addOnce(report.warnings, "trailing_omission_cannot_be_ruled_out")
    return report
  }

  if (!(finalCommitment instanceof Uint8Array)) {
    report.cryptographic_authenticity = "INVALID"
    report.errors.push("missing_final_commitment")
    return report
  }

  let finalVerified
  try {
    finalVerified = await verifyServerObject(finalCommitment, serverVerificationKeys, "final_session_commitment")
  } catch (error) {
    report.cryptographic_authenticity = "INVALID"
    report.errors.push(error?.code ?? "invalid_final_commitment")
    return report
  }
  const final = finalVerified.payload
  if (final.session_id !== certificate.session_id || final.version !== 1 || final.merkle_algorithm !== "RFC6962_SHA256_ORDERED_V1" ||
      !Number.isInteger(final.final_accepted_sequence) || !Number.isInteger(final.accepted_count) ||
      final.final_accepted_sequence !== final.accepted_count || !(final.merkle_root instanceof Uint8Array)) {
    report.cryptographic_authenticity = "INVALID"
    report.errors.push("invalid_final_commitment")
    return report
  }

  for (const message of verified) {
    if (!await verifyInclusionProof({
      leaf: acceptanceLeafBytes(message.global_sequence, message.message_digest),
      index: message.global_sequence - 1,
      treeSize: final.accepted_count,
      proof: message.inclusionProof,
      root: final.merkle_root
    })) {
      report.cryptographic_authenticity = "INVALID"
      report.errors.push("invalid_merkle_inclusion_proof")
      return report
    }
  }

  report.final_accepted_sequence = final.final_accepted_sequence
  report.final_message_count = final.accepted_count
  if (!claimedComplete) {
    report.context_completeness = "SELECTIVE_AUTHENTIC_EXCERPT"
    return report
  }

  const ordered = [...verified].sort((a, b) => a.global_sequence - b.global_sequence)
  const allSequences = ordered.length === final.accepted_count && ordered.every((message, index) => message.global_sequence === index + 1)
  if (allSequences) {
    const root = await merkleRoot(ordered.map(message => acceptanceLeafBytes(message.global_sequence, message.message_digest)))
    if (equalBytes(root, final.merkle_root)) {
      report.context_completeness = "COMPLETE_AGAINST_FINAL_COMMITMENT"
      return report
    }
  }

  report.context_completeness = "INCOMPLETE_AGAINST_FINAL_COMMITMENT"
  const maxReported = ordered.length ? ordered.at(-1).global_sequence : 0
  if (maxReported < final.final_accepted_sequence) addOnce(report.warnings, "trailing_omission_detected")
  return report
}
