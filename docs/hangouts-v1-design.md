# StrangerTalks Hangouts V1 — Repository-Grounded Design

## Status

Approved owner product contract. This document records the repository-grounded architecture for the first implementation wave; it does not replace the owner Hangouts Creation Command.

## Product bet

Hangouts tests whether small groups of anonymous strangers talk more readily and more evenly when StrangerTalks gives the room shared stimuli. Content is a conversation catalyst, not a standalone feed product.

## Canonical starting point

- Base main when this branch was created: `29fff34e916531382da481ad057dc07b92ea1859`.
- Existing `Matching` and `Conversation` schemas are explicitly pair-shaped (`participant_a_id`, `participant_b_id`) and enforce distinct two-person membership.
- Existing `ConversationChannel` and media/report paths are conversation-lifecycle specific.
- Existing authenticated `UserSocket` assigns an authoritative `participant_id`, which Hangouts can reuse without introducing a second identity/auth system.
- Existing Phoenix PubSub/Registry/DynamicSupervisor primitives are available, but the existing Conversation supervisor remains conversation-specific.
- Frontend is a Phoenix-served static shell (`priv/static/index.html`) with modular JS assets.

## Hard boundaries

1. Do not mutate `matches` or `conversations` into group abstractions.
2. Do not reuse private conversation media storage as a shared-content catalogue.
3. Add a separate `StrangertalksNew.Hangouts` bounded context and `hangout:*` channel.
4. Preserve external anonymity and room-scoped temporary pseudonyms. No permanent username, profile, follower graph, or room identity.
5. Store language as extensible BCP-47-style text metadata; V1 must not encode an eternal `en/te/hi` enum.
6. Shared content starts with first-party curated text/question/poll/image-card metadata. No anonymous public upload pipeline in V1.
7. Phoenix synchronizes room state (`content_id`, sequence, state timestamps, reactions/votes/messages); media bytes are not carried as synchronized room state.
8. Reporting in Hangouts is a separate Hangout safety path. Existing `Report` is conversation-FK-required and must not be overloaded.
9. V1 launch policy remains 18+ unless owner/legal authority changes it.
10. Hangout presence is lifecycle-derived from authoritative membership/channel transitions. V1 has no client-authored presence event or heartbeat authority.

## V1 architecture

### Persistence

Create Hangouts-owned tables:

- `hangout_rooms`: lifecycle, language tag, experiment arm, capacity/minimums, current content sequence, timestamps and aggregate counters.
- `hangout_memberships`: participant-to-room membership, temporary identity label/emoji, join/leave/disconnect state and last-seen timestamp. Unique room+participant and room+identity slot constraints.
- `hangout_messages`: room-scoped text messages with monotonic room sequence supplied by room authority.
- `hangout_content_items`: curated first-party shared stimulus catalogue metadata and safety/publication status.
- `hangout_room_content`: immutable room content sequence snapshots so reconnects see the same ordered content.
- `hangout_reactions`: participant reaction to a room-content sequence; unique per participant/sequence/reaction key as appropriate.
- `hangout_skip_votes`: one active vote per participant/content sequence.
- `hangout_reports`: reporter, optional reported participant/message/content item, category, bounded evidence, status and deduplication key.

No table creates a follower/profile/creator relationship.

### Domain modules

- `StrangertalksNew.Hangouts` — context API and transactional authority for creation/membership/messages/content/reactions/skip/reporting.
- Focused Ecto schemas under `lib/strangertalks_new/hangouts/`.
- `TemporaryIdentity` — deterministic room-scoped identity-slot allocation from a fixed non-personal vocabulary; identities are persisted only with the room membership.
- `ContentCatalog` — first-party curated content seed/catalog, language metadata extensible, deterministic feed selection for V1.
- `RoomServer` — one process per active Hangout, authoritative state machine and monotonically increasing message/content sequence.
- Dedicated `HangoutRegistry` and `HangoutDynamicSupervisor` supervised by the application.

### Matchmaking

V1 does not reuse pair-shaped `Matching`. A Hangouts queue groups eligible participants by normalized language tag into a tunable target size. The initial target defaults to 4 and may form at a configured minimum of 3. Values come from application configuration, not hard-coded product law. One participant may not be active in multiple Hangouts rooms at once.

### Realtime protocol

Add `channel "hangout:*", StrangertalksNewWeb.HangoutChannel` to the authenticated `UserSocket`.

Join authorization requires the socket participant to have an active membership for the requested room. Server replies include room lifecycle state, the caller's temporary identity, current members, authoritative current content and latest message/content sequence.

Presence authority follows the shipped room lifecycle: joining or rejoining obtains the authoritative snapshot through `RoomServer.reconnect`; unexpected channel termination calls `RoomServer.disconnect`; explicit `room:leave` persists the member's deliberate leave. There is no client-authored presence event in V1. Reconnect always begins from authoritative room state rather than a client timer or heartbeat claim.

Client events:

- `message:send`
- `reaction:add`
- `content:skip_vote`
- `room:leave`
- `safety:report`
- `safety:block`

Server broadcasts:

- `room:snapshot`
- `member:joined`
- `member:left`
- `message:new`
- `reaction:updated`
- `content:changed`
- `skip:updated`
- `room:ended`

Reconnect always begins from an authoritative snapshot, never a client timer.

### Shared-content progression

Room authority advances content when either:

- the current item reaches its configured discussion window; or
- skip votes reach the configured quorum of currently connected active members.

For the first implementation, deterministic curated sequencing is preferred over any learned recommender. Each transition increments a room content sequence and broadcasts the authoritative item and `started_at` timestamp.

### Safety and privacy

- Membership checks gate every room mutation.
- Text/message/evidence byte limits are enforced server-side.
- Reporter cannot report themself.
- Report categories reuse policy vocabulary where appropriate but persistence is Hangouts-owned because the existing report schema requires a 1:1 conversation FK.
- Client-visible temporary identity never exposes participant IDs.
- Analytics use room/content/aggregate event dimensions and participant counts; no extra public identity fields.

### Experiment arms

Persist a room `experiment_arm`:

- `GROUP_NO_CONTENT` — anonymous group chat without shared stimuli.
- `GROUP_WITH_CONTENT` — Hangouts treatment.

Existing 1:1 StrangerTalks remains the external control and is not rewritten to fit this table.

### Frontend

Add a top-level `Hang Out` entry next to the existing Talk entry without turning the doors page into a category dashboard. Add a dedicated Hangout screen optimized for mobile: shared stimulus, compact member/temporary-identity strip, group message timeline, composer, reactions, collective skip, report/leave controls, reconnect state.

Hangouts runtime lives in focused JS/CSS modules and reuses the established participant token/socket bootstrapping rather than duplicating auth.

## Test strategy

1. Schema/changeset invariants for room membership, identities, messages and reports.
2. Context transaction tests for room formation, join/leave, message ordering, content sequence, skip quorum and report authorization.
3. RoomServer concurrency/reconnect snapshot tests.
4. Channel authorization and event tests.
5. JS contract tests for state reconciliation and mobile-safe DOM behavior.
6. Existing regression via `mix precommit` plus JS tests required by the Hangouts workflow.
7. Final candidate rebased/merged against fresh canonical main before admission.

## Delivery sequence

1. Domain foundation + migrations + RED/GREEN proof.
2. RoomServer and group formation.
3. Channel and reconnect snapshot.
4. Safety/report path + telemetry.
5. Frontend entry/runtime/UI.
6. Full regression, browser/JS proof, fresh-main integration and PR admission.
