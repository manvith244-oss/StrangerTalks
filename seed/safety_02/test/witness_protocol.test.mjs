import assert from "node:assert/strict"
import test from "node:test"
import "fake-indexeddb/auto"
import {decode, encode, rfc8949EncodeOptions} from "cborg"

import {
  createAcceptanceAuthority,
  createCoseSign1,
  createServerAuthority,
  createSessionAuthority,
  decodeCosePayload,
  digestBytes,
  generateEndpointKey,
  signMessageEnvelope,
  verifyEvidenceReport
} from "../src/witness_protocol.mjs"
import {buildFinalCommitment} from "../src/merkle.mjs"
import {EvidenceVault} from "../src/evidence_vault.mjs"

const ISSUED_AT = 1_800_000_000_000
const HOUR = 60 * 60 * 1000
const DAY = 24 * HOUR

function bytesEqual(a, b) {
  return Buffer.from(a).equals(Buffer.from(b))
}

function mutateCosePayload(coseBytes, mutate) {
  const cose = decode(coseBytes, {useMaps: true})
  const payload = decode(cose[2], {useMaps: false})
  const changed = mutate(structuredClone(payload))
  cose[2] = encode(changed, rfc8949EncodeOptions)
  return encode(cose, rfc8949EncodeOptions)
}

async function fixture({multiDevice = false, expiresAt = ISSUED_AT + HOUR} = {}) {
  const server = await createServerAuthority({kid: "server-k1"})
  const sessions = createSessionAuthority({serverAuthority: server, enforceKeyFreshness: true})
  const a1 = await generateEndpointKey({endpointId: "a-1", participantSlot: "A"})
  const b1 = await generateEndpointKey({endpointId: "b-1", participantSlot: "B"})
  const endpoints = [a1, b1]
  let a2 = null
  if (multiDevice) {
    a2 = await generateEndpointKey({endpointId: "a-2", participantSlot: "A"})
    endpoints.push(a2)
  }
  const certificate = await sessions.issueSessionCertificate({
    sessionId: `session-${crypto.randomUUID()}`,
    epoch: 1,
    endpoints,
    issuedAt: ISSUED_AT,
    expiresAt
  })
  const acceptance = createAcceptanceAuthority({serverAuthority: server, sessionAuthority: sessions})
  return {server, sessions, acceptance, certificate, a1, a2, b1}
}

async function signedAccepted({acceptance, certificate, endpoint, sequence, previousDigest = null, content, acceptedAt = ISSUED_AT + 1_000, clientMessageId = crypto.randomUUID()}) {
  const messageEnvelope = await signMessageEnvelope({
    endpoint,
    sessionCertificate: certificate,
    senderSequence: sequence,
    previousSenderDigest: previousDigest,
    clientMessageId,
    messageType: "text",
    content
  })
  const accepted = await acceptance.acceptMessage({sessionCertificate: certificate, messageEnvelope, acceptedAt})
  return {...accepted, messageEnvelope}
}

test("authentic endpoint message verifies while safety adjudication remains NOT_DETERMINED", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "hello"})
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [{messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt}],
    claimedComplete: false,
    reportCreatedAt: ISSUED_AT + 7 * DAY
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.equal(report.safety_adjudication, "NOT_DETERMINED")
  assert.equal(report.messages[0].endpoint_id, "b-1")
  assert.equal(report.messages[0].participant_slot, "B")
  assert.equal(report.messages[0].content, "hello")
  assert.equal("aggressor" in report, false)
})

test("malicious reporter cannot fabricate a peer message with the reporter key", async () => {
  const fx = await fixture()
  const certPayload = decodeCosePayload(fx.certificate)
  const forgedPayload = {
    kind: "witness_message",
    version: 1,
    session_id: certPayload.session_id,
    certificate_digest: await digestBytes(fx.certificate),
    endpoint_id: "b-1",
    sender_sequence: 1,
    previous_sender_digest: null,
    client_message_id: crypto.randomUUID(),
    message_type: "text",
    content: "forged as B"
  }
  const forged = await createCoseSign1({payload: forgedPayload, privateKey: fx.a1.privateKey, kid: "b-1"})
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: forged, acceptedAt: ISSUED_AT + 1_000}),
    /invalid_endpoint_signature/
  )
})

