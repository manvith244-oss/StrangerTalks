# SEED-SAFETY-02 REPORT — Adversarial Witness Envelope Prototype

Status: isolated research evidence for the Evolution Council. **Not production-approved. Not merged.**

## 1. Exact seed identity

- Repository: `manvith244-oss/StrangerTalks`
- Canonical base: `0a19605293ef5374a2d832e05eaa40a4572942e2`
- Seed branch: `seed/safety-02-adversarial-witness-envelope-2026-09-12`
- Prototype/tested head: `00ec8e68d71bf41e070c068360c033187ebd066c`
- Green GitHub Actions run: `34684315750`
- Green job: `103528504481`
- Node runtime: `v22.23.2`
- Hostile tests: **22 passed / 0 failed**
- Clean-tree proof: passed after seed dependencies were removed.

The harness could not create a local persistent git worktree because the local container had no GitHub DNS/network path. Isolation therefore used the dedicated GitHub branch plus GitHub Actions' ephemeral checkout. Canonical `main` was never written.

## 2. Prototype architecture

The prototype is deliberately detached from current production message flows under `seed/safety_02/`.

Established mechanisms used:

- WebCrypto Ed25519 fresh endpoint key pairs, generated non-extractable for the private key;
- deterministic RFC 8949 CBOR using `cborg`;
- RFC 9052 COSE_Sign1 envelope shape;
- RFC 9053 EdDSA algorithm identifier (`-8`);
- SHA-256 endpoint/message/certificate digests;
- per-endpoint monotonically increasing sender sequence plus previous-envelope digest;
- server-signed session membership certificates;
- server-signed plaintext-free acceptance receipts with global acceptance sequence;
- RFC 6962-style domain-separated ordered Merkle tree for Mode B;
- AES-GCM encrypted local evidence records in IndexedDB-compatible storage;
- verification output that separates cryptographic authenticity from safety adjudication.

The verifier's strongest positive result is intentionally narrow:

> An admitted StrangerTalks endpoint signed these exact bytes in this certified session, and the server accepted that signed envelope at this acceptance sequence.

It never returns an aggressor verdict. The prototype emits `safety_adjudication = NOT_DETERMINED` and `human_authorship = NOT_PROVEN` even for valid evidence.

## 3. TDD / tests executed

A RED run was recorded first. Run `34684058423`, job `103527815843`, failed because `src/witness_protocol.mjs` did not exist. Dependency installation and workflow setup succeeded, so the failure was the intended test-first failure.

The final exact-head run `34684315750` executed 22 hostile tests and all passed:

1. authentic endpoint evidence verifies while adjudication remains undetermined;
2. reporter cannot sign a peer message with the reporter's own key;
3. content alteration invalidates the original endpoint signature;
4. replay is rejected;
5. sender sequence gaps/reordering are rejected at acceptance;
6. server receipts establish cross-sender acceptance order and submitted reorder is signaled;
7. missing middle evidence produces sender/global gap warnings;
8. Mode A cannot prove a claimed suffix is the true conversation end;
9. Mode B detects trailing omission against the final commitment;
10. Mode B permits selective disclosure while omitted plaintext remains undisclosed;
11. stale session certificates are rejected after certificate rotation;
12. expired certificates reject new messages while previously accepted evidence remains verifiable later;
13. server signing-key rotation preserves old evidence only if historical verification keys remain available;
14. stolen endpoint signing capability / successful same-origin XSS still produces cryptographically valid endpoint evidence;
15. multi-device participation proves the certified endpoint, not the physical human;
16. malformed/non-COSE input is rejected;
17. cross-session endpoint-key reuse can be detected only by maintaining a fingerprint reuse registry, exposing a metadata/linkability cost;
18. encrypted IndexedDB evidence survives reopen and disappears after database wipe;
19. the private/incognito model destroys evidence when the private session ends;
20. weeks-later verification works only when the local evidence/key and historical server verification key survive;
21. authentic but selectively misleading context remains cryptographically authentic without becoming an aggressor verdict;
22. Mode B's final commitment contains no message plaintext, endpoint id, or participant slot.

## 4. Mode A vs Mode B

