# StrangerTalks Language & Interface Team — Measurement Contract v0.3

## Purpose
This contract prevents Partner 01 and Partner 02 from declaring interface-language work successful by agreement, aesthetics, or implementation completion alone.

## Authority
- Owner: Manvith
- Instrumentation DRI: Partner 02 — Interface Language Architecture & Placement
- Independent measurement reviewer: Partner 01 — World Language & Meaning

## Current instrumentation verdict
StrangerTalks has backend/domain Telemetry around queue joins/leaves, matches, conversations, messages, failures, and latency. That is operational evidence, not an end-to-end entrance UX baseline.

The Language Team requires a client product-event layer before claiming an entrance baseline. The minimum event contract is:

- `st_entrance_ready`
- `st_intent_selected`
- `st_intent_changed`
- `st_talk_language_opened`
- `st_talk_language_selected`
- `st_queue_requested`
- authoritative queue-entry correlation
- authoritative match correlation
- first accepted human-message correlation
- `st_flow_cancelled` where explicitly measurable

## Privacy boundary
Do not collect message bodies, names, emails, profile text, exact location, or derived psychological/personality labels for this measurement layer.

Door and interaction-language values are contextual interaction inputs, not user identity attributes.

Use an ephemeral `flow_attempt_id` only to correlate the product-event journey. Do not use it as a high-cardinality Telemetry metric tag.

## Authority boundary
Client intent is not server success.

- `st_queue_requested` means only that the client attempted to begin matchmaking.
- queue admission must come from server-authoritative queue state.
- match creation must come from server-authoritative match state.
- first-message success must represent a server-accepted human message, not a send-button click.

Analytics failure must never block or alter the user journey.

## Measurement flow
`entrance_ready → intent_selected → talk_language_selected → queue_requested → queue_joined → match_created → first_message_accepted`

Measure median, P75, and P90 for:

1. entrance ready → first primary intent
2. primary intent → authoritative queue entry
3. queue entry → match
4. match → first accepted message
5. entrance ready → first accepted message

## Baseline rule
No quantitative entrance baseline exists until the event layer has passed integrity verification.

A descriptive baseline requires both:

- at least 7 complete calendar days; and
- at least 500 eligible entrance sessions.

Whichever takes longer controls.

If traffic is below that threshold, publish the actual N and classify the result `INSUFFICIENT QUANTITATIVE EVIDENCE`; do not call directional data validated.

## Qualitative comprehension rule
For an entrance-language round, use at least 24 first-time participants. Major Happening/Hangout taxonomy comparisons should target 30–36 first-time participants.

Teach-back answers are scored by two independent raters using a frozen rubric. Partner 01 and Partner 02 are not the sole judges of language they designed.

Target Cohen’s kappa ≥ 0.70. Below that threshold, the rubric is considered insufficiently objective and the round must be rescored after a new rubric is frozen.

## Four Door provisional answer key
- **Deep Talk** — serious, meaningful, or deeper conversation; advice is not required.
- **Vent** — express what is on one’s mind / be heard; solutions are not required.
- **Distract** — light human interaction for diversion or relief.
- **Advice** — seek another person’s input, perspective, suggestion, or guidance.

Score each teach-back explanation:

- 2 = correct core intention without material confusion
- 1 = partial/ambiguous or heavy overlap
- 0 = materially wrong, absent, inverted, or assigned to another Door

A Door passes a comprehension round only if score-2 comprehension is at least 80%, direct confusion with any single neighboring Door is below 20%, and no recurring critical misconception changes the expected experience.

## General entrance rubric
Score each dimension 0–2:

1. primary intention understood
2. expected human/social experience understood
3. interaction language understood as human-talk context rather than interface language
4. temporariness/identity promise understood without stronger false privacy guarantees

Participant-level pass: at least 6/8 and no critical misconception.

## Accountability
Every stage has one DRI, one reviewer, one target, one proof artifact, and one terminal status.

Allowed working statuses:

- `ON TRACK`
- `AT RISK`
- `MISSED`
- `BLOCKED`
- `COMPLETE`

A first `MISSED` requires cause, mitigation, and a corrected date.

Two consecutive `MISSED` completion targets on the same materially identical stage automatically trigger Owner Review before a third target is issued.

Owner Review may only choose:

- keep scope + rebuild plan
- reduce scope
- change sequence
- change/add capacity
- stop/reject workstream

A third attempt requires explicit Owner reauthorization after the second miss.

A blocker means progress is impossible without a concrete external dependency or owner decision. An inaccurate engineering estimate is a `MISSED`, not a blocker.

## Realistic execution schedule
- Sep 11–12: instrumentation audit and exact event/authority/privacy map
- Sep 13–16: minimum client event layer + authoritative correlation + tests
- Sep 17–18: event-integrity verification
- Sep 19: baseline-ready decision gate, or explicit blocker/miss with owner and next checkpoint
- Sep 19 onward: production baseline collection
- Sep 26: first mandatory quantitative baseline checkpoint
- Sep 27–Oct 2: first 24-person scored entrance-comprehension round, if recruitment is feasible

Deadlines should be aggressive enough to prevent drift but realistic enough that successful completion is the expected outcome, not the heroic outcome.

## Final law
No claim without a denominator.

No comprehension claim without an answer key.

No qualitative verdict without independent scoring.

No experiment without a predeclared stop rule.

No workstream without one DRI and a date.

Partner agreement generates hypotheses. It is not evidence.