test("one-byte-equivalent content alteration invalidates the original signature", async () => {
  const fx = await fixture()
  const envelope = await signMessageEnvelope({
    endpoint: fx.b1,
    sessionCertificate: fx.certificate,
    senderSequence: 1,
    previousSenderDigest: null,
    clientMessageId: crypto.randomUUID(),
    content: "hello"
  })
  const tampered = mutateCosePayload(envelope, payload => ({...payload, content: "jello"}))
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: tampered, acceptedAt: ISSUED_AT + 1_000}),
    /invalid_endpoint_signature/
  )
})

test("acceptance authority rejects replay of an already accepted signed envelope", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "one"})
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: m1.messageEnvelope, acceptedAt: ISSUED_AT + 2_000}),
    /message_replay/
  )
})

test("sender sequencing and previous-envelope linkage reject forged gaps and reordering", async () => {
  const fx = await fixture()
  const seq2 = await signMessageEnvelope({
    endpoint: fx.b1,
    sessionCertificate: fx.certificate,
    senderSequence: 2,
    previousSenderDigest: new Uint8Array(32),
    clientMessageId: crypto.randomUUID(),
    content: "two first"
  })
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: seq2, acceptedAt: ISSUED_AT + 1_000}),
    /sender_sequence_gap/
  )
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "one"})
  const seq3 = await signMessageEnvelope({
    endpoint: fx.b1,
    sessionCertificate: fx.certificate,
    senderSequence: 3,
    previousSenderDigest: m1.messageDigest,
    clientMessageId: crypto.randomUUID(),
    content: "three"
  })
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: seq3, acceptedAt: ISSUED_AT + 2_000}),
    /sender_sequence_gap/
  )
})

test("server receipts establish cross-sender acceptance order and detect submitted reordering", async () => {
  const fx = await fixture()
  const a = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "A first", acceptedAt: ISSUED_AT + 1_000})
  const b = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "B second", acceptedAt: ISSUED_AT + 2_000})
  assert.equal(a.globalSequence, 1)
  assert.equal(b.globalSequence, 2)
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [
      {messageEnvelope: b.messageEnvelope, acceptanceReceipt: b.acceptanceReceipt},
      {messageEnvelope: a.messageEnvelope, acceptanceReceipt: a.acceptanceReceipt}
    ]
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.ok(report.warnings.includes("submitted_cross_sender_reorder"))
})

test("missing middle message is signaled without turning authenticity into an adjudication", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "one"})
  const m2 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 2, previousDigest: m1.messageDigest, content: "two", acceptedAt: ISSUED_AT + 2_000})
  const m3 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 3, previousDigest: m2.messageDigest, content: "three", acceptedAt: ISSUED_AT + 3_000})
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [
      {messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt},
      {messageEnvelope: m3.messageEnvelope, acceptanceReceipt: m3.acceptanceReceipt}
    ]
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.ok(report.warnings.includes("sender_sequence_gap"))
  assert.ok(report.warnings.includes("global_sequence_gap"))
  assert.equal(report.safety_adjudication, "NOT_DETERMINED")
})

test("Mode A cannot prove a submitted suffix is the true end even when reporter claims completeness", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "one"})
  const m2 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "two", acceptedAt: ISSUED_AT + 2_000})
  await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 2, previousDigest: m1.messageDigest, content: "secret trailing", acceptedAt: ISSUED_AT + 3_000})
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [
      {messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt},
      {messageEnvelope: m2.messageEnvelope, acceptanceReceipt: m2.acceptanceReceipt}
    ],
    claimedComplete: true
  })
  assert.equal(report.context_completeness, "UNPROVABLE_IN_MODE_A")
  assert.ok(report.warnings.includes("trailing_omission_cannot_be_ruled_out"))
})