| Property | Mode A — Privacy-maximal | Mode B — Completeness-enhanced |
|---|---|---|
| Ordinary server plaintext transcript | none introduced | none introduced |
| Endpoint/message authenticity | yes | yes |
| Content alteration detection | yes | yes |
| Replay detection during acceptance | yes | yes |
| Per-sender order | yes | yes |
| Cross-sender acceptance order | yes, from signed receipts supplied by client | yes |
| Missing middle ranges | signaled by disclosed sequence gaps | signaled |
| Prove disclosed message belonged to finalized session | client artifacts only | yes, Merkle inclusion proof |
| Detect omitted trailing messages | **no** | **yes**, when a final commitment exists |
| Prove full transcript when every committed leaf is disclosed | no independent final anchor | yes against the final commitment only |
| Central retained session artifact | no transcript-completeness commitment | final commitment metadata |
| Privacy/legal surface | lower | higher |

Mode B therefore buys a real forensic guarantee: a reporter cannot present messages 1..N as the whole transcript when the server-finalized commitment says the session contained N+K accepted messages.

Mode B still does **not** prove that the omitted messages help or hurt the reporter's narrative. It only proves that the submitted evidence is incomplete relative to the committed acceptance log.

## 5. Guarantees demonstrated

The prototype demonstrated the following under the assumed uncompromised endpoint-key and server-certification boundaries:

- peer-message fabrication with the wrong private key fails;
- signed content mutation is detected;
- replay is rejected by acceptance state;
- sender-local sequence/previous-digest continuity detects forged ordering/gaps;
- server acceptance receipts provide a signed global ordering point across senders;
- server certificate expiry and certificate rotation can be enforced;
- historical evidence survives server signing-key rotation if the old **public verification key** remains available;
- Mode B can prove inclusion of selectively disclosed messages without storing their plaintext centrally;
- Mode B detects a false claim that an excerpt ending before the committed final sequence is complete;
- the verifier can remain mechanically incapable of converting authenticity into a safety verdict.

These are executable prototype results, not a formal cryptographic proof and not production-browser assurance.

## 6. Guarantees disproven / boundaries preserved

The seed confirms the negative findings from SEED-SAFETY-01 rather than repairing them away:

- **Successful same-origin XSS or stolen endpoint signing capability defeats trustworthy endpoint authorship.** The resulting signature verifies normally.
- A valid endpoint signature does not prove the physical human typed the content.
- A valid excerpt does not prove narrative completeness.
- Mode A cannot independently rule out trailing omission.
- Wiping IndexedDB destroys locally retained evidence.
- Private/incognito lifetime can destroy evidence at session close.
- Deleting/losing a historical server verification key makes old server certificates/receipts unverifiable to that verifier.
- Multi-device proof identifies a certified endpoint, not one unique human device identity.
- The cryptographic verifier cannot decide who was the aggressor.
- The seed does not make a malicious/compromised StrangerTalks certification authority safe.
- The seed does not address offline E2EE, server crash recovery, or production browser hardening.

## 7. Retained metadata

### Mode A

The post-session witness mechanism needs no retained transcript-completeness record. Long-lived verification does require historical **server public verification keys** and algorithm/version interpretation.

During an active prototype session, the acceptance authority holds volatile replay/order state: session id, next global sequence, endpoint sender sequence/digest, accepted message digests/client ids, and receipts. The seed does not claim that state is crash-durable.

A global cross-session key-reuse detector additionally requires retaining endpoint public-key fingerprints. Test 17 demonstrates that this works, but also demonstrates the privacy cost: remembering fingerprints is exactly what makes cross-session linkage possible. Therefore indefinite fingerprint retention is **not recommended** merely to police accidental key reuse.

### Mode B

The prototype final commitment retains only:

- `session_id`;
- `final_accepted_sequence`;
- `accepted_count`;
- SHA-256 ordered Merkle root;
- Merkle/protocol version information;
- server signing key id in COSE protected headers;
- `finalized_at` in the prototype.

It retains no message plaintext, endpoint id, or participant slot in the commitment payload.

`finalized_at` is **not cryptographically required for completeness**. It increases timing-correlation value. A production candidate should remove it unless another independently approved requirement justifies keeping it.

