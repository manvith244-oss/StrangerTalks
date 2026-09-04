# StrangerTalks Agent Context Provenance, Freshness & Non-Persistence Contract

Packet: `T-A07-003`

Status: **CONTRACT FROZEN — IMPLEMENTATION OUTSIDE THIS PACKET**

Canonical reconstruction base:

- commit: `20293425b0556d733f47d43714d236582df7948d`
- tree: `f4bb8b3b11a1b6423aaaed07664c2454995dee69`

This document defines V1 context semantics for StrangerTalks Agents. It does not create Agent memory, RAG, embeddings, a vector database, participant profiling, or new Safety authority. It does not repair Report/SafetyReview retention or A03 freshness defects.

## 1. Laws

The following are frozen:

**PERSISTED != AUTHORITATIVE**

Persistence answers where data is stored, not whether the data is factual, current, or authoritative.

**AUTHORITATIVE SNAPSHOT != CURRENT STATE**

A correctly captured historical snapshot can remain valid evidence without representing the current state of the source object.

**MODEL INPUT != MEMORY**

Context supplied for one invocation is ephemeral input unless an independently authorized durable store exists for another product purpose.

**EMBEDDING != ANONYMIZATION**

A vector representation remains derived data and does not become anonymous merely because it is not human-readable text.

**CONTEXT ACCESS != AUTHORITY**

An Agent may consume authorized context without gaining mutation, Safety, Matchmaking, relationship, publication, or policy authority.

## 2. Context provenance classes

Every material context item consumed by an Agent must have a known provenance class. Unknown provenance is not silently upgraded.

### PARTICIPANT_PROVIDED

Content explicitly supplied by a participant, including a Companion request, draft, or free-form Report evidence.

Properties:

- factual claims remain untrusted unless separately verified;
- persistence does not promote the content to canonical fact;
- the value may be immutable for the current invocation even when its factual assertions are unverified;
- inferred meaning must not be written back as authoritative participant state.

### CANONICAL_CURRENT

Current state read from the authoritative product owner at capture time, where later change can matter.

Examples include current Conversation lifecycle state, current Safety veto state, current Report/SafetyReview state, and current server-held message content while it is being read as current content.

Properties:

- requires an authoritative source;
- requires a freshness/revision story when provider work can outlive the captured state;
- must be re-read or otherwise revalidated before an Agent result that depends on it is accepted.

### CANONICAL_SNAPSHOT

Intentionally captured historical evidence whose correctness is tied to capture identity rather than current mutable state.

Examples include preserved Safety snapshots of unsent content and any canonical message content intentionally captured into immutable Safety evidence at report time.

Properties:

- must be labeled as historical snapshot evidence, not current content;
- requires stable snapshot identity or equivalent provenance sufficient to prove which captured evidence was reviewed;
- current source mutation alone does not invalidate a correctly retained snapshot;
- deletion, minimization, replacement, provenance loss, or loss of authorization to use the snapshot can invalidate its use.

### OPERATOR_PROVIDED

Material supplied by an authorized operator/caller, including A04 research signals.

Properties:

- remains untrusted model input rather than policy/system instruction;
- carries no canonical factual guarantee merely because an operator supplied it;
- must not gain publication or product authority through model processing.

### AGGREGATE_SYSTEM_EVIDENCE

Privacy-bounded aggregate evidence derived from canonical product records without participant-level output.

Examples include V1Metrics snapshots.

Properties:

- authority applies to the defined aggregate query/window and schema, not to participant-level claims;
- the reporting window/schema version are part of its provenance;
- it must not be reverse-interpreted into psychological, identity, or participant-level conclusions.

### UNKNOWN_UNPROVEN

Required fail-closed class when provenance cannot be established strongly enough for the requested use.

Properties:

- must not be silently treated as participant-provided, canonical current, canonical snapshot, or aggregate canonical evidence;
- capabilities that require trusted provenance must reject or degrade safely;
- lack of provenance must not be repaired by model inference.

### SAFETY_SENSITIVE overlay

`SAFETY_SENSITIVE` is an access/handling overlay, not a provenance class and not a grant of Safety authority.