test("Mode B final commitment detects trailing omission and proves disclosed-leaf membership", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "one"})
  const m2 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "two", acceptedAt: ISSUED_AT + 2_000})
  const m3 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 2, previousDigest: m1.messageDigest, content: "three", acceptedAt: ISSUED_AT + 3_000})
  const commitment = await buildFinalCommitment({
    serverAuthority: fx.server,
    sessionId: decodeCosePayload(fx.certificate).session_id,
    acceptedRecords: fx.acceptance.acceptedRecords(decodeCosePayload(fx.certificate).session_id),
    finalizedAt: ISSUED_AT + 4_000
  })
  const report = await verifyEvidenceReport({
    mode: "B",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [
      {messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt, inclusionProof: commitment.proofFor(1)},
      {messageEnvelope: m2.messageEnvelope, acceptanceReceipt: m2.acceptanceReceipt, inclusionProof: commitment.proofFor(2)}
    ],
    finalCommitment: commitment.cose,
    claimedComplete: true
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.equal(report.context_completeness, "INCOMPLETE_AGAINST_FINAL_COMMITMENT")
  assert.ok(report.warnings.includes("trailing_omission_detected"))
  assert.equal(report.final_accepted_sequence, 3)
  assert.equal(report.final_message_count, 3)
  assert.ok(bytesEqual((decodeCosePayload(commitment.cose)).merkle_root, commitment.root))
  assert.equal(m3.globalSequence, 3)
})

test("Mode B supports selective disclosure without revealing omitted plaintext", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "private one"})
  const m2 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "reported two", acceptedAt: ISSUED_AT + 2_000})
  await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 2, previousDigest: m1.messageDigest, content: "private three", acceptedAt: ISSUED_AT + 3_000})
  const sessionId = decodeCosePayload(fx.certificate).session_id
  const commitment = await buildFinalCommitment({serverAuthority: fx.server, sessionId, acceptedRecords: fx.acceptance.acceptedRecords(sessionId), finalizedAt: ISSUED_AT + 4_000})
  const report = await verifyEvidenceReport({
    mode: "B",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [{messageEnvelope: m2.messageEnvelope, acceptanceReceipt: m2.acceptanceReceipt, inclusionProof: commitment.proofFor(2)}],
    finalCommitment: commitment.cose,
    claimedComplete: false
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.equal(report.context_completeness, "SELECTIVE_AUTHENTIC_EXCERPT")
  assert.deepEqual(report.messages.map(m => m.content), ["reported two"])
  assert.equal(report.final_message_count, 3)
})

test("stale certificate is rejected after session certificate rotation", async () => {
  const fx = await fixture()
  const rotated = await fx.sessions.rotateSessionCertificate({
    sessionId: decodeCosePayload(fx.certificate).session_id,
    endpoints: [fx.a1, fx.b1],
    issuedAt: ISSUED_AT + 5_000,
    expiresAt: ISSUED_AT + HOUR
  })
  assert.equal(decodeCosePayload(rotated).epoch, 2)
  const staleMessage = await signMessageEnvelope({endpoint: fx.a1, sessionCertificate: fx.certificate, senderSequence: 1, clientMessageId: crypto.randomUUID(), content: "stale"})
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: staleMessage, acceptedAt: ISSUED_AT + 6_000}),
    /stale_certificate/
  )
})

test("expired certificate blocks new acceptance but does not invalidate evidence accepted while certificate was valid", async () => {
  const fx = await fixture({expiresAt: ISSUED_AT + 2_000})
  const valid = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "accepted before expiry", acceptedAt: ISSUED_AT + 1_000})
  const late = await signMessageEnvelope({endpoint: fx.a1, sessionCertificate: fx.certificate, senderSequence: 1, clientMessageId: crypto.randomUUID(), content: "too late"})
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: late, acceptedAt: ISSUED_AT + 3_000}),
    /certificate_expired/
  )
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [{messageEnvelope: valid.messageEnvelope, acceptanceReceipt: valid.acceptanceReceipt}],
    reportCreatedAt: ISSUED_AT + 30 * DAY
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
})

