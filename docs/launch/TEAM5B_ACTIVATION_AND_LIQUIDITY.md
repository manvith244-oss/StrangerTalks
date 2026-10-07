# Team 5B — Activation Funnel, Measurement, and Match Liquidity
Date: 2026-10-08. Status: PROPOSAL / NOT AUTHORIZED FOR TELEMETRY DEPLOYMENT.
Repository baseline: main@5058fc5c27045c008e1f1f8d66eb3d58aba2b00e.
Owner: Team 5B (growth operations). Engineering owners: Team 1 (realtime), Team 2 (privacy approval), Team 4 (collector/infra).

## 1. Frozen operating boundaries

- Human, anonymous, one-to-one text conversation is the first pilot surface. Never simulate human participants or display invented occupancy.
- Four Doors: Deep Talk / SOMETHING_REAL; Vent / JUST_TALK; Distract / KEEP_IT_LIGHT; Advice / EXPLORE.
- Exact-Door first; approved cross-Door only once **both** people waited at least 15 seconds; never override safety veto, fairness, or queue authority.
- Approved cross-Door edges: Vent–Advice, Vent–Distract, Distract–Advice, Advice–Deep Talk. Deep Talk–Vent and Deep Talk–Distract are not approved.
- No Four Doors language prerequisite. Language-related event schemas in product_events.mjs are legacy analysis artifacts, not permission to restore the picker.
- No message content, audio, IP-based identities, browser fingerprinting, stable participant profiles, hidden emotional inference, or cross-session analytic identity.
- Real-user validation, collector deployment, and production changes require separate founder approval and Team 2 safety/privacy approval.

## 2. Evidence and limitations

Observed directly in source at the baseline SHA:

- priv/static/assets/product_events.mjs: an allowlisted flow tracker emits st_entrance_ready, st_intent_selected, st_intent_changed, st_queue_requested, st_queue_joined, st_match_created, st_first_message_accepted and st_flow_cancelled. The tracker also retains legacy st_talk_language_* schemas.
- A flow_attempt_id is randomly generated and reset; it is an ephemeral attempt ID, not an approved cross-session person ID. Test traffic is annotated test_traffic only if the caller sets the flag.
- runtimeSink reads globalThis.__strangerTalksProductEventSink. When no callback exists, runtimeSink resolves without a collector. createProductEventTracker.deliver returns true for any resolved sink. Therefore callback success is **not** evidence of accepted, persisted, or queryable analytics.
- GitHub repository code search found this global sink name only in product_events.mjs and test/js/product_events_contract_test.mjs. No production collector registration was established.
- The existing contract test asserts funnel order and callback acknowledgments. It does **not** establish production transport, durability, test filtering, or privacy retention.
- MatchmakingEngine stores queue_attempt_id in ephemeral QueueState; emits [:queue,:joined] once on actual insertion and [:queue,:left] on match/cancel/timeout. Match persistence is atomic and emits [:match,:created] after durable commit. Repeated same-Door joins return existing queue attempt without another joined emission.
- matches.queue_duration_seconds is based on the EARLIEST of two participants' entry times. It is **not** two independent participant wait durations and cannot prove both matched within five minutes.
- V1Metrics derives DB aggregates for Match, Conversation, Relationship, Report rows. Its conversations_started metric counts Conversation rows created, not confirmed conversational engagement.
- Runtime aggregate collection, server-side first-message acceptance, durable 5-minute match percentages, and unmatched/retry/disconnect coverage remain NOT INSTRUMENTED or NOT VERIFIED as identified below.

## 3. Canonical pilot funnel and definitions

Unit for the primary metric: one admitted **human queue attempt**, not a session cookie or a person observed across days. Admitted = authoritative successful insertion into the queue (not a click or optimistic UI). Each new attempt is counted once; duplicate same-Door join of the existing attempt contributes zero extra admits. A returning person entering a new session is a new attempt; cross-day unique users cannot be inferred.

