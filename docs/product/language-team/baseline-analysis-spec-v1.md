# StrangerTalks Language Team — Entrance Baseline Analysis Spec v1

Owner: Manvith  
Measurement reviewer: Partner 01  
Instrumentation DRI: Partner 02  
Governing issue: #247

## Why this exists

The baseline analysis rules are frozen **before** production data is visible so the Language Team cannot choose convenient denominators, time windows, exclusions, or funnel definitions after seeing the results.

This document does not authorize collection. Collection remains locked behind the event-integrity gate and analytics-destination privacy gate.

## Analysis unit

The primary unit is one valid `flow_attempt_id` beginning with one accepted `st_entrance_ready` event.

A valid baseline flow must:

- contain a syntactically valid non-empty `flow_attempt_id`;
- begin with `st_entrance_ready`;
- be production traffic, not synthetic/CI/staff verification traffic;
- have an explicit or deterministically trusted `test_traffic = false` classification;
- fall inside the frozen baseline collection window.

Do not use a participant/account/person ID as the primary baseline unit.

The baseline measures journeys, not identities.

## Calendar and collection window

Baseline calendar days are UTC calendar days (`00:00:00` through `23:59:59.999` UTC).

The first quantitative baseline checkpoint requires both:

- at least 7 **complete** UTC calendar days after production ingestion is approved; and
- at least 500 eligible entrance flows.

Whichever takes longer controls.

Partial launch day is not counted as one of the seven complete calendar days.

If the threshold has not been reached, publish the actual eligible N and label the result:

`INSUFFICIENT QUANTITATIVE EVIDENCE`

Do not extend or shorten the window because the numbers look good or bad.

## Frozen canonical funnel

The canonical ordered funnel is:

`st_entrance_ready`

→ `st_intent_selected`

→ `st_talk_language_selected`

→ `st_queue_requested`

→ `st_queue_joined`

→ `st_match_created`

→ `st_first_message_accepted`

`st_intent_changed`, `st_talk_language_opened`, and `st_flow_cancelled` are diagnostic/context events, not mandatory conversion steps.

A remembered valid talk language may legitimately make the chooser-open event absent. The canonical funnel therefore uses `st_talk_language_selected`, not `st_talk_language_opened`, as its language step.

## Authority rules in analysis

### Queue

`st_queue_requested` is client intent only.

It must never substitute for `st_queue_joined`.

Queue-admission conversion requires `st_queue_joined`.

### Match

Match conversion requires `st_match_created`.

No loading, waiting, UI transition, or queue-screen event may substitute for it.

### First message

Conversation activation requires `st_first_message_accepted`.

A composer submit, local optimistic render, or message-send attempt is not activation.

## De-duplication rules

For events defined as once-only per flow, use the earliest valid occurrence and separately report unexpected raw duplicates as an integrity defect.

Once-only events are:

- `st_entrance_ready`;
- `st_intent_selected`;
- `st_queue_joined` for the admitted attempt represented in the canonical funnel;
- `st_match_created`;
- `st_first_message_accepted`.

`st_intent_changed` may occur multiple times because genuine reversals are diagnostic behavior.

`st_queue_requested` may occur more than once if the product permits an explicit retry after failure. Do not silently collapse request retries when analyzing request reliability; for the canonical journey, use the first request that precedes the first authoritative `st_queue_joined`.

`st_flow_cancelled` may occur only for explicit measurable cancellation transitions; do not infer additional cancellations from missing later events.

## Sequence validity

For a flow to contribute to a transition-duration metric, the relevant events must occur in canonical order.

If timestamps imply an impossible sequence, for example:

- match before queue admission;
- first accepted message before match;
- queue admission before entrance;

then:

1. flag the flow as a sequence anomaly;
2. exclude it from the affected duration calculation;
3. keep it in the data-quality denominator;
4. do not silently reorder or repair it.

A sequence-anomaly rate above 1% of eligible flows blocks the label `validated baseline` until explained and corrected.

## Frozen primary conversion metrics

Every percentage must show both numerator and denominator.

### 1. Entrance → intent

Numerator: eligible flows with `st_intent_selected`.  
Denominator: all eligible entrance flows.

### 2. Entrance → queue request

Numerator: eligible flows with at least one valid `st_queue_requested`.  
Denominator: all eligible entrance flows.

### 3. Queue request → authoritative queue admission

Numerator: flows with `st_queue_joined`.  
Denominator: flows with at least one valid `st_queue_requested`.

### 4. Entrance → authoritative queue admission

Numerator: eligible flows with `st_queue_joined`.  
Denominator: all eligible entrance flows.

### 5. Queue admission → match

Numerator: flows with `st_match_created`.  
Denominator: flows with `st_queue_joined`.

### 6. Match → first accepted message

Numerator: flows with `st_first_message_accepted`.  
Denominator: flows with `st_match_created`.

### 7. Entrance → first accepted message

Numerator: eligible flows with `st_first_message_accepted`.  
Denominator: all eligible entrance flows.

This is the primary end-to-end activation conversion for the entrance language workstream.

## Frozen timing metrics

For completed valid transitions report:

- N;
- median (P50);
- P75;
- P90.

Required timing intervals:

