import assert from 'node:assert/strict'
import test from 'node:test'

import {
  EvidenceClass,
  HistoricalVerificationKeyRegistry,
  WitnessOperationalAuthority,
  classifyEvidence,
  modeBFinalState,
  restartAuthority
} from '../src/operational_model.mjs'

const SAFETY = 'NOT_DETERMINED'

function expectClass(result, classification) {
  assert.equal(result.classification, classification)
  assert.equal(result.safetyAdjudication, SAFETY)
}

test('signed message without server acceptance receipt degrades to endpoint-authenticity only', () => {
  expectClass(classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: false,
    mode: 'A'
  }), EvidenceClass.ENDPOINT_AUTHENTICITY_ONLY)
})

test('delayed valid receipt upgrades evidence but never creates a Safety verdict', () => {
  const before = classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: false,
    mode: 'A'
  })
  const after = classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: true,
    acceptanceReceiptValid: true,
    mode: 'A'
  })
  expectClass(before, EvidenceClass.ENDPOINT_AUTHENTICITY_ONLY)
  expectClass(after, EvidenceClass.ACCEPTED_EXCERPT)
})

test('missing historical server verification key degrades explicitly instead of returning generic unverified', () => {
  expectClass(classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: false,
    acceptanceReceiptPresent: true,
    acceptanceReceiptValid: true,
    mode: 'A'
  }), EvidenceClass.HISTORICAL_SERVER_KEY_UNAVAILABLE)
})

test('wiped local evidence is distinguished from cryptographic invalidity', () => {
  expectClass(classifyEvidence({localEvidencePresent: false}), EvidenceClass.LOCAL_EVIDENCE_UNAVAILABLE)
})

test('invalid endpoint signature is distinguished from missing receipt', () => {
  expectClass(classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: false,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: false
  }), EvidenceClass.INVALID_ENDPOINT_SIGNATURE)
})

test('Mode B without a final commitment is classified as incomplete finalization', () => {
  expectClass(classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: true,
    acceptanceReceiptValid: true,
    mode: 'B',
    finalCommitmentPresent: false
  }), EvidenceClass.FINALIZATION_INCOMPLETE)
})

test('Mode B final commitment detects trailing omission without adjudicating blame', () => {
  expectClass(classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: true,
    acceptanceReceiptValid: true,
    mode: 'B',
    finalCommitmentPresent: true,
    finalCommitmentValid: true,
    finalAcceptedSequence: 7,
    submittedMaxSequence: 5,
    finalMessageCount: 7,
    submittedMessageCount: 5
  }), EvidenceClass.TRAILING_OMISSION_DETECTED)
})

test('Mode B complete evidence can be classified complete while Safety remains undetermined', () => {
  expectClass(classifyEvidence({
    localEvidencePresent: true,
    endpointSignatureValid: true,
    historicalServerKeyAvailable: true,
    acceptanceReceiptPresent: true,
    acceptanceReceiptValid: true,
    mode: 'B',
    finalCommitmentPresent: true,
    finalCommitmentValid: true,
    finalAcceptedSequence: 3,
    submittedMaxSequence: 3,
    finalMessageCount: 3,
    submittedMessageCount: 3
  }), EvidenceClass.ACCEPTED_COMPLETE)
})

test('duplicate message retry during a live session returns the original receipt sequence', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1'})
  authority.startSession({sessionId: 'witness-random-1', mode: 'A'})
  const first = authority.acceptMessage('witness-random-1', 'digest-1')
  const duplicate = authority.acceptMessage('witness-random-1', 'digest-1')
  assert.equal(first.acceptanceSequence, 1)
  assert.equal(duplicate.acceptanceSequence, 1)
  assert.equal(duplicate.duplicate, true)
})

test('network loss after server acceptance can recover a receipt only while live acceptance state still exists', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1'})
  authority.startSession({sessionId: 'witness-random-2', mode: 'A'})
  authority.acceptMessage('witness-random-2', 'digest-1')
  assert.equal(authority.lookupReceipt('witness-random-2', 'digest-1').acceptanceSequence, 1)

  const restarted = restartAuthority(authority)
  assert.equal(restarted.lookupReceipt('witness-random-2', 'digest-1'), null)
  assert.equal(restarted.hasActiveSession('witness-random-2'), false)
})

test('server restart destroys ephemeral live witness session authority rather than silently continuing stale sequence state', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1'})
  authority.startSession({sessionId: 'witness-random-3', mode: 'A'})
  authority.acceptMessage('witness-random-3', 'digest-1')

  const restarted = restartAuthority(authority)
  assert.equal(restarted.hasActiveSession('witness-random-3'), false)
  assert.throws(() => restarted.acceptMessage('witness-random-3', 'digest-2'), /session_state_unavailable/)
})