Report evidence, Safety snapshots, review state, raw Safety media, and related material may carry this overlay in addition to one provenance class above.

## 3. General context envelope

The V1 conceptual contract separates **model-semantic context** from **deterministic control context**.

A capability may conceptually capture:

```text
context = {
  semantic_input,
  provenance,
  authoritative_refs,
  freshness_identity,
  retention = EPHEMERAL,
  provider_projection
}
```

This is a semantic contract, not a requirement to create a universal struct, table, or service.

### Model-semantic context

Only information the model actually needs to perform the authorized reasoning task.

### Deterministic control context

Identifiers, revisions, digests, authority-state values, freshness tokens, access checks, and revalidation metadata needed to decide whether the model result is still admissible.

Deterministic control context should remain outside the external provider payload unless the model semantically requires it.

## 4. Freshness pattern

For mutable authoritative context, the default V1 pattern is:

```text
capture authorized context
        ↓
capture freshness identity
        ↓
project only required semantic input to provider
        ↓
provider/model work
        ↓
validate model output
        ↓
re-read/revalidate authoritative state
        ↓
recompute/compare freshness identity
        ↓
ACCEPT RESULT or STALE-REJECT
```

A stale-rejected model output is not reused merely because the model call was expensive or structurally valid.

## 5. What invalidates mutable context

Where relevant to the capability, an Agent result must become stale when any context assumption that materially supported the result changes before acceptance, including:

- authoritative subject no longer exists;
- caller is no longer authorized to access the subject;
- lifecycle leaves the capability's allowed state;
- Safety veto/control state changes in a way that removes authorization;
- relevant source revision/version changes;
- exact model-visible current projection changes;
- evidence availability changes;
- provenance class changes;
- associated authoritative review state becomes terminal or otherwise incompatible with the invocation;
- canonical evidence is minimized/deleted/replaced;
- an immutable snapshot identity no longer resolves to the same authorized snapshot.

The comparison need only cover facts the result actually depends on. Irrelevant state should not be added merely to make a larger token.

## 6. Snapshot freshness

Canonical snapshots do not use the same rule as current mutable state.

For a `CANONICAL_SNAPSHOT`, freshness means:

- the same snapshot identity still exists or remains valid for the review;
- the snapshot has not been deleted, minimized, replaced, or disallowed;
- the governing review/capability state still permits its use.

A later edit or unsend of the original live message does not by itself make an intentionally retained Safety snapshot stale. The snapshot is historical evidence and must remain labeled as such.

## 7. Participant-provided invocation freshness

A direct participant request/draft supplied for a single invocation is fixed input for that invocation and normally requires no database revalidation of its text.

If participant-provided content is instead read later from a persisted canonical product record, freshness of that stored field and authorization to use it must be revalidated when the capability depends on the persisted record.

Persistence never changes the provenance class from `PARTICIPANT_PROVIDED` to canonical fact.

## 8. Operator-provided and aggregate evidence freshness

### OPERATOR_PROVIDED

Operator-supplied input is fixed for the invocation but has no implied canonical-current guarantee. If later product publication or mutation depends on factual freshness, a separate deterministic admission check must establish that freshness.

### AGGREGATE_SYSTEM_EVIDENCE

Aggregate evidence is a bounded snapshot over a defined window/schema. Its provenance should include enough information to identify the query contract, such as schema version and reporting window. It is not required to revalidate every underlying row after provider work unless a later authoritative action specifically depends on a live-current value.

## 9. A01 current reference contract

A01 is the strongest implemented V1 freshness reference.

### Participant-provided capture

A01 captures bounded:

- mode;
- request;
- draft;
- tone.

These remain participant-provided invocation input.

### Canonical capture

A01 currently derives context from:

- `Conversation` row for membership/lifecycle/door/match reference;
- `Matching` row for canonical Conversation language;
- `MatchingRules` for current Safety veto;
- `ConversationServer.inspect_state/1` for active runtime state, epoch, next sequence, recent messages, and current starter runtime identity;
- `IcebreakerCatalog` for the canonical language-qualified starter text.

### Bounded transcript projection

A01 includes at most 12 current text messages, excluding unsent messages, capped per message and by an overall context character budget. Each projected message contains role, bounded text, and sequence.

