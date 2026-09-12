# SEED-SAFETY-03 REPORT — Witness Operational Boundary Lab

Status: isolated Evolution Council evidence. **Not production-approved. Not merged.**

## 1. Seed identity

- Repository: `manvith244-oss/StrangerTalks`
- Canonical base SHA: `0a19605293ef5374a2d832e05eaa40a4572942e2`
- Seed branch: `seed/safety-03-witness-operational-boundary-2026-09-12`
- Operational/browser implementation evidence head before this report: `b4f96b9d85f29edd7b222ecc5aee5fea271b6ffb`
- Known green full browser+operational run before the finalization-survival coverage was added: `34685024397`
- Playwright: `1.63.0`
- Node: `22.x`

Canonical `main` was not written. No production or Supabase mutation occurred. SEED-SAFETY-02 was not modified.

## 2. Executive verdict

CLIENT-ATTESTED WITNESSING remains operationally plausible on the browser engines tested, but the product-level durability claim is **not yet portable enough to approve**.

The strongest positive result is that non-extractable Ed25519 signing keys and non-extractable AES-GCM evidence-vault keys successfully round-tripped through IndexedDB and remained usable after page reload and browser-process restart on the tested Chrome-for-Testing, Firefox and Playwright WebKit engines.

The strongest negative result is architectural: **Mode B final-only retention is not crash-resilient before finalization.** If the server dies before the final commitment is durably written, authoritative completeness cannot be reconstructed from final-only server state. Recoverability requires an evolving durable accumulator, which creates additional persistent per-session metadata during the conversation.

A second major boundary remains: Linux Playwright WebKit is not native Safari, and mobile WebKit emulation is not iOS/iPadOS Safari or PWA execution. Native Apple-platform durability remains unproven.

## 3. Browser matrix

The seed pinned Playwright 1.63.0, whose browser set is Chrome for Testing / Chromium 153.0.8010.12, Firefox 155.0 and WebKit 26.6.

| Environment | Ed25519 IDB reload | AES-GCM IDB reload | Same-profile browser-process restart | Site-data deletion | Profile isolation | Status |
|---|---:|---:|---:|---:|---:|---|
| Chrome for Testing 153.0.8010.12 on Ubuntu runner | PASS | PASS | PASS | destructive as expected | PASS | PROVEN FOR THIS ENGINE/OS |
| Firefox 155.0 on Ubuntu runner | PASS | PASS | PASS | destructive as expected | PASS | PROVEN FOR THIS ENGINE/OS |
| Playwright WebKit 26.6 on Ubuntu runner | PASS | PASS | PASS | destructive as expected | PASS | PROVEN FOR PLAYWRIGHT WEBKIT, NOT NATIVE SAFARI |
| WebKit mobile emulation on Ubuntu runner | PASS | PASS | PASS | destructive as expected | PASS | EMULATION ONLY; NOT NATIVE iOS/iPadOS |
| Native macOS Safari | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | UNPROVEN |
| Native iOS/iPadOS Safari/PWA | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | UNPROVEN |

The first Firefox run produced a separate operational finding: all six key/evidence tests passed, but `navigator.storage.persist()` remained pending until the 60-second test timeout. The probe was then time-bounded rather than treated as a durability prerequisite. After that change Firefox passed the complete matrix. This does **not** prove a Firefox storage defect; it proves the application cannot safely make receipt/evidence durability depend on an unbounded persistence-permission request resolving promptly in every environment.

## 4. Persistence matrix

| Event | Result |
|---|---|
| Same page / IndexedDB round-trip | Evidence and non-extractable keys usable in tested engines. |
| Page reload | Evidence and keys survived. |
| Browser-process restart with same persistent profile | Evidence and keys survived in tested engines. |
| Separate browser profile | Could not read another profile's evidence. |
| Fresh isolated/private-like Playwright context | Prior context evidence absent after context destruction. |
| Explicit site-data deletion | Evidence and keys destroyed. |
| Native incognito/private mode | UNPROVEN; Playwright isolated contexts are only a model. |
| Browser storage eviction under real disk pressure | UNPROVEN experimentally. Browser storage remains subject to quota/eviction policy unless persistence is granted. |
| OS/device reboot | UNPROVEN; process restart is not an OS reboot. |
| Device loss/profile reset | Destructive by architecture; no backup was introduced. |

The evidence vault therefore survives ordinary reload/restart in tested desktop engines but remains **browser-profile-local state**, not durable evidence in the legal/archive sense.

## 5. Key-persistence findings

- Non-extractable Ed25519 private keys were stored directly in IndexedDB and were still capable of signing after reload/process restart in all tested Playwright engines.
- The corresponding public key still verified the signature.
- Non-extractable AES-GCM keys stored in IndexedDB still decrypted retained ciphertext after reload/process restart.
- `extractable` remained false after retrieval.
- A fresh browser profile had no access to the prior profile's key/evidence records.
- Clearing site data removed the stored key/evidence records.

