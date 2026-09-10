# StrangerTalks Language Team — P02 Instrumentation Independent Review Round 1

Owner: Manvith  
Implementation DRI: Partner 02 — Interface Language Architecture & Placement  
Independent reviewer: Partner 01 — World Language & Meaning  
Governing issue: #247  
Implementation PR: #249

## Review snapshot

This review is deliberately anchored to repository evidence rather than Partner 02's prose handoff.

Canonical main verified during review:

`65b6bf065193269c52cc73c5231dc64546b92d38`

Partner 02 branch moved while review was underway. Relevant sequence observed:

- `91fc5cfada63af11b167eeba1623a8d07f5cd3d0` — handoff head;
- `d17c3bd6add517ca216625f59bbbe76d3d94e819` — RED first-message same-flow test;
- `6a3d151480635976104a1833c09e235cd0217ade` — GREEN flow-scoped match eligibility;
- `941a61028cd5829f7a42c82d798dcdf298f82d09` — runtime first-message hook routed through the flow observer;
- `40090538eb8c4c11d7d632c0f7ece143c07025e4` — RED test freezing the authoritative queue event as `st_queue_joined`.

This is therefore a moving-branch review, not a final exact-head admission verdict.

## Current verdict

# FAIL / CORRECTIONS REQUIRED BEFORE EVENT-INTEGRITY PASS

This is not a rejection of the instrumentation approach.

The provider-neutral architecture is directionally sound, but the event layer is not yet sufficiently bounded or reconnect-complete to support the frozen baseline contract.

Production baseline remains `LOCKED`.

Provider transport remains `NOT APPROVED` and Task 9 must remain unstarted.

## Finding 1 — same-flow first-message law

### Reviewer decision

`CORRECT LAW`

`st_first_message_accepted` must require an authoritative match observed in the same `flow_attempt_id`.

A restored pre-existing conversation must not be allowed to fabricate completion of a new entrance → queue → match → first-message funnel.

Partner 02's original handoff correctly identified this defect.

### Repository state observed

Partner 02 then created a RED test at `d17c3bd6...`, implemented flow-scoped `matchedInFlow` state at `6a3d1514...`, and routed the runtime message-success hook through `queueEvents.firstMessageAccepted()` at `941a6102...`.

The resulting design resets match eligibility when the tracker rotates to a new `flow_attempt_id`.

### Status

`STRUCTURALLY CORRECT — FINAL EXACT-HEAD PROOF STILL REQUIRED`

Do not close this finding from commit messages alone. Final Task 10 proof must exercise the resulting exact head.

## Finding 2 — authoritative queue event vocabulary drift

### Severity

`BLOCKING CONTRACT DRIFT`

The frozen measurement flow uses:

`st_queue_joined`

not:

`st_queue_admitted`

At the review snapshot, production event code still contained `st_queue_admitted` / `admitted()`, while the latest Partner 02 commit `40090538...` intentionally changed the tests to expect `st_queue_joined` / `joined()`.

That latest head is therefore an intentional RED state for this correction.

### Required correction

Make production/runtime vocabulary match the frozen measurement contract:

- event: `st_queue_joined`;
- observer transition: `joined()` or another clearly equivalent implementation;
- all tests, report shells, queries, and later provider mappings must use the same authoritative name.

Do not add an alias that lets both names survive into production analytics unless a migration requirement actually exists. No production events exist yet, so carrying two names would create needless taxonomy debt.

### Status

`OPEN — PARTNER 02 ACTIVELY CORRECTING`

## Finding 3 — allowed property keys are bounded, allowed values are not

### Severity

`BLOCKER — PRIVACY / TAXONOMY INTEGRITY`

The generic core correctly rejects unknown event names and drops unknown property keys.

However, `createIntentSelectionObserver.select(intentValue)` accepts any non-empty string, and `createQueueEventObserver.requested(nextIntentCode, nextInteractionLanguage)` accepts any non-empty strings.

This is not enough.

The queue-request event is captured before the backend validates the outbound `queue:join`. Therefore a manipulated client payload can place arbitrary strings into an *approved property key* and reach the analytics sink even if the server later rejects the product request.

Examples that must fail at the semantic event boundary:

- arbitrary/free-form `intent_value`;
- arbitrary/free-form `intent_code`;
- arbitrary/free-form `interaction_language`;
- DOM-tampered `data-door` values;
- oversized strings supplied through an otherwise allowlisted field.