It does not create a PostgreSQL transcript copy.

### Captured A01 authority metadata

A01 captures:

- conversation status;
- match id;
- language;
- runtime epoch id;
- next sequence;
- transcript fingerprint of the exact bounded message projection;
- starter identity.

### What A01 actually revalidates

After provider work and output validation, A01 re-reads/rechecks:

- Conversation existence;
- current participant membership;
- allowed Conversation lifecycle;
- current match-derived language equals captured language;
- current Safety veto remains clear;
- live ConversationServer runtime remains available and `ACTIVE`;
- runtime epoch id equals captured epoch id;
- runtime next sequence equals captured next sequence;
- fingerprint of the newly projected bounded transcript equals captured transcript fingerprint;
- current starter identity equals captured starter identity.

Important accuracy note: although captured inside the authority map, the stored `conversation_status` and `match_id` values are not currently equality-compared during revalidation. Current code instead revalidates the lifecycle/member/language assumptions described above.

### Provider projection

The external model receives only the semantic projection:

- language;
- door;
- mode;
- tone;
- request;
- draft;
- bounded messages;
- current Conversation Start projection.

The provider does not receive participant id, peer id, request id, draft fingerprint, authority metadata, runtime epoch, next sequence, transcript fingerprint, or starter freshness token. `conversation_id` is also removed at the provider boundary.

### Stale disposition

Any failed A01 revalidation becomes `:companion_stale`; the caller does not receive the generated result.

This establishes the reusable principle:

> model-visible semantic context and deterministic freshness metadata are separate concerns.

## 10. A03 minimum context contract

A03 is advisory only. This contract does not give it Safety mutation authority.

### A03 model-semantic input — minimum

The model should receive only what it needs to evaluate the bounded report evidence:

- report category;
- bounded evidence value when authorized and available;
- coarse evidence provenance semantic needed for correct interpretation;
- media-presence boolean when relevant, never raw Safety media.

A coarse provider-visible provenance value may distinguish, for example:

- participant-provided allegation/context;
- canonical Safety snapshot.

`CANONICAL_CURRENT` should not be used to describe report-time message content later reviewed from a retained Safety evidence copy. Once intentionally captured as report evidence, that content is a snapshot for later review.

The model does not need report id, SafetyReview id, participant ids, revisions, timestamps, hashes, row versions, or freshness tokens merely to produce the advisory classification.

### A03 deterministic control context — minimum

The deterministic A03 caller/revalidator must be able to establish:

1. the exact Report under review;
2. the exact authoritative SafetyReview governing that Report;
3. whether the capability is currently authorized to review it;
4. the evidence provenance class;
5. the evidence availability state;
6. a stable identity for the exact evidence projection reviewed;
7. the relevant current Report/Review state needed for admission;
8. a freshness identity that can be recomputed after provider work.

The contract does not require these to become new database columns. They may be derived from authoritative records, existing revisions, stable snapshot identity, field digests, or another deterministic representation chosen by the owning implementation team.

### A03 freshness identity

The exact implementation is owned by the implementing packet, but the token must be semantically equivalent to the minimum facts the result depends on.

Conceptually:

```text
freshness_identity = digest(
  report_subject,
  authoritative_review_subject,
  admissible_report/review_state,
  evidence_provenance,
  evidence_availability,
  exact bounded evidence identity,
  relevant source revision or snapshot identity,
  media_presence_if_model_used_it
)
```

The digest/token itself is deterministic control metadata and should not cross the provider boundary.

### A03 post-provider revalidation

Before returning a model result as ready, deterministic code must re-establish the authoritative context and compare it with the captured freshness identity.

The result must stale-reject if, where relevant:

- the Report or governing SafetyReview no longer exists;
- the review has become terminal/incompatible;
- the evidence was changed, replaced, minimized, or deleted;
- evidence availability changed;
- the provenance/identity of the reviewed evidence can no longer be proven;
- media presence changed when that fact affected the model invocation;
- authorization to consume the Safety-sensitive context is no longer valid.

A structurally valid model output is insufficient when the context has become stale.

### A03 provenance uncertainty

