# StrangerTalks Language Team — P02 Instrumentation Independent Review Round 2

Owner: Manvith  
Reviewer: Partner 01 — World Language & Meaning  
Implementation DRI: Partner 02 — Interface Language Architecture & Placement  
Governing issue: #247  
Reviewed PR: #249  

## Review snapshot

This review is based on repository bytes and CI evidence, not the Partner 02 handoff summary.

Canonical main observed during review:

`2f268b94d087ce1a177faeb9d96d3ddb8b8ece39`

PR #249 head observed for the frozen Round 2 checkpoint:

`c16e91c6ec87a0fa6b6a1cb2f9dda6dd6258b779`

PR #249 remains draft and unmerged. Its merge base is still the older main:

`65b6bf065193269c52cc73c5231dc64546b92d38`

The branch is therefore not fresh-main-integrated at this checkpoint.

## Round 2 verdict

**FAIL — CORRECTIONS / GREEN IMPLEMENTATION STILL REQUIRED.**

This is not a regression from Round 1. Partner 02 has intentionally added RED tests for several Round 1 findings. The newly added focused `Language Product Event Integrity` workflow checked out exact head `c16e91c6...` successfully and then failed in the focused product-event test step. That failure is expected evidence that the new contract is ahead of production code.

Do not convert that RED into PASS until the implementation changes, the exact same tests pass, fresh main is integrated, and the final exact-head proof is green.

Task 9 remains locked. No live analytics ingestion is approved.

---

## Findings closed in principle since Round 1

The following Round 1 directions are now represented in repository code or tests strongly enough to leave the original finding category, subject to final exact-head regression proof:

1. `st_queue_joined` is now the canonical queue-success event name.
2. Four Door and current V1 Talk-language analytics values are bounded semantically.
3. malformed event payloads are validated before consuming a once-only slot.
4. `st_first_message_accepted` no longer exposes `message_type` or other application-message properties.
5. entrance flow rotation has a general non-Doors → Doors coordinator rather than being cancellation-only.
6. held keyboard repeats no longer manufacture repeated chooser-open observations.
7. remembered Talk language is validated against the bounded baseline language contract rather than truthiness.
8. authoritative queue success now shares the intent observer and calls the post-join intent lock.

These are not production-baseline approval. They are implementation-direction closures only.

---

# ACTIVE BLOCKER A — CANONICAL FUNNEL MUST BE MONOTONIC

The frozen analysis funnel is:

`entrance_ready → intent_selected → talk_language_selected → queue_requested → queue_joined → match_created → first_message_accepted`

Round 1 found that match and first-message stages could be recorded without the complete preceding authoritative chain.

Partner 02 has now added RED tests requiring:

- `match_created` cannot occur unless `queue_joined` was successfully recorded in the same flow;
- `first_message_accepted` cannot occur unless `match_created` was successfully recorded in the same flow;
- failure to deliver `queue_requested`, `queue_joined`, or `match_created` truncates measurement rather than allowing a later stage to pretend the funnel was complete;
- session reconciliation must restore product state without fabricating historical queue/match timestamps.

At reviewed head `c16e91c6...`, focused product-event CI is RED, so the implementation has not yet proven these laws.

## Acceptance condition

The queue/match observer must maintain explicit successfully-recorded stage state, not merely observed product context.

A safe direction is equivalent to:

- request context becomes eligible only after successful `st_queue_requested` delivery;
- `joinedInFlow` becomes true only after successful `st_queue_joined` delivery;
- `matchedInFlow` becomes true only after successful `st_match_created` delivery;
- downstream methods return false when the required immediately preceding canonical stage is absent;
- reconciliation never synthesizes the missing event time.

The exact implementation may differ, but the observable contract may not.

---

# ACTIVE BLOCKER B — CURRENT MAIN NOW OVERLAPS THE LANGUAGE LIFECYCLE

The P02 handoff described the then-new main movement as unrelated security work. That is no longer current repository truth.