test('Mode B final-only persistence cannot recover authoritative completeness after restart before finalization', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1', modeBPersistence: 'final-only'})
  authority.startSession({sessionId: 'witness-mode-b-final-only', mode: 'B'})
  authority.acceptMessage('witness-mode-b-final-only', 'digest-1')
  authority.acceptMessage('witness-mode-b-final-only', 'digest-2')

  const restarted = restartAuthority(authority)
  assert.equal(modeBFinalState(restarted, 'witness-mode-b-final-only').status, 'FINALIZATION_INCOMPLETE')
})

test('Mode B finalized commitment survives a restart once the durable final state exists', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1', modeBPersistence: 'final-only'})
  authority.startSession({sessionId: 'witness-mode-b-finalized', mode: 'B'})
  authority.acceptMessage('witness-mode-b-finalized', 'digest-1')
  authority.acceptMessage('witness-mode-b-finalized', 'digest-2')
  const committed = authority.finalizeModeB('witness-mode-b-finalized')

  const restarted = restartAuthority(authority)
  const recovered = modeBFinalState(restarted, 'witness-mode-b-finalized')
  assert.equal(recovered.status, 'FINALIZED')
  assert.equal(recovered.root, committed.root)
  assert.equal(recovered.finalAcceptedSequence, 2)
  assert.equal(recovered.messageCount, 2)
})

test('Mode B crash-resilient evolving accumulator can recover a final commitment but necessarily persists evolving session metadata', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1', modeBPersistence: 'evolving-accumulator'})
  authority.startSession({sessionId: 'witness-mode-b-evolving', mode: 'B'})
  authority.acceptMessage('witness-mode-b-evolving', 'digest-1')
  authority.acceptMessage('witness-mode-b-evolving', 'digest-2')
  const durableBeforeRestart = authority.durableSnapshot()

  assert.deepEqual(Object.keys(durableBeforeRestart.modeBAccumulators['witness-mode-b-evolving']).sort(), [
    'acceptedSequence', 'frontier', 'messageCount', 'serverKeyId', 'witnessSessionId'
  ])
  assert.equal('finalizedAt' in durableBeforeRestart.modeBAccumulators['witness-mode-b-evolving'], false)

  const restarted = restartAuthority(authority)
  const recovered = modeBFinalState(restarted, 'witness-mode-b-evolving')
  assert.equal(recovered.status, 'RECOVERABLE_FROM_EVOLVING_ACCUMULATOR')
  assert.equal(recovered.messageCount, 2)
  assert.equal(recovered.finalAcceptedSequence, 2)
})

test('Mode B finalized metadata contains no finalized_at timestamp', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1', modeBPersistence: 'final-only'})
  authority.startSession({sessionId: 'witness-mode-b-final', mode: 'B'})
  authority.acceptMessage('witness-mode-b-final', 'digest-1')
  const final = authority.finalizeModeB('witness-mode-b-final')
  assert.equal('finalizedAt' in final, false)
  assert.equal('finalized_at' in final, false)
  assert.deepEqual(Object.keys(final).sort(), [
    'finalAcceptedSequence', 'messageCount', 'root', 'serverKeyId', 'version', 'witnessSessionId'
  ])
})

test('historical public-key registry preserves old verification across server signing-key rotation', () => {
  const registry = new HistoricalVerificationKeyRegistry()
  registry.add('server-v1', 'public-key-v1')
  registry.add('server-v2', 'public-key-v2')
  assert.equal(registry.has('server-v1'), true)
  assert.equal(registry.get('server-v1'), 'public-key-v1')
  registry.remove('server-v1')
  assert.equal(registry.has('server-v1'), false)
})

test('cross-session endpoint-key reuse detection requires a persistent comparison memory and therefore creates linkability', () => {
  const authority = new WitnessOperationalAuthority({serverKeyId: 'server-v1', endpointReuseDetection: true})
  authority.registerEndpointFingerprint('session-a', 'endpoint-fingerprint-x')
  assert.throws(
    () => authority.registerEndpointFingerprint('session-b', 'endpoint-fingerprint-x'),
    /endpoint_key_reuse_detected/
  )
  const snapshot = authority.durableSnapshot()
  assert.deepEqual(snapshot.endpointFingerprints, {'endpoint-fingerprint-x': 'session-a'})
})