This is meaningful positive evidence for Chrome/Firefox and the tested WebKit build, but it is not enough to make a universal Safari/iOS claim. Current WebKit bug evidence also shows that IndexedDB persistence behavior can be algorithm-specific: Safari 26.4 has a reported reproducible failure for non-extractable X25519 keys while AES-GCM works. SAFETY-03 did not observe that failure for Ed25519 in Playwright WebKit, but the existence of an algorithm-specific Safari failure is sufficient reason to require native Apple testing before admission.

## 6. Crash/restart behavior

### Mode A

The prototype treats live acceptance state as ephemeral. A server restart destroys:

- active witness-session sequence state;
- in-memory digest→receipt lookup;
- the ability to re-return a lost receipt solely from live state.

If the server accepted a signed envelope but the network died before the client received its receipt, the client can recover that receipt only while the server still has acceptance state. After an unpersisted server restart, the client can still prove endpoint signature authenticity but not server acceptance. The verifier therefore degrades to `ENDPOINT_AUTHENTICITY_ONLY`.

Making lost receipts recoverable across server restarts would require persistently retaining some acceptance/deduplication state. That is another privacy/metadata trade-off and is **not part of Mode A as currently defined**.

### Mode B final-only

If finalization completes and the final commitment is durable, the commitment survives a restart and remains available.

If the server crashes **before** the final commitment becomes durable, final-only Mode B cannot prove the true final count/root after restart. The correct state is `FINALIZATION_INCOMPLETE`.

Therefore final-only Mode B has an unavoidable crash window.

### Mode B evolving accumulator

The seed proved a crash-resilient alternative can retain an evolving accumulator containing:

- `witnessSessionId`;
- accepted sequence;
- message count;
- Merkle frontier;
- server key ID.

That is sufficient to recover a root/count after restart in the model. It contains no plaintext and no `finalized_at`, but it is **persistent evolving session metadata**, updated as the conversation progresses.

This materially changes Mode B's privacy description. Crash-resilient Mode B is not merely "retain one final root when the room ends."

## 7. Finalization failure states

The seed distinguishes these conditions:

1. **Before final durable commit:** `FINALIZATION_INCOMPLETE`.
2. **After final durable commit:** `FINALIZED`; restart retains commitment.
3. **Evolving accumulator exists but no final record:** `RECOVERABLE_FROM_EVOLVING_ACCUMULATOR` in the research model.
4. **Final commitment exists but report ends before final sequence/count:** `TRAILING_OMISSION_DETECTED`.
5. **Final commitment absent in Mode A:** not an error; completeness remains unprovable by design.

`finalized_at` was not required by any tested cryptographic or recovery property and remains removed.

## 8. Receipt/network behavior

- Duplicate submission of the same digest during the same live session is idempotent and returns the original acceptance sequence.
- A delayed valid receipt upgrades evidence from endpoint-authenticity-only to server-accepted evidence.
- A receipt lost before client delivery does not magically exist client-side.
- Live receipt recovery disappears after an unpersisted server restart.
- Continuing a stale pre-restart session sequence was rejected rather than silently inventing continuity.

The seed therefore supports an explicit distinction between "endpoint signed" and "server accepted."

## 9. Historical server-key behavior

Old evidence can remain verifiable across server signing-key rotation only while the corresponding historical **public** verification key remains in an integrity-protected registry.

Deleting the old private key is compatible with historical verification. Removing the historical public key is not.

The historical key registry should identify server signing epochs only. It must not become a participant/session directory.

## 10. Evidence-verification degradation states

The verifier model returns explicit classifications rather than a generic verified/unverified boolean:

- `LOCAL_EVIDENCE_UNAVAILABLE`
- `MALFORMED_EVIDENCE`
- `INVALID_ENDPOINT_SIGNATURE`
- `HISTORICAL_SERVER_KEY_UNAVAILABLE`
- `ENDPOINT_AUTHENTICITY_ONLY`
- `INVALID_ACCEPTANCE_RECEIPT`
- `ACCEPTED_EXCERPT`
- `FINALIZATION_INCOMPLETE`
- `INVALID_FINAL_COMMITMENT`
- `TRAILING_OMISSION_DETECTED`
- `ACCEPTED_COMPLETE`

Every classification returns:

`SAFETY_ADJUDICATION = NOT_DETERMINED`

No classification asserts aggression, blame, intent, human authorship, uncompromised device state, or narrative truth.

## 11. Mode A vs Mode B operational comparison

| Property | Mode A | Mode B final-only | Mode B crash-resilient accumulator |
|---|---|---|---|
| Persistent final commitment | No | Yes | Yes/eventually |
| Trailing-omission detection | No | Yes after successful finalization | Yes after recoverable/final state |
| New evolving per-session server metadata | No by reference design | No | **Yes** |
| Receipt recovery after unpersisted server restart | No | No for pre-final receipt state | Not automatically; accumulator is completeness state, not a receipt directory |
| Crash before finalization | Privacy preserved; completeness unavailable | **Completeness lost** | Completeness state recoverable |
| Correlation/legal surface | Lowest | Higher | **Higher still** due evolving state |
| `finalized_at` required | No | No | No |

