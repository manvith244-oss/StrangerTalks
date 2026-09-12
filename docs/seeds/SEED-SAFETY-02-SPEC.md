# SEED-SAFETY-02 — Adversarial Witness Envelope Prototype

Status: isolated research seed. Never production authority.

Base: canonical `main` at `0a19605293ef5374a2d832e05eaa40a4572942e2`.

## Frozen scope

Prototype only client-attested witnessing. Do not modify canonical `main`, production, production Supabase, or current production message flows. Do not merge automatically. Do not weaken existing tests.

The maximum safe claim is:

> A recipient can later present cryptographically verifiable evidence that an admitted StrangerTalks endpoint signed these exact bytes in this session.

The prototype MUST NOT infer human authorship, moral truth, aggressor status, narrative completeness without evidence, or uncompromised-device status.

## Mechanism under test

- Fresh WebCrypto Ed25519 endpoint key pairs per conversation.
- RFC 8949 deterministic CBOR encoding.
- RFC 9052 COSE_Sign1 structure using RFC 9053 EdDSA (`alg = -8`).
- Server-signed ephemeral session membership certificate.
- Signed message envelopes with per-endpoint sender sequence and previous-envelope digest.
- Server-signed acceptance receipts containing digest/order metadata only, never message plaintext.
- AES-GCM encrypted client evidence vault backed by IndexedDB-compatible storage.
- Later report verification separated from safety adjudication.

## Competing modes

### Mode A — PRIVACY-MAXIMAL

No retained transcript-completeness commitment beyond the reporting client's evidence bundle and historical server verification keys.

### Mode B — COMPLETENESS-ENHANCED

Retain only final-session metadata:

- witness session identifier;
- final accepted sequence;
- accepted message count;
- final ordered Merkle root over accepted receipt/message-digest leaves;
- server signing key/version metadata.

No plaintext is retained by the Mode B commitment store.

## Mandatory hostile tests

Fabricated peer message; one-byte alteration; replay; sender reorder; cross-sender order; missing middle message; trailing omission; forged sequence; stale certificate; expired certificate; server signing-key rotation; stolen endpoint key; wiped IndexedDB; private/incognito lifetime; multi-device participation; weeks-later report; malformed CBOR/COSE; cross-session key reuse; authentic but selectively misleading context; same-origin XSS modeled as endpoint compromise.

## Explicit non-goals

- No automatic punishment or moderation verdicts.
- No production endpoint or schema changes.
- No E2EE/offline-delivery redesign.
- No attempt to make XSS safe after compromise.
- No claim that endpoint signatures identify the physical human typist.
