# SEED-SAFETY-02 Adversarial Witness Envelope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an isolated executable prototype that tests whether endpoint-signed, server-certified abuse evidence remains verifiable without a central ordinary-plaintext transcript, and quantify Mode A versus Mode B completeness/privacy trade-offs.

**Architecture:** A standalone Node 22 seed under `seed/safety_02/` uses browser-compatible WebCrypto Ed25519/AES-GCM, deterministic CBOR via `cborg`, an RFC 9052 COSE_Sign1 encoding, server-signed session certificates and acceptance receipts, per-endpoint hash linkage, an RFC 6962-style ordered Merkle commitment for Mode B, IndexedDB-backed encrypted evidence storage, and a verifier that returns cryptographic authenticity separately from safety adjudication.

**Tech Stack:** Node 22 WebCrypto, `cborg@6.1.2`, `fake-indexeddb@6.2.5`, Node `node:test`, GitHub Actions.

**Spec:** `docs/seeds/SEED-SAFETY-02-SPEC.md`

## Global Constraints

- Canonical `main` is read-only.
- No production or production Supabase mutation.
- No integration into current ConversationChannel/ConversationServer flows.
- No weakening existing tests.
- No automatic punishment logic.
- Successful same-origin XSS and stolen endpoint-key capability are modeled as endpoint compromise, not as preventable by signatures.
- Safe verifier claim is endpoint-byte provenance only.

---

### Task 1: RED hostile-test harness and isolated CI

**Files:**
- Create: `seed/safety_02/package.json`
- Create: `seed/safety_02/test/witness_protocol.test.mjs`
- Create: `.github/workflows/seed-safety-02.yml`

**Interfaces:**
- Consumes: none.
- Produces: executable hostile tests that initially fail because `../src/witness_protocol.mjs`, `../src/merkle.mjs`, and `../src/evidence_vault.mjs` do not exist.

- [ ] **Step 1: Add package manifest** with `cborg@6.1.2` and `fake-indexeddb@6.2.5`, and `npm test` running `node --test test/*.test.mjs`.
- [ ] **Step 2: Write mandatory hostile tests first** covering certificate issuance, peer forgery, mutation, replay, ordering, omission, key compromise/XSS, storage loss, multiple devices, key rotation, malformed COSE, key reuse, weeks-later verification, and authenticity/adjudication separation.
- [ ] **Step 3: Add isolated workflow** triggered only for the seed branch and workflow dispatch, using Node 22, `npm ci`, and `npm test` from `seed/safety_02`.
- [ ] **Step 4: Push tests without implementation and verify RED**. Expected result: workflow/test failure because implementation modules are absent.

### Task 2: GREEN COSE/WebCrypto witness core

**Files:**
- Create: `seed/safety_02/src/witness_protocol.mjs`

**Interfaces:**
- Produces: `generateEndpointKey`, `createServerAuthority`, `issueSessionCertificate`, `rotateSessionCertificate`, `signMessageEnvelope`, `acceptMessage`, `verifyEvidenceReport`, `decodeCosePayload`, `digestBytes`, `detectCrossSessionKeyReuse`.

- [ ] **Step 1: Implement deterministic CBOR helpers** using `encode(value, rfc8949EncodeOptions)` and strict decode.
- [ ] **Step 2: Implement untagged RFC 9052 COSE_Sign1** as `[protected_bstr, unprotected_map, payload_bstr, signature_bstr]`, with protected `{1: -8, 4: kid}` and Sig_structure `["Signature1", protected_bstr, empty_bstr, payload_bstr]`.
- [ ] **Step 3: Generate fresh non-extractable Ed25519 private keys** through WebCrypto while exporting only public raw bytes.
- [ ] **Step 4: Implement server-certified membership** binding session id, certificate epoch, endpoint ids, participant slots, public keys, issue/expiry times, and server key id.
- [ ] **Step 5: Implement signed message envelopes** binding session/certificate identity, endpoint id, endpoint-local sender sequence, previous sender digest, client message id, type and content.
- [ ] **Step 6: Implement server acceptance receipts** binding session id, certificate fingerprint, monotonically increasing global acceptance sequence, signed-envelope digest, endpoint id and server acceptance time, with no plaintext.
- [ ] **Step 7: Enforce acceptance invariants**: active certificate only, certificate validity at acceptance, endpoint membership, sender-sequence continuity, previous-digest continuity, unique client message id/digest, and replay rejection.
- [ ] **Step 8: Implement historical server-key verification** by `kid` so reports remain verifiable after rotation if old public keys remain in the verifier keyring.
- [ ] **Step 9: Run tests** and fix only protocol-core failures.

### Task 3: GREEN Mode B ordered commitment

**Files:**
- Create: `seed/safety_02/src/merkle.mjs`

**Interfaces:**
- Produces: `merkleRoot`, `inclusionProof`, `verifyInclusionProof`, `buildFinalCommitment`.

- [ ] **Step 1: Implement RFC 6962-style SHA-256 tree hashing**: empty root `SHA256("")`, leaf `SHA256(0x00 || leaf)`, node `SHA256(0x01 || left || right)`.
- [ ] **Step 2: Commit ordered acceptance leaves** encoded from global sequence and signed-envelope digest.
- [ ] **Step 3: Implement inclusion proof generation/verification** for selective disclosure.
- [ ] **Step 4: Build server-signed final-session commitment** containing session id, final accepted sequence, accepted count, root, algorithm/version, and server key id; no content or participant ids.
- [ ] **Step 5: Verify Mode B detects trailing omission** while Mode A returns completeness `unprovable` rather than falsely claiming completeness.

### Task 4: GREEN encrypted local evidence vault

**Files:**
- Create: `seed/safety_02/src/evidence_vault.mjs`

**Interfaces:**
- Produces: `EvidenceVault.open`, `putEvidence`, `getEvidence`, `listEvidence`, `destroyDatabase`, `close`.

- [ ] **Step 1: Use IndexedDB-compatible storage** with database/object-store names local to the seed only.
- [ ] **Step 2: Generate/store a non-extractable AES-GCM CryptoKey** and encrypt serialized evidence records before database storage; store IV+ciphertext only for message evidence.
- [ ] **Step 3: Prove wipe behavior** by deleting the IndexedDB database and showing later evidence recovery fails.
- [ ] **Step 4: Model private/incognito behavior honestly** by destroying the seed database/key at private-session end and asserting later report generation is impossible.
- [ ] **Step 5: Run vault and full hostile tests.**

### Task 5: Final report and exact-SHA verification

**Files:**
- Create: `docs/seeds/SEED-SAFETY-02-REPORT.md`

**Interfaces:**
- Consumes: actual GitHub Actions results and implemented behavior.
- Produces: Evolution Council evidence report.

- [ ] **Step 1: Record exact branch/base/head SHAs and dependency versions.**
- [ ] **Step 2: Record each hostile test as proven, disproven, or boundary/failure.**
- [ ] **Step 3: Compare Mode A versus Mode B guarantees and retained metadata.**
- [ ] **Step 4: State XSS/key-theft collapse explicitly and keep adjudication `NOT_DETERMINED`.**
- [ ] **Step 5: Quantify relationship-graph capability from Mode B metadata and distinguish it from canonical Conversation metadata.**
- [ ] **Step 6: Re-run isolated seed CI on the exact final SHA and record status; verify canonical `main` SHA did not move because of this seed.**