| Stage | Candidate signal and source | Numerator / denominator | State on 2026-10-08 |
| --- | --- | --- | --- |
| Arrive | st_entrance_ready, client | Entrance attempts / page landings; page-landings not reliably counted | NOT INSTRUMENTED (no collector) |
| Understand | Small consent-based comprehension question, answered after visit; no passive psychological inference | Correct unaided explanations / consenting respondents | RESEARCH ONLY / no real-user data |
| Choose Door | st_intent_selected, client | Initial Door selections / entrances | NOT INSTRUMENTED |
| Request join | st_queue_requested, client | Requests / chosen Door | NOT INSTRUMENTED |
| Admitted | authoritative QueueState insertion, [:queue,:joined] | New valid admissions / acknowledged join requests | Server signal exists; COLLECTION NOT VERIFIED |
| Find person | committed Match with both queue attempts admitted | Matched admitted attempts (2 per Match) / admitted attempts in same session | Matches durable; full rate NOT INSTRUMENTED |
| Matched <= 5 minutes | both participants' individual monotonic residence times at committed match | Matched attempts with own wait <= 300 s / all admitted attempts (same session) | NOT INSTRUMENTED; do not use match.queue_duration_seconds as both waits |
| Converse | authoritative ACTIVE/start transition or first server-accepted send, separately distinguished from PENDING Conversation row | Started conversations / committed matches | NOT VERIFIED: V1 aggregate counts records, not true starts |
| First accepted human message | server returns successful send acknowledgment, accepted once per conversation; browser st_first_message_accepted is non-durable | Conversations with >=1 accepted human send / matches or started conversations | Client event exists; DURABLE METRIC NOT INSTRUMENTED |
| End | Conversation ended_at and known ending_type | Ended conversations / genuinely started conversations | Partial via V1Metrics; denominator needs start proof |
| Return voluntarily | consent-based survey question or explicitly separate later session; do not link identities to answer | Self-reported willingness/return among consenting respondents; no cross-session unique conversion | NOT INSTRUMENTED; survey estimates only |

Measurement cautions:
- Count successful match as committed, authorized Match, not a browser 'match_found' animation.
- Count a successful conversation START as a server-authoritative engaged transition, not creation of a PENDING Conversation.
- 'First accepted message' means server accepted a real human send. A failed/disconnected send does not count. Do not record the text or recipient.
- Voluntary abandonment: authoritative queue:leave with explicit user leave; technical loss: disconnect, transport failure or unclassified loss separately. Do not label every unmatched disappearance a preference.
- Retry: same attempt not double counted; new accepted insertion gets a new attempt and belongs to its arrival session.
- Unknown outcome on crash is NOT INSTRUMENTED / COVERAGE UNKNOWN, never silently counted as voluntary or 0.
- Stage ratios should use matched cohorts and at-risk windows; do not mix creation timestamps across sessions. Document right-censored late admits and report both fully observed and incomplete cohorts.
- For pilot scorecards, record denominator size, raw counts, percentage, and coverage. Do not claim confidence from small n.

## 4. Prefer aggregate Option A before introducing Option B

**Option A — existing read-only V1Metrics (preferred wherever adequate):**
- Available: matches_created; same_door_matches; cross_door_matches; matched-only average queue wait; Conversation row creation; natural/technical endings; failures; mutual-consent Bonds; submitted Reports; Block-terminated conversations.
- Request restricted aggregate snapshots via existing internal 'mix strangertalks.intelligence [hours]' once an authorized environment and operator exist. Data window <=31 days.
- No new collector or tracking history needed for these measures.
- Limitations: cannot count queue admits without Match, unmatched exits, per-participant wait percentiles, matched-under-five-minutes among ALL admits, first accepted send, or true repeat attendance.

**Option B — minimal additional session aggregate counters, SPECIFICATION ONLY:**
- Owning service: Team 1 queue/Conversation authority with Team 4 operational aggregate sink. Team 2 MUST approve before implementation or emission into storage.
- At queue insertion, increment admitted_attempts once; at matched Match transaction completion, increment matched_attempts by 2; compute each queued participant's monotonic age separately and increment matched_within_300s for each qualifying attempt.
- At authoritative queue removal, categorize matched, explicit_exit, timeout, or unknown/lost on service restart; distinguish duplicate join/cancel idempotence and stale attempts. Count process_restart_loss where reliably known, otherwise record data coverage invalid.
- On first truly accepted human message in a Conversation, increment first_message_conversations once at the authoritative acceptance boundary. This is not a text event.
- At terminal Conversation status transition, aggregate natural_end, block_end, report_related, failed and disconnect with existing V1Metrics if equivalent; avoid redundant counters.
- Per named pilot window emit only bounded non-identifying counts and histogram bins e.g. 0–15 s / 16–60 s / 61–180 s / 181–300 s / >300 s, with explicit 'not observed' bucket. Door-specific breakdowns stay restricted, suppressed for cells <5, and never public.
- No persisted UUID, browser flow_attempt_id, participant_id, Match ID, Conversation ID, token, IP, location, user-agent string, content, message text or report payload in the aggregate sink.
- In-memory identifiers may be used transiently to ensure once-only processing but must not become an analytic trail. Define process-restart behavior and how counters reconcile with authoritative durable Match/Conversation rows without copying identities.
- UTC half-open session windows tied to an operator-configured session label; no free-text label controlled by users. Only approve storing finalized window-level aggregates with an explicit short retention period documented by Team 2; TTL not yet approved.
- Test traffic: isolate staging from production, use test-only session labels validated server-side; do not trust client test_traffic flag for production exclusion. A human-confirmed test attendance sheet cannot be treated as complete server test filtering.
- No growth tracking cookies or client collector are recommended for V1. Consent-based usability results must be separated from transport logs and app identities.
- Counts are only 'AVAILABLE' after an exact SHA integrated test demonstrates emission, delivery, query, retention, and stage reconciliation from two browsers; test that sink failures cannot be reported as collection success.