Canonical main is now `2f268b94...` through PR #255, which changes the Conversation Language lifecycle itself:

- the header Conversation Language selector is editable only while the Four Doors screen owns selection;
- outside active/visible Doors, the selector is disabled;
- a browser regression now protects that lifecycle.

PR #249 is still based on `65b6bf...`, so its current proof does not include this behavior.

This is a semantic integration requirement even if Git reports no textual conflict.

## Required fresh-main tests

After integrating current main, prove at minimum:

1. analytics still observes valid language interaction while Doors owns the choice;
2. queue/conversation states disable the visible Talk-language selector as current main requires;
3. a programmatically dispatched `change`, `keydown`, or pointer-like event on the disabled/non-owned control cannot manufacture `st_talk_language_opened` or `st_talk_language_selected` after authoritative queue join;
4. returning to a genuinely new Doors attempt resets the measurement authority and permits new language observations again;
5. PR #255's `p02_language_queue_lock_browser_test.mjs` remains green alongside the product-event tests.

**UI-disabled is not sufficient analytics authority.** Measurement must fail closed even if application code, automation, a stale listener, or a manipulated DOM dispatches an event.

---

# ACTIVE BLOCKER C — TALK-LANGUAGE OBSERVER LACKS A FLOW-LIFECYCLE LOCK

At the reviewed implementation, `createTalkLanguageObserver` validates values and deduplicates unchanged selections, but it has no `queueJoined` / selection-ownership state.

The DOM listener calls `talkLanguageEvents.selected(...)` whenever a `change` event fires. Current main's disabled control helps humans, but programmatic events can still reach the observer.

The analytics law should match the product law introduced by PR #255:

**Talk-language selection belongs to the current Four Doors attempt and closes when authoritative queue join closes selection.**

## Acceptance condition

Use one shared flow-scoped language observer or equivalent authority that:

- allows open/select/remembered observation while the current entrance attempt owns Talk-language selection;
- locks after authoritative queue join;
- rejects later open/select events in the same flow;
- resets automatically when `flow_attempt_id` rotates for a new entrance attempt;
- is driven from the same accepted queue authority used to lock intent changes.

Add hostile unit and browser tests. Do not rely only on the `disabled` HTML property.

---

# ACTIVE BLOCKER D — `build_id` IS AN UNBOUNDED STRING ESCAPE HATCH

The event schema is now intentionally strict, but `st_entrance_ready.build_id` still accepts any non-empty string and `captureEntranceReady` forwards any non-empty `options.buildId`.

That is inconsistent with the rest of the privacy-bounded layer: a future caller can place arbitrary free text into a property that passes schema validation.

No current baseline requirement needs arbitrary free text here.

## Acceptance condition

Preferred for this stage: remove `build_id` from the event schema and baseline implementation until there is an actual bounded release-identifier contract.

If Partner 02 retains it, first freeze a machine-generated bounded format and length, validate it strictly, prove its only source is trusted build metadata, and add injection tests. "Non-empty string" is not sufficient.

---

# ACTIVE BLOCKER E — RETRY / LATE-QUEUE REPLAY ATTRIBUTION NEEDS A HOSTILE PROOF

`queueEvents.requested()` stores the latest valid intent/language context. The server-authoritative `queue:status = queued` event carries a queue-attempt identifier, but the product-event layer deliberately does not export that identifier.

That privacy choice is good. However, it creates an integrity obligation internally.

A dangerous sequence to prove impossible or handle safely is:

1. request A is sent;
2. client times out / returns to Doors before its queued push is accepted locally;
3. user changes Door or Talk language and sends request B in the same still-live measurement flow or before the stale push is fully retired;
4. late `queue:status = queued` for A arrives;
5. analytics attributes the authoritative join to request B's latest stored context.

The current single-request tests do not establish this cannot happen.

## Acceptance condition

Add a hostile replay test using two distinct valid request contexts and a late queued status. The result must be one of:

- stale A is rejected by existing queue-attempt authority and no join is recorded for B; or
- internal correlation proves A and records A's bounded context without exposing the queue attempt ID to analytics; or
- the product lifecycle provably prevents B from existing until A can no longer be accepted, with a browser/protocol test demonstrating that invariant.

Do not solve this by sending `queue_attempt_id` to analytics.

The same family of test should cover a late/replayed `match_found` crossing a cancelled/rotated flow boundary.

---

# HARDENING — GENERIC SUCCESS EVENT BYPASS

The exported `productEvents` tracker can technically capture allowlisted success events directly, bypassing the higher-level queue/match observer's causal gates.

No current production caller reviewed in this pass is using that bypass for match/first-message success, so this is classified as hardening rather than a demonstrated current defect.

Before merge, add a static/repository test or API boundary making it difficult for application modules to call canonical success events directly. Prefer domain-specific observer methods over generic event capture for success stages.

---

# CONSERVATIVE RECOVERY VERDICT

Partner 02's new direction is correct:

**reconciliation restores product state; it must not invent analytics timestamps for events the browser did not actually observe/record in this flow.**

A recovered Conversation with a missing queue-join or match event should produce an incomplete measured funnel, not a fabricated complete one.

The frozen analysis spec already knows how to treat incomplete and anomalous journeys. Honest missing measurement is preferable to false precision.

---

# CI / EVIDENCE VERDICT

The newly added `Language Product Event Integrity` workflow is a useful dedicated gate because it:

- checks out an exact candidate SHA;
- proves the checked-out SHA;
- runs `node --test test/js/product_events*.mjs`;
- requires a clean tree after the test run.

At `c16e91c6...`, the exact checkout step passed and the focused test step failed. Therefore this is valid RED evidence, not final proof.

Final admission still requires, on a candidate based on fresh canonical main:

1. focused Language Product Event Integrity workflow GREEN;
2. all protected repository workflows GREEN;
3. maintained full precommit GREEN;
4. exact candidate SHA = tested SHA;
5. clean-tree proof;
6. event-integrity report committed before the final proof run;
7. independent Partner 01 exact-head review.

---

# STATUS MATRIX

- Tasks 1–8 implementation: **AT RISK / CORRECTIVE TDD ACTIVE**
- Focused monotonic-funnel tests: **RED at reviewed head**
- Round 1 semantic/property corrections: **mostly closed in principle**
- Fresh-main integration: **NOT DONE**
- PR #255 language-lifecycle compatibility: **NOT PROVEN**
- Talk-language measurement lifecycle lock: **NOT PROVEN**
- `build_id` privacy bound: **FAIL**
- retry/replay attribution: **NOT PROVEN**
- event-integrity report: **NOT PRESENT / NOT REVIEWED**
- Task 9 provider transport: **LOCKED / MUST NOT START**
- production baseline collection: **LOCKED**
- PR #249 merge: **NOT APPROVED**

---

# NEXT P02 EXECUTION ORDER

1. Turn the new recovery/monotonic-funnel RED tests GREEN without weakening them.
2. Remove or strictly bound `build_id`.
3. Add flow-scoped Talk-language authority lock tied to authoritative queue join.
4. Add the two-request late-queue replay test and late-match/cancellation replay test.
5. Integrate current canonical main `2f268b94...` or newer.
6. Run the PR #255 language queue-lock browser test plus all product-event tests.
7. Produce `event-integrity-report-v1.md` with one row per event.
8. Commit the report.
9. Run focused exact-head CI, protected workflows, full precommit, exact-SHA and clean-tree proof on that final report-bearing candidate.
10. Return the exact final candidate to Partner 01.

Do not start Task 9 while any item above is open.

## Round 2 law

A green event is not merely an event the server once emitted.

It is an event whose **current flow, prior stage, product ownership, replay state, value domain, and privacy surface** are all valid at the moment measurement accepts it.