test("server signing-key rotation preserves old evidence only while historical verification key remains available", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "before rotation"})
  await fx.server.rotate("server-k2")
  const fullKeyring = fx.server.verificationKeys()
  const ok = await verifyEvidenceReport({mode: "A", serverVerificationKeys: fullKeyring, sessionCertificate: fx.certificate, evidence: [{messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt}]})
  assert.equal(ok.cryptographic_authenticity, "VERIFIED")
  const withoutOld = new Map(fullKeyring)
  withoutOld.delete("server-k1")
  const failed = await verifyEvidenceReport({mode: "A", serverVerificationKeys: withoutOld, sessionCertificate: fx.certificate, evidence: [{messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt}]})
  assert.equal(failed.cryptographic_authenticity, "INVALID")
  assert.ok(failed.errors.includes("unknown_server_key"))
})

test("stolen endpoint signing capability / successful same-origin XSS produces valid endpoint evidence and cannot be detected by the verifier", async () => {
  const fx = await fixture()
  const malicious = await signMessageEnvelope({
    endpoint: fx.b1,
    sessionCertificate: fx.certificate,
    senderSequence: 1,
    clientMessageId: crypto.randomUUID(),
    content: "signed while endpoint was compromised"
  })
  const accepted = await fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: malicious, acceptedAt: ISSUED_AT + 1_000})
  const report = await verifyEvidenceReport({mode: "A", serverVerificationKeys: fx.server.verificationKeys(), sessionCertificate: fx.certificate, evidence: [{messageEnvelope: malicious, acceptanceReceipt: accepted.acceptanceReceipt}]})
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.equal(report.safety_adjudication, "NOT_DETERMINED")
  assert.ok(report.limitations.includes("endpoint_compromise_not_detectable"))
})

test("multi-device session identifies the certified endpoint without claiming a physical human identity", async () => {
  const fx = await fixture({multiDevice: true})
  const m = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a2, sequence: 1, content: "from second A device"})
  const report = await verifyEvidenceReport({mode: "A", serverVerificationKeys: fx.server.verificationKeys(), sessionCertificate: fx.certificate, evidence: [{messageEnvelope: m.messageEnvelope, acceptanceReceipt: m.acceptanceReceipt}]})
  assert.equal(report.messages[0].endpoint_id, "a-2")
  assert.equal(report.messages[0].participant_slot, "A")
  assert.equal(report.human_authorship, "NOT_PROVEN")
})

test("malformed CBOR/COSE is rejected rather than interpreted leniently", async () => {
  const fx = await fixture()
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: new Uint8Array([0xff, 0x01]), acceptedAt: ISSUED_AT + 1_000}),
    /malformed_cose/
  )
  const malformedStructure = encode({not: "COSE_Sign1"}, rfc8949EncodeOptions)
  await assert.rejects(
    () => fx.acceptance.acceptMessage({sessionCertificate: fx.certificate, messageEnvelope: malformedStructure, acceptedAt: ISSUED_AT + 1_000}),
    /malformed_cose/
  )
})

test("cross-session endpoint-key reuse is rejected by the optional freshness registry and its metadata cost is measurable", async () => {
  const server = await createServerAuthority({kid: "server-k1"})
  const sessions = createSessionAuthority({serverAuthority: server, enforceKeyFreshness: true})
  const shared = await generateEndpointKey({endpointId: "shared", participantSlot: "A"})
  const peer1 = await generateEndpointKey({endpointId: "peer-1", participantSlot: "B"})
  await sessions.issueSessionCertificate({sessionId: "s-one", epoch: 1, endpoints: [shared, peer1], issuedAt: ISSUED_AT, expiresAt: ISSUED_AT + HOUR})
  const peer2 = await generateEndpointKey({endpointId: "peer-2", participantSlot: "B"})
  await assert.rejects(
    () => sessions.issueSessionCertificate({sessionId: "s-two", epoch: 1, endpoints: [shared, peer2], issuedAt: ISSUED_AT + HOUR, expiresAt: ISSUED_AT + 2 * HOUR}),
    /endpoint_key_reuse/
  )
  assert.ok(sessions.reuseRegistrySize() >= 2)
})