1. `st_entrance_ready` → `st_intent_selected`;
2. `st_intent_selected` → `st_queue_joined`;
3. `st_queue_joined` → `st_match_created`;
4. `st_match_created` → `st_first_message_accepted`;
5. `st_entrance_ready` → `st_first_message_accepted`.

Durations are calculated only for flows that contain both valid boundary events in the correct order.

Do not report an incomplete flow as a zero duration.

Do not silently discard incomplete flows from conversion denominators merely because they lack an end timestamp.

If fewer than 50 valid completed transitions exist for a particular percentile distribution, report the N and descriptive values but mark that stage:

`LOW STAGE N — DO NOT INTERPRET AS STABLE`

## Intent-reversal diagnostics

Report:

- flows with zero `st_intent_changed` events;
- flows with exactly one change;
- flows with two or more changes;
- mean changes per flow;
- top bounded from-intent → to-intent transitions by count.

Do not interpret reversal as confusion by itself.

Reversal is observed behavior. A confusion claim requires independent qualitative evidence.

## Talk-language diagnostics

Report:

- remembered-language entrance share;
- newly selected talk-language share;
- changed talk-language share;
- direct chooser-open share;
- required-after-intent chooser-open share;
- valid language-selection rate after required-after-intent opening.

Do not report talk-language choice as ethnicity, nationality, identity, fluency, or demographic profile.

## Explicit cancellation diagnostics

Cancellation reporting is stage-based only.

Allowed reporting examples:

- explicit cancel before queue admission;
- explicit queue leave after admission;
- explicit flow cancellation after another measurable stage if the implementation defines it.

Report bounded reason codes only where the user explicitly caused a known action.

Never relabel inactivity, disconnect, timeout, or missing subsequent events as emotional/psychological reasons.

## Permitted descriptive breakdowns

The initial baseline may be descriptively broken down by:

- stable Four Door intent code;
- validated talk-language code;
- bounded device class;
- build/release identifier if implemented safely;
- remembered-talk-language true/false;
- direct vs required-after-intent language opening where applicable.

These are descriptive interaction/product contexts.

Do not convert them into persistent person segments.

## Forbidden post-hoc segmentation

The first baseline must not introduce unplanned breakdowns using:

- inferred personality;
- inferred mental/emotional state;
- exact location;
- identity/account history;
- relationship history;
- message content;
- arbitrary free text;
- demographic inference from language or Door choice.

Any later new segmentation question must be written down before looking at the corresponding segmented outcome.

## Data-quality report required with every baseline

Every baseline report must include:

- eligible entrance-flow N;
- test/synthetic flow count excluded;
- missing/invalid `flow_attempt_id` count;
- once-only raw duplicate count by event;
- sequence-anomaly count and rate;
- unknown custom-event count, if any;
- unexpected-property findings, if any;
- percentage of eligible flows reaching each canonical funnel stage.

Zero forbidden sensitive properties is required.

Any forbidden sensitive property finding invalidates production analytics approval until corrected and freshly verified.

Any required custom product event missing its `flow_attempt_id` is a schema defect and must be investigated rather than silently joined by another identifier.

## Missing events are not automatically abandonment reasons

If a flow has `st_entrance_ready` but no later event, the quantitative statement is only:

`no later measured canonical event was observed for this flow in the analysis window`.

Do not automatically call it:

- confused;
- uninterested;
- scared;
- bored;
- privacy-concerned;
- bounced because of copy;
- abandoned because of language placement.

Causal explanations require separate evidence.

## Baseline comparison rule

The first production window is descriptive baseline, not proof that current copy/design is good.

Future variants must be compared against a predeclared hypothesis and stop rule.

Do not use the baseline as an A/B control retrospectively unless the later experiment design explicitly supports that comparison.

## Mandatory baseline report shell

```text
STRANGERTALKS LANGUAGE TEAM — ENTRANCE BASELINE

COLLECTION WINDOW:
COMPLETE UTC DAYS:
ELIGIBLE ENTRANCE FLOWS:
TEST FLOWS EXCLUDED:

DESTINATION PRIVACY STATUS:
EVENT-INTEGRITY STATUS:
DATA-QUALITY STATUS:

CANONICAL FUNNEL:
entrance N / 100%
intent N / % of entrance
language selected N / % of entrance
queue requested N / % of entrance
queue joined N / % of request and % of entrance
match N / % of joined and % of entrance
first accepted message N / % of match and % of entrance

TIMINGS:
entrance → intent: N / P50 / P75 / P90
intent → queue joined: N / P50 / P75 / P90
queue joined → match: N / P50 / P75 / P90
match → first accepted message: N / P50 / P75 / P90
entrance → first accepted message: N / P50 / P75 / P90

INTENT REVERSALS:
TALK-LANGUAGE DIAGNOSTICS:
EXPLICIT CANCELLATIONS:

DUPLICATE COUNTS:
SEQUENCE ANOMALIES:
SCHEMA/PRIVACY ANOMALIES:

EVIDENCE CLASSIFICATION:
VALIDATED DESCRIPTIVE BASELINE /
INSUFFICIENT QUANTITATIVE EVIDENCE /
INVALID — DATA INTEGRITY OR PRIVACY GATE FAILURE
```

## Baseline unlock state

At the time this spec was frozen:

- event-integrity review: `PENDING`;
- analytics destination: `NOT APPROVED`;
- production baseline collection: `LOCKED`.

These states must be refreshed from current evidence before any data collection begins.
