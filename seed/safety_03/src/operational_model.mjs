import {createHash} from 'node:crypto'

export const EvidenceClass = Object.freeze({
  LOCAL_EVIDENCE_UNAVAILABLE: 'LOCAL_EVIDENCE_UNAVAILABLE',
  MALFORMED_EVIDENCE: 'MALFORMED_EVIDENCE',
  INVALID_ENDPOINT_SIGNATURE: 'INVALID_ENDPOINT_SIGNATURE',
  HISTORICAL_SERVER_KEY_UNAVAILABLE: 'HISTORICAL_SERVER_KEY_UNAVAILABLE',
  ENDPOINT_AUTHENTICITY_ONLY: 'ENDPOINT_AUTHENTICITY_ONLY',
  INVALID_ACCEPTANCE_RECEIPT: 'INVALID_ACCEPTANCE_RECEIPT',
  ACCEPTED_EXCERPT: 'ACCEPTED_EXCERPT',
  FINALIZATION_INCOMPLETE: 'FINALIZATION_INCOMPLETE',
  INVALID_FINAL_COMMITMENT: 'INVALID_FINAL_COMMITMENT',
  TRAILING_OMISSION_DETECTED: 'TRAILING_OMISSION_DETECTED',
  ACCEPTED_COMPLETE: 'ACCEPTED_COMPLETE'
})

const SAFETY_ADJUDICATION = 'NOT_DETERMINED'

function result(classification, detail = null) {
  return {classification, detail, safetyAdjudication: SAFETY_ADJUDICATION}
}

export function classifyEvidence(input = {}) {
  if (!input.localEvidencePresent) {
    return result(EvidenceClass.LOCAL_EVIDENCE_UNAVAILABLE)
  }
  if (input.malformed === true) {
    return result(EvidenceClass.MALFORMED_EVIDENCE)
  }
  if (input.endpointSignatureValid !== true) {
    return result(EvidenceClass.INVALID_ENDPOINT_SIGNATURE)
  }
  if (input.historicalServerKeyAvailable === false) {
    return result(EvidenceClass.HISTORICAL_SERVER_KEY_UNAVAILABLE)
  }
  if (input.acceptanceReceiptPresent !== true) {
    return result(EvidenceClass.ENDPOINT_AUTHENTICITY_ONLY)
  }
  if (input.acceptanceReceiptValid !== true) {
    return result(EvidenceClass.INVALID_ACCEPTANCE_RECEIPT)
  }
  if (input.mode !== 'B') {
    return result(EvidenceClass.ACCEPTED_EXCERPT)
  }
  if (input.finalCommitmentPresent !== true) {
    return result(EvidenceClass.FINALIZATION_INCOMPLETE)
  }
  if (input.finalCommitmentValid !== true) {
    return result(EvidenceClass.INVALID_FINAL_COMMITMENT)
  }

  if (
    Number.isInteger(input.finalAcceptedSequence) &&
    Number.isInteger(input.submittedMaxSequence) &&
    input.submittedMaxSequence < input.finalAcceptedSequence
  ) {
    return result(EvidenceClass.TRAILING_OMISSION_DETECTED)
  }

  if (
    Number.isInteger(input.finalMessageCount) &&
    Number.isInteger(input.submittedMessageCount) &&
    input.finalMessageCount === input.submittedMessageCount &&
    input.finalAcceptedSequence === input.submittedMaxSequence
  ) {
    return result(EvidenceClass.ACCEPTED_COMPLETE)
  }

  return result(EvidenceClass.ACCEPTED_EXCERPT)
}

export class HistoricalVerificationKeyRegistry {
  constructor(initial = {}) {
    this.keys = new Map(Object.entries(initial))
  }

  add(keyId, publicKey) {
    this.keys.set(keyId, publicKey)
  }

  get(keyId) {
    return this.keys.get(keyId) ?? null
  }

  has(keyId) {
    return this.keys.has(keyId)
  }

  remove(keyId) {
    this.keys.delete(keyId)
  }

  snapshot() {
    return Object.fromEntries(this.keys)
  }
}

function hashLeaf(value) {
  return createHash('sha256')
    .update(Buffer.from([0]))
    .update(String(value), 'utf8')
    .digest('hex')
}

function hashNode(leftHex, rightHex) {
  return createHash('sha256')
    .update(Buffer.from([1]))
    .update(Buffer.from(leftHex, 'hex'))
    .update(Buffer.from(rightHex, 'hex'))
    .digest('hex')
}

function appendFrontier(frontier, digest) {
  const next = [...frontier]
  let carry = hashLeaf(digest)
  let level = 0

  while (next[level]) {
    carry = hashNode(next[level], carry)
    next[level] = null
    level += 1
  }
  next[level] = carry
  return next
}

function rootFromFrontier(frontier) {
  let root = null
  for (let level = 0; level < frontier.length; level += 1) {
    const hash = frontier[level]
    if (!hash) continue
    root = root === null ? hash : hashNode(hash, root)
  }
  return root
}