test("encrypted IndexedDB evidence survives reopen but is lost when IndexedDB is wiped", async () => {
  const dbName = `seed-safety-02-${crypto.randomUUID()}`
  const vault = await EvidenceVault.open({indexedDB, dbName})
  await vault.putEvidence("reportable", {content: "plaintext evidence", bytes: new Uint8Array([1, 2, 3])})
  const raw = await vault.debugRawRecord("reportable")
  assert.equal(JSON.stringify(raw).includes("plaintext evidence"), false)
  await vault.close()
  const reopened = await EvidenceVault.open({indexedDB, dbName})
  assert.equal((await reopened.getEvidence("reportable")).content, "plaintext evidence")
  await reopened.destroyDatabase()
  const afterWipe = await EvidenceVault.open({indexedDB, dbName})
  assert.equal(await afterWipe.getEvidence("reportable"), null)
  await afterWipe.destroyDatabase()
})

test("private/incognito-mode model destroys evidence on session close", async () => {
  const dbName = `seed-safety-02-private-${crypto.randomUUID()}`
  const vault = await EvidenceVault.open({indexedDB, dbName, privateMode: true})
  await vault.putEvidence("e1", {content: "temporary"})
  await vault.close()
  const reopened = await EvidenceVault.open({indexedDB, dbName})
  assert.equal(await reopened.getEvidence("e1"), null)
  await reopened.destroyDatabase()
})

test("client evidence can verify weeks later only if local vault and historical server key survive", async () => {
  const fx = await fixture()
  const m1 = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "retain me"})
  const dbName = `seed-safety-02-weeks-${crypto.randomUUID()}`
  const vault = await EvidenceVault.open({indexedDB, dbName})
  await vault.putEvidence("bundle", {sessionCertificate: fx.certificate, messageEnvelope: m1.messageEnvelope, acceptanceReceipt: m1.acceptanceReceipt})
  await vault.close()
  const weeksLater = await EvidenceVault.open({indexedDB, dbName})
  const bundle = await weeksLater.getEvidence("bundle")
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: bundle.sessionCertificate,
    evidence: [{messageEnvelope: bundle.messageEnvelope, acceptanceReceipt: bundle.acceptanceReceipt}],
    reportCreatedAt: ISSUED_AT + 21 * DAY
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  await weeksLater.destroyDatabase()
})

test("authentic selectively misleading context remains cryptographically authentic but never becomes an aggressor verdict", async () => {
  const fx = await fixture()
  const a = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "Quote the villain line from the script"})
  const b = await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.b1, sequence: 1, content: "I will hurt you", acceptedAt: ISSUED_AT + 2_000})
  const report = await verifyEvidenceReport({
    mode: "A",
    serverVerificationKeys: fx.server.verificationKeys(),
    sessionCertificate: fx.certificate,
    evidence: [{messageEnvelope: b.messageEnvelope, acceptanceReceipt: b.acceptanceReceipt}],
    claimedComplete: false
  })
  assert.equal(report.cryptographic_authenticity, "VERIFIED")
  assert.equal(report.safety_adjudication, "NOT_DETERMINED")
  assert.equal(report.context_completeness, "SELECTIVE_AUTHENTIC_EXCERPT")
  assert.equal(report.messages[0].content, "I will hurt you")
  assert.equal(report.messages.some(m => m.content === decodeCosePayload(a.messageEnvelope).content), false)
})

test("Mode B retained commitment contains no message plaintext or endpoint participant mapping", async () => {
  const fx = await fixture()
  await signedAccepted({acceptance: fx.acceptance, certificate: fx.certificate, endpoint: fx.a1, sequence: 1, content: "sensitive text"})
  const sessionId = decodeCosePayload(fx.certificate).session_id
  const commitment = await buildFinalCommitment({serverAuthority: fx.server, sessionId, acceptedRecords: fx.acceptance.acceptedRecords(sessionId), finalizedAt: ISSUED_AT + 2_000})
  const payload = decodeCosePayload(commitment.cose)
  assert.deepEqual(Object.keys(payload).sort(), ["accepted_count", "final_accepted_sequence", "finalized_at", "kind", "merkle_algorithm", "merkle_root", "session_id", "version"].sort())
  assert.equal(JSON.stringify(payload).includes("sensitive text"), false)
  assert.equal(JSON.stringify(payload).includes("participant_slot"), false)
  assert.equal(JSON.stringify(payload).includes("endpoint_id"), false)
})