## 5. Exact acceptance tests for engineering owner (not executed by Team 5B)

Run at the exact candidate SHA:
1. node --test test/js/product_events_contract_test.mjs (existing contract; necessary but not collector proof).
2. Add automated contract that unregistered runtime sink reports **no collection acknowledgment**; current behavior is expected to FAIL this future requirement.
3. Add server integration with two fresh consenting test clients, same Door: exactly 2 queue admits, 1 Match, 2 matched attempts, 0 duplication after duplicate joins and repeated server broadcasts.
4. Exercise two approved cross-Door entries before 15 s, then at >=15 s for BOTH attempts; verify no early Match; verify forbidden pairs never match even after 15 s.
5. Blocked participants cannot match; safety veto unchanged.
6. One matched pair: confirm per-participant wait durations (different entry offsets). Verify earliest-entry match.queue_duration_seconds cannot be substituted for both.
7. Cancel after join; stale cancel after match; retry; server disconnect, process restart and reconciliation; validate no phantom Match and honest loss/coverage category.
8. First accepted send increments once; rejected push, duplicate push, replay and reconnect increment zero extras. No payload/content or identifying fields in aggregates.
9. Isolate synthetic staging traffic; prove prod aggregate sink rejects testing labels/clients even if client-controlled test_traffic=false.
10. Shut collector/storage off; display NOT INSTRUMENTED or STALE rather than 0. Restore; check no silent replay double-count.
11. Review aggregate TTL, authorization, query guard, low-cell suppression and log redaction with Team 2.
12. After approval, run two-browser genuine HTTP/WSS flow with Network tools and read-only aggregate query, recording exact SHA, timestamp and result.

Acceptance gates: zero phantom matches, invariant-safe recovery, no content/identity leakage, real durable/reconcilable measures, and Team 2 sign-off. Until then five-minute matched rate and message-accepted metrics remain NOT INSTRUMENTED.

## 6. Beta cohort operating model

**Assumptions only, not verified attendance:**
- Invite 40–60 consenting adults. Seek 12–20 real confirmed arrivals per supervised window, never guarantee an exact number.
- Start with two small text Conversation windows; Hangouts excluded.
- Suggested timezone anchors (Oct 18, 2026; confirm DST before each invite):
  - 20:30 IST = 15:00 UTC = 16:00 London (BST) = 17:00 Paris (CEST) = 11:00 New York (EDT).
  - 07:00 IST = 01:30 UTC = previous calendar day 21:30 New York (EDT) = previous day 18:30 Los Angeles (PDT). A Sunday morning IST session is a Saturday evening US session.
- These are candidate anchors only. Require actual volunteer and moderator coverage before publishing. Do not book both if operational coverage is missing.

**Illustrative concentration model, not measured product performance:**
Assume independent Poisson arrivals, equally chosen Doors, no users initially queued, no safety blocks and no cross-Door help. A new participant's probability of at least one later same-Door arrival within five minutes is approximately 1 - exp(-5*N/(4*T)), where N is arrivals across T minutes.
- N=12 across T=30 minutes -> approximately 39%.
- N=20 across T=30 minutes -> approximately 57%.
- N=12 concentrated across T=10 minutes -> approximately 78%.
- N=20 concentrated across T=10 minutes -> approximately 92%.
This is not the cohort's eventual match rate; it ignores previous waiters, pair consumption, arrival-edge effects and safety constraints. Use it ONLY to explain why synchronized arrivals matter.
A different deterministic observation: with 12 people spread evenly as 3 in each Door, exact-Door-only matching can pair eight and leave four unmatched (67%). With 20 spread evenly as five each, exact-Door-only matching pairs 16 (80%). Real cross-Door eligibility may improve these outcomes; do not change matching rules to hit a growth goal.