## 8. Client-storage failure behavior

The seed encrypts client evidence using AES-GCM with a non-extractable CryptoKey stored through IndexedDB-compatible structured cloning.

Observed in the Node/fake-IndexedDB experiment:

- ciphertext persisted across reopen;
- the raw evidence record did not contain message plaintext;
- deleting the database made the evidence unrecoverable;
- the modeled private/incognito close deleted both key and evidence;
- a report 21 days later verified when the local bundle/key and historical server verification key still existed.

This is **not** proof of identical behavior across Chrome, Firefox, Safari, mobile WebViews, storage eviction, browser-profile backup, or actual private-browsing implementations. A real-browser matrix is still required.

## 9. Server-key rotation behavior

Server signing-key rotation is compatible with weeks-later verification if old public verification keys remain available by `kid`.

The old private signing key is not required merely to verify old evidence. Losing the old public key, however, makes the old server certificate/receipt chain unverifiable in the prototype.

Therefore historical verification-key publication/retention becomes part of the evidence contract. It is low-sensitivity public material, but its lifecycle must be deliberately versioned and durable.

## 10. XSS / stolen-key boundary

The hostile test intentionally used the legitimate endpoint signing capability to create attacker-chosen content. The verifier returned `VERIFIED`.

That is the correct result at the cryptographic layer: endpoint compromise is outside what a signature can detect.

Therefore successful same-origin XSS, a sufficiently privileged malicious extension, or stolen/invokable endpoint key collapses the claim from "trusted user action" to only:

> this endpoint signing capability produced the signature.

No XSS-detection theater or automatic punishment was added to hide this boundary.

## 11. Legal / privacy consequences

Mode A minimizes new centrally retained witness material. A later report still deliberately transfers disclosed plaintext into Safety authority and that reported evidence then becomes a separate durable/legal surface according to whatever Safety retention policy is approved.

Mode B creates a subpoena/preservation-relevant session ledger even without plaintext. A retained commitment can establish that a particular random witness session existed, its accepted-message count, final sequence, root, key/version metadata, and—**in this prototype**—finalization time.

The Merkle root is not an ordinary transcript and does not by itself reveal the omitted plaintext. But metadata can still be revealing when joined with other systems.

## 12. Does Mode B create a meaningful relationship graph?

**By itself, with a fresh random witness `session_id` and no retained participant mapping: not a participant relationship graph.** It is a session-activity ledger.

**When joinable to current StrangerTalks Conversation/participant metadata: yes, it can materially enrich the existing relationship graph.** It can add message count, session-finalization timing, and a durable commitment to an interaction already attributable elsewhere.

Therefore Mode B does not erase the existing-system contradiction established in SEED-SAFETY-01. In the current architecture, durable Conversation metadata already carries interaction relationships. A future witness implementation must not reuse canonical Conversation ids as witness-session ids or persist an unnecessary durable join table and then claim the witness layer is unlinkable.

Even a supposedly independent random session id may become correlatable through precise timestamps/logs. Removing unnecessary timestamps and preventing durable join keys matters.

## 13. Recommendation to Evolution Council

**CLIENT-ATTESTED WITNESSING is not falsified by this prototype. The narrow endpoint-byte provenance claim survived the hostile suite.**

Mode A should remain the privacy reference design. Mode B should be treated as an explicit optional forensic trade: it gains real trailing-omission/completeness evidence, but creates additional durable session metadata and can enrich a relationship graph when joined with current Conversation records.

Do **not** advance either mode directly into production message flows.

Recommended next experiment:

1. real-browser CryptoKey/IndexedDB durability and private-browsing matrix across Chrome, Firefox and Safari;
2. remove non-essential Mode B timing metadata and prove completeness still works;
3. test server restart/crash during a session and finalization without introducing a plaintext transcript;
4. test that witness-session ids cannot be joined to durable Conversation/participant ids through application data, logs, telemetry or backups;
5. obtain independent cryptographic review of the COSE/CBOR profile before any admission discussion;
6. keep XSS/APM/crash-dump plaintext hardening as separate architecture work rather than smuggling it into this witness seed.

**Council disposition recommended: ADVANCE AS RESEARCH ONLY. Do not merge.**
