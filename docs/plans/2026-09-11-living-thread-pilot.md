# Living Thread minimum consequence pilot

Status: implementation plan for the disposable founder pilot. This is not a reusable World/Commons/Consequence framework.

## Question

Can one small, privately legible causal action make a person voluntarily return to see what became of it more than comparable spectatorship?

## Frozen pilot rules

- Two-person causal pocket: A writes one load-bearing seed; one eligible anonymous B carries it forward.
- Spectator control: a spectator may observe an equivalent thread but cannot change it.
- Continuation timeout: B must continue within 8 hours of A opening the thread.
- Resolution point: 24 hours after A opens the thread.
- `time_remaining_at_continuation` is logged so late continuation can be separated from psychological failure.
- No rescue after the 8-hour deadline: no manual backfill, AI, bot, timeout extension, or operator nudge.
- No consequence-specific push/email/countdown.
- Liquidity failure, causal dullness, and social fizzle remain analytically separate.
- Known-person suspicion is asked only after behavioral exposure and logged separately.
- Small-N results are directional smoke only. Single-digit completed exposures per condition must not be presented as a confident verdict.

## Minimal roles

The recruited cohort is assigned once to one of three pilot roles:

- `CONSEQUENCE_A`: creates one seed and later receives its real continuation if one arrives.
- `SPECTATOR_A`: is attached to a comparable thread but cannot mutate it.
- `CARRIER_B`: may carry forward one eligible waiting seed.

Assignment is persisted so refreshing cannot switch a participant between conditions. A spectator and carrier are never allowed to mutate the spectator's observed thread as if they were the causal A.

## State model

`WAITING_FOR_B` -> `CONTINUED` -> `RESOLVED`

or

`WAITING_FOR_B` -> `LIQUIDITY_FAILURE`

Deadline transitions may be materialized lazily on reads/writes for this pilot; no background scheduler is required.

## Safety

- A participant cannot continue their own thread.
- Candidate B and spectator assignment must honor canonical `MatchingRules.check_safety_veto?/2`.
- Thread selection must not reveal why a candidate was skipped.
- Content is bounded plain text; no media, HTML, links-as-features, profiles, likes, ranking, or public attribution.

## Identity limitation

For this disposable pilot, the current signed StrangerTalks `participant_id` is the experiment anchor. The dedicated browser surface may persist its signed participant credential locally for the 24-hour experiment window. This does **not** replace the separately designed production identity stack (stable server-only principal, rotating sessions/public actors, scoped recognition). Do not generalize this storage pattern into production World identity.

## Minimal event vocabulary

- `thread_seen`
- `thread_contributed`
- `thread_reopened`
- `thread_resolved`
- `new_thread_joined`
- `known_person_debrief`

Event metadata may include `time_remaining_at_continuation_seconds` and the debrief answer. It must not become general-purpose behavioral analytics.

## Implementation order (TDD)

1. Domain tests for assignment stability, deadlines, no rescue, safety veto, continuation dedupe, hidden-before-resolution result, spectator read-only behavior, and continuation timing metadata.
2. Migration + small Ecto schemas/context.
3. Authenticated JSON controller tests and controller.
4. One isolated `/living-thread` page using the JSON API.
5. CI/precommit. Do not merge until branch checks pass.

## Explicitly out of scope

No world map, Commons, recognition capsules, social-presence lease implementation, notification system, recommendation engine, AI-generated continuation, multiple pocket sizes/horizons, statistical dashboard, or general consequence engine.

The expensive architecture is earned only if real users produce the core behavioral smoke.