**Practical session plan:**
T-72h send invitation after approval and collect explicit adult eligibility + consent + availability via restricted opt-in process. T-24h reconfirm accepted window, accessible device/browser and backup access. T-2h operator checks Team 1–4 evidence, participant confirmations, safety reviewer and communications channel. T-15m confirm support coverage; do not collect chat bodies. At T-0 use a single short joining interval (recommended 10 minutes, adjustable) and announce that matching is not guaranteed. At T+5/10m review queue aggregate and provide truthful wait text; offer voluntary leave/cancel. At session end record only aggregate measures and opt-in responses.

**Cancellation/pause:** Cancel if release gates are red, real operator coverage is absent, infrastructure/DB or WSS unstable, abuse handling unavailable, or participant arrival confirmations are below the founder-approved minimum. Do not fill queues with bots. Send cancellation without attributing the reason to participants.

**Expansion:** Only propose a third slot after >=2 sessions across both proposed slots demonstrate reliable admission/matching, sufficient real attendance and safe support coverage. Do not expand based on registrations alone. Require >=70% admitted matched within 5 minutes as a *pilot planning target*, with denominator, complete observation coverage and uncertainty; this is not a guaranteed SLA.

## 7. Launch liquidity dashboard — restricted operator view

The dashboard is a proposed read-only operator worksheet. Do not expose granular Door/time cells publicly.

| Field | Ground truth | Today | Safeguard |
| --- | --- | --- | --- |
| Confirmed consenting invitees | restricted invitation tracker | NOT COLLECTED | separate from app identity; limited operator access |
| Admitted queue attempts | authoritative queue insertion | NOT INSTRUMENTED durably | no user IDs in output |
| Matched participants | 2 x committed Match in window | PARTIAL: durable match rows; session attribution needs proof | guard session overlap |
| Unmatched exits | authoritative queue removal without Match | NOT INSTRUMENTED durably | distinguish abandon/disconnect/unknown |
| Individual wait p50/p90 | each queue attempt's wait at exit/match | NOT INSTRUMENTED | bin/suppress small cohorts |
| Matched within 300s | each matched person's wait | NOT INSTRUMENTED | numerator <= admitted, complete censoring |
| True successful Conversation starts | authoritative start, not PENDING row | NOT VERIFIED | show pending/started separately |
| First human message accepted | authoritative first accepted send | NOT INSTRUMENTED | content never captured |
| Report / Block aggregate | approved safety records, V1Metrics | PARTIAL: Reports and Block-ended Conversations | restricted only; low-cell suppression |
| Reconnection / restoration failures | Team 1 verified lifecycle metric | NOT INSTRUMENTED for pilot | distinguish from voluntary leave |
| Conversation terminal endings | V1Metrics ended_at | AVAILABLE in source; production query NOT VERIFIED | do not call all 'successful' |
| Telemetry freshness and coverage | last verified exact-SHA snapshot | NOT VERIFIED | stale/unknown is not zero |

Operator should record: SHA, environment, session UTC start/end, data source, sample size, observation coverage, collector availability, suppression applied, metrics and interpretation. Founder sees coarse aggregate summary; only designated safety operator sees protected incident records. Public users should see none of the live Door-specific dashboard or competitor-like 'N online' indicators.

## 8. Release decision for this document

**NO-GO for public beta at this checkpoint.** No real-user admissions, production telemetry or cross-team release gates have been verified; production is behind main and a later deployment failed. The documentation, plan and ready-to-copy operator templates can be reviewed now. Engineering changes and cohort invitations: READY — AWAITING AUTHORIZATION.

Source anchors: docs/STRANGERTALKS_CURRENT_CONTEXT.md, docs/PRODUCTION_OPERATIONS.md, docs/TEAM4_PRIVACY_STORAGE_MAP.md, priv/static/assets/conversation_catalog.mjs, priv/static/assets/product_events.mjs, lib/strangertalks_new/intelligence/v1_metrics.ex, lib/strangertalks_new/matchmaking/queue_engine/matchmaking_engine.ex, test/js/product_events_contract_test.mjs.