If current canonical storage cannot establish whether retained report evidence was participant-provided versus canonically captured Safety evidence, the Agent layer must not guess.

Until deterministic Safety authority exposes sufficient provenance, the value is `UNKNOWN_UNPROVEN` for any use requiring that distinction.

The fix must occur at the authoritative context/provenance boundary; model inference must not manufacture provenance.

## 11. Evidence availability semantics

Absence must not be ambiguous.

The deterministic context builder should distinguish at least conceptually between:

- evidence intentionally absent at original capture;
- evidence currently present;
- evidence formerly present but now unavailable/minimized/deleted;
- provenance/availability unknown.

Whether A03 may still run with intentionally absent evidence is a Safety capability decision, not a Team 7 authority expansion. Team 7 requires only that these states not be collapsed into the same semantic value when freshness depends on the difference.

## 12. Non-persistence contract

The default V1 Agent context lifecycle is:

```text
CAPTURE -> USE -> REVALIDATE -> DISCARD
```

Unless another canonical product subsystem already owns durable retention for an independently authorized reason:

- invocation context is not Agent memory;
- provider input is not written into a generic memory store;
- model output is not automatically durable Agent memory;
- freshness tokens/digests are ephemeral unless a deterministic owner independently needs durable audit provenance;
- Agent context must not be copied into Memories/Bonds;
- Agent context must not be copied into analytics as raw content;
- Agent context must not be embedded/indexed for future use;
- no cross-conversation participant memory is created;
- no psychological/behavioral profile is created.

Existing canonical Safety evidence remains canonical Safety evidence. Reading it for A03 does not convert it into Agent memory.

## 13. Provider exposure contract

For each Agent invocation, only the minimum model-semantic projection may cross an external provider boundary.

Deterministic-only metadata should remain local, including where possible:

- participant/account identifiers;
- product record identifiers;
- revisions/row versions;
- evidence digests/fingerprints;
- freshness tokens;
- internal authorization state;
- hidden Safety/governance metadata.

Raw Safety media remains excluded from A03 provider input in V1.

Provider `store: false` is a provider-request control, not proof of zero external retention and not a substitute for context minimization.

## 14. Logging and observability

Operators may observe bounded metadata such as capability, success/failure, stale rejection, latency, and provenance class where safe.

Do not log raw Agent context by default.

Do not log participant text, report evidence, Safety media, or reusable content fingerprints merely for debugging convenience.

A freshness comparison failure should be observable without exposing the sensitive value that changed.

## 15. Failure behavior

When required context cannot be obtained or proven:

- do not invent it;
- do not ask the model to infer missing provenance;
- do not silently substitute historical data for current state;
- do not silently substitute current state for an authoritative historical snapshot;
- reject or degrade according to the capability's defined fail-closed behavior.

`UNKNOWN_UNPROVEN` is an acceptable and sometimes required outcome.

## 16. Contract consumption by implementation teams

### Deterministic Safety / Construction authority

May use this contract to define the authoritative provenance/retention representation for Report/SafetyReview evidence without creating Agent memory.

### T-A03

May use this contract to implement the A03 capture/revalidate/stale-result gate while preserving A03's advisory-only authority.

### Team 4 runtime/provider engineering

May use this contract for provider-payload minimization and timeout/cancellation behavior, but does not own context authority semantics.

### Team 8 collaboration

Any future Agent-to-Agent transfer must preserve provenance/freshness classifications rather than flattening them into untyped text.

## 17. Explicit non-goals

This contract does not authorize:

- participant profiling;
- cross-conversation participant memory;
- generic persistent Conversation memory;
- shared global Agent scratchpads;
- RAG;
- embeddings;
- vector databases;
- autonomous learning;
- raw Conversation dataset creation;
- Agent-owned Safety enforcement;
- Agent-owned Matchmaking;
- Agent-owned Memory/Bond semantics;
- publication authority for A04.

## 18. Frozen V1 principle

> An Agent may consume only the minimum authorized context needed for its task. Every material input must have a provenance class. Mutable authoritative assumptions that can change during provider work must have a deterministic freshness identity and must be revalidated before result acceptance. Historical snapshots must remain labeled as snapshots. Invocation context is discarded by default rather than becoming Agent memory.
