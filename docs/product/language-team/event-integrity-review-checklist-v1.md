# StrangerTalks Language Team — Event Integrity Review Checklist v1

Owner: Manvith  
Implementation DRI: Partner 02  
Independent reviewer: Partner 01  
Governing issue: #247

## Purpose

This checklist prevents Partner 01 from improvising acceptance criteria after Partner 02 finishes implementation.

The implementation must be judged against frozen positive, negative, authority, duplicate, privacy, and failure-isolation evidence.

A passing implementation is not one that merely emits events. It is one where each event means exactly what the measurement contract claims it means.

## Review event names

The following exact names are frozen for the issue #247 product-event layer unless Partner 02 documents a technically necessary equivalent before integration review:

- `st_entrance_ready`
- `st_intent_selected`
- `st_intent_changed`
- `st_talk_language_opened`
- `st_talk_language_selected`
- `st_queue_requested`
- `st_queue_joined`
- `st_match_created`
- `st_first_message_accepted`
- `st_flow_cancelled`

`st_queue_requested` and `st_queue_joined` are intentionally separate.

## Global context law

`flow_attempt_id` is the correlation key for this measurement journey.

It must be:

- freshly generated for a genuinely new entrance attempt;
- opaque;
- ephemeral;
- unavailable as a personality/account label;
- absent from operational Telemetry metric tags;
- safe to rotate/reset without breaking product behavior.

`test_traffic` must be present or otherwise deterministically derivable for controlled/CI traffic without adding personal identity.

## Per-event review matrix

| Event | Positive trigger required | Must NOT trigger from | Authority | Duplicate rule | Minimum privacy expectation |
|---|---|---|---|---|---|
| `st_entrance_ready` | Primary entrance is actually usable/interactable | HTML parse alone, repeated reconciliation callback | Client readiness boundary | Once per entrance flow | No DOM dump or identity |
| `st_intent_selected` | First valid primary Door/intent selection | Hover, focus, same-intent repeat | Human client action | One first-selection event per current flow before reset | Stable intent code only |
| `st_intent_changed` | Previously selected intent replaced with a different valid intent before authoritative queue admission | Same Door clicked again; passive UI rerender | Human client action | One per genuine change | Bounded from/to intent codes only |
| `st_talk_language_opened` | Chooser invoked directly or surfaced because language is required after intent | Unrelated header render or passive state hydration | Human/UI interaction boundary | No duplicate from one open transition | Bounded trigger only |
| `st_talk_language_selected` | Valid interaction language accepted for pending/next interaction | Invalid/free-form value; arbitrary DOM value | Validated client contract | No duplicate for unchanged no-op selection unless product semantics justify it | Validated language code + bounded source only |
| `st_queue_requested` | Canonical outbound `queue:join` attempt is made | Showing queue UI, intent click alone | Client request boundary | One per actual outbound request attempt | Intent/language context only |
| `st_queue_joined` | Server-confirmed `queue:status` reports `queued` for current authoritative attempt | Request send, queue screen, stale/replayed status | Server-authoritative queue state | Once per authoritative queue attempt/flow correlation | No unnecessary persistent identifier |
| `st_match_created` | Current flow receives canonical server-authoritative match state | Client expectation, loading state, queue display | Server-authoritative match state | Once per flow despite duplicate/recovery notifications | Match ID omitted by default |
| `st_first_message_accepted` | First human message operation receives server acceptance | Submit click, local render, rejected send, timeout | Server acceptance boundary | Once per flow; retries cannot double count | No content/message ID by default |
| `st_flow_cancelled` | Explicit measurable user cancellation/leave | Inactivity, timeout interpreted as psychology, browser loss guessed as intent | Explicit user action | One per actual cancellation transition | Bounded stage/reason code only |

## Mandatory positive proofs

Partner 02 must provide focused test evidence for every implemented event.

For each event the evidence must identify:

1. exact test file;
2. exact command;
3. passing assertion relevant to that event;
4. production hook/file under test;
5. authoritative boundary where relevant.

A broad `mix precommit` pass is necessary at final integration but does not replace focused semantic tests.

## Mandatory negative proofs

The reviewer must reject the implementation if any of the following can occur without a failing test.

### Payload injection

Attempt to capture an approved event with extra fields resembling:

- `content`;
- `message_body`;
- `draft`;
- `email`;
- `name`;
- `profile`;
- `latitude`;
- `longitude`;
- `location`;
- `token`;
- `participant_token`;
- arbitrary nested object;
- arbitrary DOM text.