function rootFromDigests(digests) {
  let frontier = []
  for (const digest of digests) frontier = appendFrontier(frontier, digest)
  return rootFromFrontier(frontier)
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

export class WitnessOperationalAuthority {
  constructor({
    serverKeyId,
    modeBPersistence = 'final-only',
    endpointReuseDetection = false,
    durableState = null
  }) {
    this.serverKeyId = serverKeyId
    this.modeBPersistence = modeBPersistence
    this.endpointReuseDetection = endpointReuseDetection
    this.sessions = new Map()

    this.historicalKeys = new HistoricalVerificationKeyRegistry(durableState?.historicalKeys ?? {})
    this.finalCommitments = clone(durableState?.finalCommitments ?? {})
    this.modeBAccumulators = clone(durableState?.modeBAccumulators ?? {})
    this.endpointFingerprints = clone(durableState?.endpointFingerprints ?? {})
  }

  startSession({sessionId, mode}) {
    if (this.sessions.has(sessionId)) throw new Error('session_already_active')
    const session = {
      sessionId,
      mode,
      nextSequence: 1,
      receiptsByDigest: new Map(),
      acceptedDigests: [],
      frontier: []
    }
    this.sessions.set(sessionId, session)

    if (mode === 'B' && this.modeBPersistence === 'evolving-accumulator') {
      this.persistAccumulator(session)
    }
    return {sessionId, mode}
  }

  hasActiveSession(sessionId) {
    return this.sessions.has(sessionId)
  }

  acceptMessage(sessionId, envelopeDigest) {
    const session = this.sessions.get(sessionId)
    if (!session) throw new Error('session_state_unavailable')

    const existing = session.receiptsByDigest.get(envelopeDigest)
    if (existing) return {...existing, duplicate: true}

    const receipt = {
      witnessSessionId: sessionId,
      acceptanceSequence: session.nextSequence,
      envelopeDigest,
      serverKeyId: this.serverKeyId,
      duplicate: false
    }
    session.receiptsByDigest.set(envelopeDigest, receipt)
    session.acceptedDigests.push(envelopeDigest)
    session.frontier = appendFrontier(session.frontier, envelopeDigest)
    session.nextSequence += 1

    if (session.mode === 'B' && this.modeBPersistence === 'evolving-accumulator') {
      this.persistAccumulator(session)
    }
    return {...receipt}
  }

  lookupReceipt(sessionId, envelopeDigest) {
    const session = this.sessions.get(sessionId)
    if (!session) return null
    const receipt = session.receiptsByDigest.get(envelopeDigest)
    return receipt ? {...receipt} : null
  }

  finalizeModeB(sessionId) {
    const session = this.sessions.get(sessionId)
    if (!session || session.mode !== 'B') throw new Error('session_state_unavailable')

    const final = {
      witnessSessionId: sessionId,
      finalAcceptedSequence: session.nextSequence - 1,
      messageCount: session.acceptedDigests.length,
      root: rootFromDigests(session.acceptedDigests),
      version: 'safety-03-mode-b-v1',
      serverKeyId: this.serverKeyId
    }
    this.finalCommitments[sessionId] = final
    delete this.modeBAccumulators[sessionId]
    return clone(final)
  }

  persistAccumulator(session) {
    this.modeBAccumulators[session.sessionId] = {
      witnessSessionId: session.sessionId,
      acceptedSequence: session.nextSequence - 1,
      messageCount: session.acceptedDigests.length,
      frontier: [...session.frontier],
      serverKeyId: this.serverKeyId
    }
  }

  registerEndpointFingerprint(sessionId, fingerprint) {
    if (!this.endpointReuseDetection) return
    const existing = this.endpointFingerprints[fingerprint]
    if (existing && existing !== sessionId) throw new Error('endpoint_key_reuse_detected')
    this.endpointFingerprints[fingerprint] = sessionId
  }

  durableSnapshot() {
    return clone({
      historicalKeys: this.historicalKeys.snapshot(),
      finalCommitments: this.finalCommitments,
      modeBAccumulators: this.modeBAccumulators,
      endpointFingerprints: this.endpointFingerprints
    })
  }
}

export function restartAuthority(authority) {
  return new WitnessOperationalAuthority({
    serverKeyId: authority.serverKeyId,
    modeBPersistence: authority.modeBPersistence,
    endpointReuseDetection: authority.endpointReuseDetection,
    durableState: authority.durableSnapshot()
  })
}

export function modeBFinalState(authority, sessionId) {
  const final = authority.finalCommitments[sessionId]
  if (final) return {status: 'FINALIZED', ...clone(final)}

  const accumulator = authority.modeBAccumulators[sessionId]
  if (accumulator) {
    return {
      status: 'RECOVERABLE_FROM_EVOLVING_ACCUMULATOR',
      witnessSessionId: sessionId,
      finalAcceptedSequence: accumulator.acceptedSequence,
      messageCount: accumulator.messageCount,
      root: rootFromFrontier(accumulator.frontier),
      serverKeyId: accumulator.serverKeyId
    }
  }

  return {status: 'FINALIZATION_INCOMPLETE', witnessSessionId: sessionId}
}