Key allowlisting protects the shape; it does not make the values safe.

### Current canonical bounded values

Current Four Door backend codes are:

- `JUST_TALK`
- `KEEP_IT_LIGHT`
- `EXPLORE`
- `SOMETHING_REAL`

Current V1 Conversation Language authority is centrally allowlisted by the product as `en`, `te`, and `hi`.

The analytics layer should consume current product authority rather than becoming a second permanent source of truth. Future worldwide language expansion must not require analytics-specific redesign, but today's event values still need validation against today's canonical product set.

### Required RED cases

Prove that no event reaches the sink when:

1. intent selection receives an unknown Door code;
2. queue request receives an unknown Door code;
3. queue request receives an invalid/free-form language code;
4. an allowed key contains arbitrary text intended to simulate sensitive user content.

### Required GREEN behavior

Validate bounded semantic values before event construction or at an equivalent central semantic boundary.

Do not merely truncate an arbitrary value and call it safe.

### Status

`OPEN`

## Finding 4 — authoritative queue recovery can lose the `queue_joined` stage

### Severity

`BLOCKER — RECONNECT / FUNNEL INTEGRITY`

The normal fresh queue path has a useful server ordering: after successful server queue admission, `ParticipantChannel` pushes `queue:status = queued` before returning the successful queue-join reply.

The runtime correctly measures the live `queue:status = queued` path only after its stale-attempt presentation guard.

But session reconciliation creates another authoritative state path.

Observed runtime behavior:

- a `QUEUED` reconciliation snapshot calls `applyQueueSnapshot(...)` and restores the UI;
- it does not currently record the authoritative queue-join measurement stage;
- a `CONVERSATION` reconciliation snapshot can call the match observer.

This leaves a measurable recovery hole.

Example:

1. current flow emits `st_queue_requested`;
2. server admits the user;
3. browser/network misses or loses the live `queue:status = queued` delivery;
4. reconnect/reconciliation later returns canonical `QUEUED` or `CONVERSATION`;
5. the product correctly recovers;
6. analytics may have `queue_requested → match_created` with no authoritative `queue_joined` event.

That violates the frozen ordered funnel even though the product itself behaved correctly.

### Important constraint

Do **not** solve this by inventing a historical queue-join timestamp at reconciliation time and then silently using it in latency calculations.

A recovered observation is observed at recovery time, not at the historical admission time unless the server actually supplies a trustworthy admission timestamp.

### Required RED cases

At minimum cover:

- request → lost live queued push → reconcile canonical `QUEUED`;
- request → lost live queued push → reconcile canonical `CONVERSATION`;
- stale/pre-existing `QUEUED` or `CONVERSATION` at boot must not fabricate a new entrance funnel;
- recovered authority must not double count if the live queued event was already recorded.

### Required design decision

Choose one evidence-preserving recovery model before baseline collection. Examples include:

- emit the same authoritative `st_queue_joined` once when current-flow reconciliation proves queue authority, with a bounded observation-source property and exclude recovered timing where historical time is unknown; or
- obtain an authoritative server timestamp if the existing canonical snapshot safely exposes one; or
- explicitly classify affected flows as recovery/incomplete for timing while preserving conversion evidence.

Whichever model is chosen must be frozen in the analysis contract before production data is visible.

### Status

`OPEN`

## Finding 5 — post-admission intent lock is proven only in a unit test, not wired to runtime authority

### Severity

`BLOCKER — EVENT SEMANTICS`

`createIntentSelectionObserver` contains `markQueueAdmitted()` and its unit test proves that calls to `select(...)` stop creating reversals after this flag is set.

However, the runtime Door observer is created locally inside `arrival_first_minute.mjs` and the authoritative queue listener lives in `flow_loading_runtime.mjs` through a separate `queueEvents` observer.

At the review snapshot, no production bridge was found that invokes the local intent observer's admission lock when `queue:status = queued` is accepted.

This means the test proves a capability that production does not appear to use.

A particularly important case is a flow that was authoritatively queued and later returns to Doors because the queue times out or another canonical terminal queue transition occurs without rotating the measurement flow. A later Door selection could be recorded as `st_intent_changed` even though the frozen law says intent reversal is a pre-admission diagnostic.

