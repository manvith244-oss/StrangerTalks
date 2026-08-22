# StrangerTalks Agent Systems — V1 Runtime Boundaries

Status: canonical release-remediation note for `release/prep-2026-08-22`.

This document does not introduce an Agent system. It records the deterministic V1 authority boundaries so historical Agent-era names cannot be mistaken for live runtime design.

## Zero-Agent V1

V1 has no generic Agent Runtime, Agent Router, Agent Executor, Node Agent Cluster, runtime LLM, embedding/vector-search dependency, or autonomous learning-to-production mutation path.

Elixir's `Agent` used by `QueueEngine.QueueState` is only an in-memory OTP state primitive.

## Matchmaking safety authority

Final anonymous Match authority is `StrangertalksNew.Matchmaking.MatchmakingEngine` while both participants are held by `ParticipantActivityLock`.

Immediately before Match + Conversation persistence it re-reads:

- both current QueueState entries;
- queue-attempt IDs;
- Door values;
- Conversation Language values;
- the persisted safety veto (`MatchingRules.check_safety_veto?/2`);
- active Conversation authority for both participants.

The persisted safety veto currently consists of:

1. an active `BoundaryBlock` in either direction; or
2. a canonical Relationship whose status is `CLOSED`.

The Match and pending Conversation are then created in one `Ecto.Multi`; queue entries are removed only after the transaction succeeds.

No separate ban, suspension, safety-hold, review-triggered matchmaking restriction, bot/tarpit restriction, or other participant restriction is part of the frozen current anonymous V1 matchmaking admission contract. Historical documents/schema fields that discuss broader enforcement do not create a runtime requirement.

## Queue lifecycle ownership

Canonical V1 owners are:

- `QueueEngine.ParticipantConnectionTracker` — live ParticipantChannel/tab ownership and final-tab disconnect cleanup;
- `QueueEngine.QueueState` — volatile current queue-attempt state;
- `Matchmaking.MatchmakingEngine` — join/leave/cancel/requeue/matching mutations.

`Queue.ParticipantServer` is **DORMANT BUT REFERENCED**. It is retained for historical focused tests only. Production supervision does not start it or its private `StrangertalksNew.Queue.Registry`, and current ParticipantChannel/controller/matchmaking paths do not call it.

`QueueEngine.Matcher` is **DORMANT**. Its historical intent/media/tempo scoring function remains for regression-only callers; current MatchmakingEngine does not call it.

## Legacy safety hooks

`QueueEngine.SafetyReceiver` is **ACTIVE BUT BENIGN / NON-AUTHORITATIVE**. It remains supervised as a compatibility subscriber.

`QueueEngine.QueueState.apply_veto/2` is a **PLACEHOLDER** no-op. Neither component is relied on for final safety. The authoritative persisted safety re-read in MatchmakingEngine is the protection boundary.

Old comments implying a Redis safety bridge were historical. Current V1 dependencies do not include Redis.

## Readiness / privacy remnants

The following remain only as historical schema vocabulary and are not active V1 behavioral inputs:

- `LearningRecord.record_type == READINESS_EVALUATION` — **DORMANT schema**;
- `readiness_score` — **DORMANT schema field**;
- `keystroke_latency_variance` — **DORMANT schema field**;
- analytics `*_agent_accuracy` fields — **HISTORICAL NAMING ONLY**.

Current ParticipantChannel passes `nil` for media/keystroke profile inputs when joining the anonymous queue. Current MatchmakingEngine does not consume LearningRecord/AnalyticsRecord or the historical readiness fields to select candidates, relax scarcity, choose language, choose Conversation Start content, or decide safety.

This is an explicit V1 privacy boundary: no hidden semantic or psychological Conversation surveillance is authorized by those historical fields.

## Learning / analytics authority

`LearningRecords` and `AnalyticsRecords` are CRUD persistence contexts. They do not write application configuration and are not called by authoritative Matchmaking, Conversation Start, language, or safety paths.

V1 production behavior changes require an explicit reviewed code/configuration change. Analytics may observe or support later recommendations; it has no silent mutation authority.

## Conversation Start language authority

Conversation Language remains attempt-bound and Match-authoritative (`en`, `te`, `hi`).

`IcebreakerCatalog.identity_for/1` resolves:

`Conversation -> persisted Match -> conversation_language -> approved language-qualified starter identity`.

The browser receives that approved identity and renders only the matching curated catalog item. It does not select a fallback language from local browser state. Missing/invalid Match language produces no active starter rather than an English fallback.

System starter state has no participant sender, message ID, sequence, or delivery lifecycle. Genuine participant-authored timeline content is still accepted only through the normal message/media send boundaries and retires the starter.

## Recovery

Conversation runtime recovery reconstructs authority from persisted Conversation/Match state. A terminal durable Conversation is not resurrected, stale runtime epochs do not regain authority, and unauthorized participants cannot join another participant's Conversation.

A recovered transition survivor re-enters the same canonical QueueState/MatchmakingEngine path; any later Match therefore passes the same final persisted safety re-read as an ordinary queue attempt.

## Single-node V1 deployment invariant

`ParticipantActivityLock` is intentionally a **single-node V1** serialization boundary. Horizontal multi-node app execution is not supported by this V1 authority model.

Release invariant:

- the authoritative Phoenix release must run exactly one application instance;
- automatic horizontal scaling must remain disabled;
- preview instances must not share production matchmaking authority;
- any future move to multiple authoritative BEAM nodes requires an explicit distributed-coordination design before scaling.

Operational verification on 2026-08-22 found the Render service `strangertalks-phoenix` on branch `release/prep-2026-08-22` configured with `numInstances: 1`, plan `free`, preview generation off, PR previews off, and auto-deploy off. That configuration satisfies the single-node V1 invariant at the time of this remediation audit.

The separate legacy Node service on branch `master` is not the release-preparation Phoenix authority and must not be treated as a second BEAM matchmaking node.

## Model / LLM boundary

Runtime dependency audit must remain clean for:

- OpenAI;
- Gemini / Google AI;
- Anthropic;
- LLM libraries/endpoints;
- embeddings;
- vector search;
- inference endpoints;
- semantic models;
- moderation models.

A future participant-invoked assistant or review aid would require a separate explicit product/architecture decision; it is not part of Agent Systems V1.