The product-event core must deterministically drop/reject unapproved properties and must not forward them to the sink.

### Unknown event

An unknown event name must not become an arbitrary provider event merely because a caller supplies a string.

### Sink synchronous failure

A sink that throws synchronously must not alter the product operation.

### Sink asynchronous failure

A sink that rejects asynchronously must not create an unhandled path that breaks the product operation.

### No sink

A no-op/missing transport must leave the product usable.

## Flow-boundary attack cases

### Entrance duplication

Repeated initialization/reconciliation must not emit multiple `st_entrance_ready` events for one entrance attempt.

### Intent no-op

Clicking the same selected Door twice must not manufacture `st_intent_changed`.

### Language invalid value

A manipulated/free-form language value outside the validated product contract must not be emitted.

### Queue request failure

A rejected/failed outbound queue request may have `st_queue_requested`, but it must not result in `st_queue_joined`.

### Queue replay

Repeated current `queue:status = queued` messages must not inflate queue admission.

### Stale queue status

A queued/matched status belonging to a stale queue attempt must not inflate the current flow.

### Match replay/recovery

Duplicate `match_found`, matched reconciliation, or recovery paths must not produce multiple `st_match_created` events for one flow.

### Message rejection

Send-button interaction followed by server rejection must not emit `st_first_message_accepted`.

### Message timeout

Timeout must not emit first-message success.

### Message retry

A retry that eventually receives one accepted result must produce exactly one `st_first_message_accepted` for the flow.

### Later messages

Second and later accepted messages must not emit additional first-message events.

### Cancellation inference

Do not emit a cancellation reason that was inferred from inactivity, delay, failure, or presumed emotional state.

## Existing regression authorities that must remain green

At minimum preserve relevant behavior proven by:

- `test/js/door_click_flow_test.mjs`
- `test/js/arrival_first_minute_browser_test.mjs`
- `test/js/arrival_accessibility_browser_test.mjs`
- `test/js/browser_e2e_test.mjs`
- `test/js/f01_app_shell_browser_test.mjs`
- relevant canonical message reliability/retry tests touched by Task 7

Instrumentation does not get permission to weaken product tests.

## Provider-independent acceptance gate

Tasks 1–8 may be judged `COMPLETE` at the code-semantic level only if:

- every required event implemented in that phase has focused positive proof;
- every applicable negative/attack case above has proof;
- existing relevant product regressions remain green;
- analytics failure is proven observational/non-fatal;
- provider-specific live ingestion remains absent while the destination privacy gate is `NOT APPROVED`.

This does not authorize production baseline collection.

## Controlled-ingestion review

When a provider destination later reaches controlled-test approval, Partner 01 must compare **actual received properties** against the core allowlist.

For every event, record:

- expected properties;
- actual application-supplied properties;
- provider/system-added properties;
- unexpected properties;
- test-traffic filter result;
- reviewer verdict.

Any unexpected sensitive property is an automatic `FAIL` until removed and re-proven with fresh synthetic events.

## Baseline unlock condition

Production baseline collection remains locked until both gates pass:

1. event-integrity review: `PASS`;
2. analytics destination: `APPROVED FOR PRODUCTION INGESTION`.

Passing only one gate is insufficient.

## Review report format

Partner 01 must publish the final review using this structure:

```text
LANGUAGE TEAM — P01 EVENT INTEGRITY VERDICT

IMPLEMENTATION BRANCH:
IMPLEMENTATION HEAD:
CANONICAL BASE/ANCESTRY:

EVENT ROWS REVIEWED:

POSITIVE PROOFS:
NEGATIVE PROOFS:
AUTHORITY PROOFS:
DUPLICATE/RECONNECT PROOFS:
PRIVACY PROOFS:
FAILURE-ISOLATION PROOFS:
REGRESSION COMMANDS:
REGRESSION RESULTS:

DESTINATION PRIVACY STATUS:

EVENT-INTEGRITY VERDICT:
PASS / FAIL

BASELINE COLLECTION:
LOCKED / UNLOCKED

DEFECTS:
REQUIRED CORRECTIONS:
```

## Present reviewer state

No Partner 02 implementation packet has yet been independently reviewed against this checklist.

Therefore:

- event-integrity verdict: `PENDING`;
- production analytics destination: `NOT APPROVED`;
- baseline collection: `LOCKED`.