### Required RED cases

Prove production semantics for:

- first Door → authoritative queue join → later attempt to change Door in same measurement flow does not create `st_intent_changed`;
- authoritative queue join → terminal queue state → return to Doors has an explicit flow-boundary decision before a new Door selection;
- flow rotation, if chosen, produces a genuine new `st_entrance_ready` before a new first-intent measurement.

### Required correction

Either:

- wire the authoritative queue-join boundary into a shared flow observer that owns both intent and queue stage state; or
- define a clean flow rotation at the relevant terminal transition and prove the new entrance boundary.

Do not leave a unit-only `markQueueAdmitted()` method as proof of production behavior.

### Status

`OPEN`

## Finding 6 — remove unused `message_type` from the first-message allowlist

### Severity

`REQUIRED HARDENING`

`st_first_message_accepted` currently allowlists `message_type`, but the runtime first-message hook does not need or send that property and no baseline question requires it.

Keeping an unused field increases future collection surface for no present measurement value.

### Required correction

Remove `message_type` from the event property's allowlist unless Partner 02 can point to a preregistered baseline question that requires it.

No such requirement is present in the current measurement contract.

### Status

`OPEN`

## Finding 7 — Talk Language open events need transition-level duplicate semantics

### Severity

`NON-BLOCKING NOW / REQUIRED BEFORE BASELINE INTERPRETATION`

The current UI can call `st_talk_language_opened` from pointer and multiple keyboard triggers.

The frozen review checklist expects one event for one genuine open transition rather than repeated key activity manufacturing several opens.

Before using this event as a share/count metric, either:

- prove one genuine chooser transition emits once; or
- rename/document the semantic as an invocation/interaction attempt and analyze it accordingly.

Do not interpret raw repeated open events as multiple independent user decisions.

### Status

`OPEN`

## Findings that passed this review round

### Cancellation authority / flow rotation

The current cancellation design is appropriate for the stated scope:

- only the bounded `queue:user_requested` combination is accepted;
- the metric is emitted only after the server confirms queue leave with `status = left`;
- error/timeout paths do not close the flow;
- the captured cancellation keeps the old `flow_attempt_id` because the event is constructed before reset;
- a successful cancellation rotates the tracker flow;
- observers synchronize and clear old flow state;
- entrance-ready is re-armed only when the product actually returns to the Doors screen.

This still requires final exact-head tests, but no conceptual correction is requested in this round.

### Generic unknown-property stripping

The core's event-name allowlist and property-key allowlist are the correct architectural boundary.

Unknown event names are rejected and non-allowlisted properties are dropped before reaching the sink.

The remaining defect is value validation inside approved fields, covered by Finding 3.

### Door codes as context, not identity

Using the four stable Door codes as per-flow interaction context is acceptable.

They must not be copied into a persistent person profile, promoted into personality labels, or used as inferred psychological identity.

No such persistent identity behavior was found in the reviewed event core.

## Required Partner 02 correction order

1. Finish same-flow first-message GREEN/exact-head proof.
2. Finish `st_queue_joined` contract rename GREEN.
3. Add semantic value allowlists/validation for Door and language properties.
4. Close the reconciliation queue-join gap with explicit recovery semantics.
5. Wire/fix post-admission intent-flow semantics.
6. Remove unused `message_type`.
7. Freeze chooser-open duplicate semantics.
8. Run every focused product-event suite.
9. Run relevant existing browser/product regressions.
10. Run exact-head protected CI on the final candidate.
11. Return a new exact-head proof packet for Partner 01 review.

Do not start Task 9.

## Evidence required in the next packet

The next Partner 02 packet should provide:

- exact branch and HEAD;
- base/main ancestry refresh;
- RED and GREEN commits for each blocking correction;
- focused commands and exact results;
- reconnect/reconciliation proof cases;
- event/property/value allowlist table after correction;
- proof no unused first-message payload field remains;
- relevant browser regression results;
- protected exact-head check-run results;
- confirmation provider transport remains absent.

## Reviewer state after Round 1

Event-integrity verdict: `FAIL — CORRECTIONS REQUIRED`  
Destination privacy verdict: `NOT APPROVED`  
Production baseline: `LOCKED`  
Task 9: `DO NOT START`  
Final admission: `PENDING NEW EXACT-HEAD PACKET`
