# Team 8 — Intelligence, Learning & Analytics V1

Status: canonical Team 8 V1 boundary for the release-prep line.

## Decision

StrangerTalks V1 needs **zero formal autonomous intelligence Agents**.

The V1 intelligence loop is deliberately small:

```text
canonical product outcomes
        ↓
read-only bounded aggregate queries
        ↓
privacy-safe metric snapshot
        ↓
deterministic recommendation rules
        ↓
Command / human review
        ↓
separate approved product change
```

There is no raw analytics event warehouse, participant intelligence profile, self-modifying policy loop, learning worker, model-based Team 8 learner, vector store, or analytics dashboard requirement in V1.

## Runtime owners

- `StrangertalksNew.Telemetry` remains the bounded operational telemetry primitive. It strips IDs/content/secrets and is non-authoritative.
- `StrangertalksNew.Intelligence.V1Metrics` is the Team 8 read-only aggregate owner.
- `StrangertalksNew.Intelligence.V1Recommendations` is the Team 8 deterministic recommendation owner.
- `mix strangertalks.intelligence [hours]` is the operator entry point. The window is capped at 31 days.
- `AnalyticsRecord` and `LearningRecord` remain legacy schemas only. New writes through their contexts are disabled in V1.
- The historical model-based `mix strangertalks.agents learning` path is superseded by the deterministic Team 8 report.

## Signal allowlist

V1 Team 8 aggregate queries may read only the following canonical fields for the current report:

| Source | Fields read | Purpose | Identity handling |
| --- | --- | --- | --- |
| Match | `created_at`, `participant_a_door_type`, `participant_b_door_type`, `queue_duration_seconds` | throughput, same/cross-Door counts, successful-match wait | IDs are used only by the database as row keys; never selected into output |
| Conversation | `created_at`, `ended_at`, `ending_type`, `conversation_status` | creation, natural end, disconnect, failed, block-terminal counts | no participant/message/content fields selected |
| Relationship | `created_at` | count explicit mutual continuation | no participant, Memory, note, summary or strength fields selected |
| Report | `created_at` | count aggregate safety-boundary use | no reporter, target, message, evidence/context or media selected |
| Telemetry | bounded numeric measurements + low-cardinality enum metadata already accepted by `Telemetry` | live observability | IDs/content/secrets stripped before emission |

The report itself contains only aggregate counts/averages, an ISO reporting window, and code schema versions.

## Signal denylist

Team 8 V1 must not ingest or emit:

- raw message text, reply snippets or quoted text;
- Voice Note audio/binaries/transcripts;
- Voice Call audio;
- Video or Screen Share frames;
- private Memory, Reflection, note or summary text;
- report evidence / `reporter_context`;
- participant, Conversation, Match, Message, Report, Memory or account identifiers in analytics output;
- Google identity, email, name, photo, OAuth/session/token/cookie data;
- IP-derived identity, user-agent fingerprinting or stable device identity;
- keystroke cadence / latency variance;
- readiness, emotion, personality, vulnerability or psychological labels;
- biometric, voice-identity or face-identity data.

## Legacy schema disposition

### `AnalyticsRecord`

The historical schema is not the V1 analytics pipeline. It contains broad fields such as satisfaction/trust/quality composites and `*_agent_accuracy` values that do not have defensible current measurement contracts. Treating database defaults as real measurements would manufacture data.

V1 disposition: **LEGACY / READ-ONLY COMPATIBILITY**. New context writes are disabled. Existing rows may be read only for migration/forensic work. The V1 report does not consume them.

### `LearningRecord`

The historical schema supports participant-linked readiness and keystroke-variance records. Those fields are outside the V1 privacy boundary and are not needed to operate StrangerTalks.

V1 disposition: **LEGACY / READ-ONLY COMPATIBILITY**. New context writes are disabled. V1 does not generate LearningRecords.

## `learning_version`

The repository contains `learning_version` fields on Match, Conversation and Relationship records, but the current V1 architecture has no learned production behavior and no frozen historical meaning for those fields.

Therefore Team 8 will **not invent a value**. V1 leaves `learning_version` unset (`nil`).

Team 8 recommendations instead carry `logic_version = team8-v1-recommendations-1`. That value means only: “which deterministic recommendation code produced this evidence packet.” It does not mutate or backfill the domain `learning_version` fields.