The Council's original trade therefore expands from:

`COMPLETENESS EVIDENCE ↔ PERSISTENT SESSION METADATA`

to:

`CRASH-RESILIENT COMPLETENESS ↔ EVOLVING PERSISTENT SESSION METADATA`.

## 12. Operational linkability audit

See `docs/seeds/SEED-SAFETY-03-LINKABILITY-AUDIT.md`.

Key findings:

- Current custom telemetry strongly bans content and high-cardinality IDs; `witness_session_id` would be stripped by its `_id` rule.
- Conversation channel join/handle-in logging is disabled and the custom channel crash translator is content-blind.
- These protections do not prove a future generic Phoenix/APM exporter is safe.
- Render can retain application logs and, on eligible plans, public HTTP request logs with a unique request correlation ID. Witness IDs must not appear in URLs/logs and provider request IDs must not be copied into durable witness records by default.
- Canonical `Conversation` rows already store participant pairs plus timing/activity metrics.
- Canonical `Report` rows directly join reporting participant, reported participant and Conversation.
- Therefore a witness→Conversation or witness→Report mapping can immediately make otherwise fresh witness metadata identifiable to operators/Safety.
- No Redis/Redix integration was found in repository code search on the audited base; introducing one for witness state would create a new retention/join authority.
- No active Sentry integration was found in repository code search; future generic error/APM tooling still requires a field-level audit.
- Backups and crash dumps count as retention/correlation surfaces.

Mode B metadata should therefore be described as **pseudonymous session metadata**, not inherently anonymous metadata.

## 13. Architectural assumptions falsified or narrowed

### Falsified

1. **"Mode B can be crash-resilient while retaining only a final commitment."** False if the server crashes before finalization. Some evolving durable state is required for authoritative recovery.
2. **"A signed message with no receipt can simply be called verified/unverified."** Too coarse. Endpoint authenticity can survive while server acceptance is unproven.
3. **"A fresh witness ID is operationally unlinkable by construction."** False. Logs, request IDs, Reports, Conversation rows, timing/count metadata, backups and operator joins can re-link it.
4. **"Persistent-storage permission can be treated as an ordinary prompt-free prerequisite."** Not supported by the Firefox automation evidence; the request can fail to resolve promptly in at least this environment.

### Narrowed but not falsified

1. Non-extractable Ed25519/AES CryptoKeys can survive IndexedDB reload and browser-process restart on the tested desktop engines.
2. Playwright WebKit success does not establish shipping Safari success.
3. Isolated-context destruction models private-session ephemerality but does not prove exact native private/incognito behavior.
4. Browser-process restart does not prove OS/device reboot behavior.
5. Real storage-pressure eviction remains untested; browser policy still permits eviction for best-effort storage.

## 14. Critical browser/product answer

Is the evidence-vault + non-extractable signing-key model **durable enough today to make a universal mainstream-browser product promise?**

**Not yet.**

It is strong enough to justify continued research because the core persistence mechanism worked on current Chrome-for-Testing, Firefox and Playwright WebKit engines. But native Safari/macOS and iOS/iPadOS Safari/PWA remain untested, storage eviction remains a browser-controlled failure mode, and local deletion/device loss remain intentionally destructive.

The safe product statement remains conditional:

> Local witness evidence can survive ordinary reload/restart on supported environments, but later reporting depends on the evidence vault and required verification keys still existing.

Do not promise permanent evidence retention.

## 15. Recommendation to Evolution Council

1. Keep **Mode A** as the leading privacy baseline.
2. Keep **Mode B final-only** as a forensic option with a documented crash-before-finalization hole.
3. Do **not** silently upgrade Mode B to an evolving durable accumulator. That is a new privacy architecture decision requiring Council approval.
4. Keep `finalized_at` absent.
5. Preserve explicit evidence degradation states in any later design.
6. Require native macOS Safari and native iOS/iPadOS Safari/PWA testing before browser durability can become a product contract.
7. Do not introduce cloud backup to solve local durability without a separate seed.
8. Do not persist global endpoint-key fingerprints solely to police key reuse without explicitly accepting the resulting cross-session linkability.
9. Treat witness identifiers as unlinkable only under specified store/operator joins, never globally.
10. Keep this seed isolated and unmerged.

### Council disposition suggested

**SEED-SAFETY-03: CONDITIONAL PASS WITH TWO MATERIAL WARNINGS.**

- Browser-key persistence is promising across the tested engines but native Apple/browser-lifecycle coverage is incomplete.
- Crash-resilient Mode B requires more persistent metadata than the final-only design and must not be smuggled into the architecture as an implementation detail.
