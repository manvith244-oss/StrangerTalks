# StrangerTalks Prototype 1 — Third Thing Experiment

Status: FROZEN BUILD CONTRACT
Owner authority: Manvith
Construction base: `main@d69fd48889ba9c79a66a5653acd44ad329c97969`

## Scientific hypothesis

H1: a shared Third Thing produces stronger anonymous conversation than a contextless blank 1:1 room.

This branch is an isolated experiment. It MUST NOT change canonical matchmaking semantics, production database schema, production secrets, or production traffic without separate owner approval.

## Controlled topology

### A — control
`Connect -> canonical contextless pairing -> blank room`

### B — treatment
`Hearth -> <=100-char contribution -> overlap bridge -> mutual Step In -> anchored room`

Both variants must reuse equivalent participant authentication, transport, safety, rate-limit, terminal teardown, and message-delivery laws. The experimental variable is context: treatment receives the Hearth contribution/bridge/origin anchor; control does not.

## Treatment state machine

`UNSEEDED -> HEARTH_VIEWED -> SUBMITTED -> BRIDGE_OFFERED -> DYADIC_ROOM -> OPTIONAL_FEEDBACK`

Failure/exit paths:
- SUBMITTED timeout/exit -> DISSOLVED
- bridge pass/drop/20s timeout -> HEARTH_VIEWED with no rejection notification
- room Leave -> immediate terminal partner notification and teardown, then optional feedback

## Non-negotiable UX laws

- one active Hearth artifact; no feed or history scroll
- contribution cap is provisionally 100 characters
- Temporal Presence may expose only 1–3 recent authorless contributions and must expire aggressively
- no queue depth, global presence count, spinner timer, AI prompt, icebreaker, streak, level, or identity mechanic
- bridge actions are Step In / Pass; mutual Step In is required
- room retains only the two origin contributions as an unobtrusive anchor
- Leave is immediate; feedback is post-teardown and optional

## Isolation

- experiment namespace: `StrangertalksNew.Experiments.Hearth` and `hearth:*` socket topics (or an equally isolated namespace if repository constraints require it)
- ephemeral bounded process memory first; no new production tables
- experiment state must have TTLs and memory bounds
- `EXPERIMENT_HEARTH_ENABLED=false` is the default and kill switch
- no live traffic split is enabled by merely merging experiment code; traffic admission requires a separate owner-approved configuration/deployment action
- do not mutate Supabase or execute production migrations

## Telemetry contract

Record structural events, not durable chat text:
- `hearth_viewed`
- `hearth_submitted`
- `bridge_offered`
- `bridge_step_in`
- `bridge_passed`
- `bridge_expired`
- `experiment_room_started`
- `experiment_first_message`
- `experiment_turn`
- `experiment_room_ended`
- optional `experiment_exit_reason`

Required dimensions should be privacy-bounded identifiers/variant/run metadata, timestamps/durations, turn counters, and reason enums. Do not place raw message bodies or raw Hearth contribution text in analytics payloads.

Automatic semantic classifications such as ASL/demographic regression, bilateral handle extraction, and context migration are NOT authoritative in V1. Preserve enough privacy-safe structural evidence for later bounded research, and use consented/manual qualitative sampling where required.

## Comparative metrics

1. ignition velocity: room start -> first message
2. demographic-regression rate in first three turns (research classification; not raw-text analytics)
3. turn longevity
4. bilateral handle extraction (qualitative/experimental classification)
5. early abort rate: <=2 turns
6. escape-velocity proxy: >12 turns without >60s transmission gap
7. optional exit-reason distribution

All numeric thresholds proposed during brainstorming are provisional hypotheses, not validated product laws.

## Phase-1 Hearth archetypes

1. Failed Aspiration — `What did you buy thinking, “I’m definitely using this,” and then barely touched?`
2. Domestic Chaos — `What chair, counter, or corner in your room has quietly become permanent storage?`
3. Mundane Waste — `What food item do you keep buying even though half of it always goes bad?`
4. Micro-Avoidance — `What is one tiny task you've postponed for days that would take under 4 minutes?`
5. Private Habit — `What is something you do almost every night that would make no sense to anyone else?`
6. Cheap Relief — `What's something that costs almost nothing that instantly saves a bad day?`
7. Everyday Contradiction — `What's something you constantly complain about but keep choosing to do anyway?`
8. Trivial Conviction — `What is an incredibly petty everyday thing you quietly judge people for?`

Each run must register its prompt, latent seam, expected migration route, and predicted failure signature before exposure.

## Repository-grounded reuse boundary

At the frozen base, canonical web entry routes are served through `PageController`, participant auth is enforced at `/socket` through `UserSocket`, and existing topics include participant, conversation, hangout, and hangout_lobby. The experiment must add its own topic namespace rather than alter those topic contracts. Existing queue, participant-connection, rate-limit, lifecycle, and transport authorities remain canonical.

## Proof required before admission

- focused unit tests for Hearth state/TTL/memory bounds
- channel tests for auth, submission validation, bridge mutuality, pass/drop/timeout, replacement/disconnect races, and terminal teardown
- browser contract for Hearth -> Bridge -> Room and immediate Leave
- kill-switch proof: disabled state exposes no experiment admission path
- privacy proof: analytics events contain no raw contribution/message text
- regression proof for canonical matchmaking/conversation
- `mix compile --warnings-as-errors`
- `mix deps.unlock --unused` + clean lock diff
- `mix format --check-formatted`
- full `mix test`
- relevant JS/browser tests
- clean tree / exact-head evidence

## Falsification rule

Do not expand into Bonds, Relationship Space, World districts, Circles, AI conversation intervention, or public reputation from this prototype. First determine whether treatment B beats control A on the core social-physics hypothesis.