If a future approved learned/model policy actually informs production behavior, Command must first freeze what `learning_version` means, who writes it, when it changes, rollback semantics, and how it is audited.

## Metric dictionary

The executable dictionary lives in `V1Metrics.metric_dictionary/0`; these are the V1 metrics:

| Metric | Definition | Interpretation | Non-goal |
| --- | --- | --- | --- |
| `matches_created` | canonical Match rows created in window | matching throughput | not Conversation quality |
| `same_door_matches` | Match entry Doors equal | exact-Door path usage | not personal compatibility |
| `cross_door_matches` | Match entry Doors differ | approved scarcity path usage | cannot auto-change cross-Door policy |
| `average_queue_time_seconds` | mean persisted queue duration for successful Matches | successful-match wait | excludes unmatched attempts; not happiness |
| `conversations_started` | canonical Conversation rows created | creation reliability/throughput | not meaningfulness |
| `natural_ends` | Conversations ending `NATURAL_END` | non-safety terminal outcome | not automatically positive |
| `technical_disconnects` | Conversations ending `DISCONNECT` | technical-survival signal | not participant rejection |
| `failed_conversations` | terminal rows with status `FAILED` | reliability failure | no automatic product change |
| `voluntary_relationships_created` | Relationship rows created after domain mutual-consent gate | explicit continuation signal | not relationship-strength profiling |
| `reports_submitted` | canonical Report rows created | aggregate report-boundary use | no evidence exposure or automatic punishment |
| `block_terminated_conversations` | Conversations ending `BLOCK` | in-Conversation block boundary use | not every BoundaryBlock from every surface |

No composite “Conversation Quality”, “trust”, “satisfaction”, “connection success”, or “platform health” score exists in Team 8 V1.

## System health versus human outcomes

System health metrics: match creation, queue duration, Conversation creation, disconnects and failures.

Human-outcome signals: explicit mutual Relationship creation, Report use and Block-terminal outcomes.

A system-health success must never be promoted into an emotional-quality claim. Duration/message count/technical completion are not proxies for a worthwhile Conversation.

## Deduplication and ordering

Team 8 does not create an additional event stream, so it avoids a second retry/dedup problem. Aggregate truth is derived from canonical durable rows after the owning domain has resolved its own idempotency and state transitions.

Examples:

- a canonical Report deduplication key prevents one report retry from becoming two Report rows;
- one Match row is counted once no matter how many times an operator runs the report;
- terminal Conversation metrics are selected from durable `ended_at` + terminal fields, so a later report run observes the final canonical row rather than replay order.

If a future raw analytics event stream is proposed, stable event identity and explicit ordering rules become mandatory before adoption.

## Failure behavior

Analytics and recommendations are observational.

- Report query failure fails only the operator report; it does not roll back or block matchmaking, messaging, safety, media, continuity or Conversation actions.
- Recommendation generation is pure/deterministic over a snapshot and performs no writes.
- There is no retrying learning worker and therefore no retry storm or half-applied policy state.
- Legacy AnalyticsRecord/LearningRecord write failures cannot affect product behavior because V1 does not call those writers.

Safety-critical durable records are domain authority, not analytics, and remain owned by Safety/product code.

## Recommendation approval firewall

Every Team 8 recommendation contains `mutation_authority: false` and `requires_review: true`.

Team 8 has no function that writes Door compatibility, queue thresholds, safety rules, privacy settings, content-learning consent, Conversation behavior, media policy or account policy.

A recommendation and a production change are separate operations owned by Command/the relevant product team.

## Model / AI necessity

Team 8 V1 uses no model.

The historical `LearningAdvisor` model path fails the V1 necessity test because the current Team 8 questions are answerable from deterministic aggregates and simple arithmetic. Its operator command is therefore superseded.

Current cross-team model-assisted capabilities are classified by Team 8 as **normal bounded services, not formal autonomous Agents**, because they do not possess independent product authority:

- Conversation Companion (Team 3/product assistance owner): participant-invoked model-assisted service; Team 8 does not alter it.
- Safety Review Assistant (Team 4 owner): advisory model-assisted review helper; Team 8 does not grant it punishment authority.
- Trend/Bridge Research (Conversation-start owner): advisory research helper with no publication authority; not part of Team 8 learning.

Their continued V1 product necessity remains with their owning product/safety boundaries, not Team 8.

## Historical intelligence classification

| Historical concept | Team 8 V1 disposition |
| --- | --- |
| Compatibility | RULE / ALGORITHM where current deterministic matching uses it; no Agent |
| Opportunity | REJECT / SUPERSEDED as V1 decision authority; legacy score fields do not earn runtime authority |
| Scarcity | RULE / ALGORITHM for approved deterministic cross-Door scarcity behavior |
| Matchmaking Lead | REJECT / SUPERSEDED |
| Queue Intelligence | RULE / ALGORITHM / normal queue service |
| Safety | PRODUCT/GOVERNANCE + deterministic Safety services; Team 4 owns policy |
| Learning | ANALYTICS / LEARNING COMPONENT implemented by deterministic Team 8 report |
| Category Intelligence | normal curated/rule-based Conversation-start behavior where active |
| Language Intelligence | explicit participant language + deterministic qualification; no inference Agent |
| Complexity Intelligence | FUTURE RESEARCH |
| Confidence Intelligence | FUTURE RESEARCH / reject profiling in V1 |
| Trend Intelligence | FUTURE/ADVISORY RESEARCH; no automatic publication |
| Icebreaker Learning | FUTURE ANALYTICS only if privacy-safe canonical signals are justified |
| Starter | FUTURE RESEARCH |
| Flow | FUTURE RESEARCH |
| Trust | FUTURE RESEARCH; no hidden trust score |
| Critic | FUTURE RESEARCH |
| Adaptive Matching | current approved deterministic matchmaking rules, not self-learning |
| Learning Engine | superseded by Team 8 deterministic aggregate/recommendation path |
| Emotional Readiness | REJECT / SUPERSEDED for V1 |
| Story Engine | FUTURE RESEARCH |
| Conversation Start | normal product/catalog service |
| Expression Confidence | FUTURE RESEARCH; no participant profiling in V1 |
| Language Detection | SUPERSEDED by explicit attempt language for matchmaking V1 |
| Language Anxiety Reduction | PRODUCT / GOVERNANCE principle, not Agent |
| Trust & Safety Intelligence | Team 4 safety rules/review services, not hidden participant scoring |
| Serendipity | PRODUCT/GOVERNANCE principle or future research, not Agent |
| Metrics & Success | Team 8 aggregate analytics |
| HCIL | PRODUCT/GOVERNANCE / future research principle, not runtime Agent |
| A01 Conversation Companion | normal participant-invoked model-assisted service; cross-team owner |
| A02 Learning Advisor | SUPERSEDED for V1 Team 8 learning; operator path disabled |
| A03 Safety Review Assistant | normal advisory model-assisted service; Team 4 owner |
| A04 Trend/Bridge Research | normal advisory research service; cross-team owner |

## Keystroke field

The current matcher may carry a legacy `keystroke_cadence` slot in queue payload shape, but V1 matching does not use it and Team 8 does not ingest it. No browser or analytics path should fabricate or persist cadence for learning.

## Experiments

Team 8 V1 contains no automatic experimentation system. Any future A/B test requires an explicit hypothesis, bounded population, frozen safety/privacy invariants, version, start/end, outcome metric, rollback and Command approval. Analytics may measure an approved experiment; it may not silently enroll people or alter behavior.

## Retention

Team 8 V1 creates no persisted analytics/learning dataset: snapshots and recommendations are generated on demand in process memory and printed to the operator. Therefore Team 8 introduces no new raw-event or aggregate retention period.

Existing canonical Match/Conversation/Relationship/Report retention remains governed by those product domains; Team 8 does not extend it.

The historical AnalyticsRecord/LearningRecord tables may contain pre-V1 rows. Their deletion/archive policy is a separate Command/governance cleanup decision. New writes are blocked now so the ambiguity cannot accumulate further.

## Dashboard

No dashboard is required for V1. `mix strangertalks.intelligence` plus tests is sufficient. Build a UI only if launch operations later prove a real need.

## Closure invariant

Team 8 V1 learns less about people and more about whether the product is doing its job:

**aggregate before profiling; deterministic before AI; recommend before mutating; privacy before curiosity; Safety cannot be optimized away.**
