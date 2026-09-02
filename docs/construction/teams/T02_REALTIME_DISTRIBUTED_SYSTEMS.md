# T02 — Realtime & Distributed Systems Authority

## Evolution Clause

Realtime topology may evolve from single-node OTP/Phoenix toward multi-node or extracted services. Authority transfer must be explicit; stale-operation, ordering and safety invariants must survive migration.

## Mission

Make live human interaction correct under concurrency, retries, disconnects, reconnects, process restart and stale asynchronous work.

## Owned authority

- Phoenix Channels and socket protocol contracts;
- `ConversationServer` and related OTP lifecycle;
- realtime sequencing, epochs/generations and replay rules;
- presence and connection convergence;
- queue/realtime coordination in cooperation with T01;
- stale callback/event isolation;
- Pub/Sub and future multi-node realtime architecture;
- backpressure/resource bounds.

## Preserve

- PostgreSQL durable truth owned with T01;
- client presentation owned by T03;
- safety/identity access rules owned by T04;
- media transport specifics owned by T05.

## Immediate archaeology inputs

Inspect prep/integration differences involving:

- `ConversationChannel`;
- `ParticipantChannel`;
- `ConversationServer`;
- session reconciliation;
- navigation/realtime seams;
- terminal-truth lineages;
- same-Conversation rejoin work;
- pairing reservation candidate;
- multi-tab and reconnect proof branches.

## Required invariants

- old Conversation/session events cannot mutate a newer active one;
- duplicate events are idempotent or explicitly rejected;
- client-visible terminal truth matches durable authority;
- reconnect cannot resurrect terminal authority;
- presentation navigation does not implicitly perform lifecycle mutation;
- peer presence is not equivalent to durable relationship/access authority;
- realtime process death cannot create contradictory durable state.

## Failure matrix

Cover:

- disconnect during send;
- reconnect after missed frames;
- same participant in multiple tabs;
- old socket callback arriving after new socket/session;
- process restart;
- duplicate end/block;
- queue admission race;
- delayed match event after a newer queue attempt;
- stale WebRTC signaling in coordination with T05;
- multi-node duplication if/when clustering is enabled.

## Technology posture

- Phoenix Channels/WebSockets/OTP: ACTIVE NOW.
- Phoenix PubSub/distributed BEAM primitives: preferred before external brokers where sufficient.
- Redis: EVALUATE only when shared ephemeral coordination requires it.
- Kafka/RabbitMQ: NOT JUSTIFIED until durable asynchronous/event-stream requirements are concrete.
- Load balancing/multi-node: trigger-based; session/realtime routing must be designed before scaling horizontally.

## Evidence

Require deterministic hostile tests, real multi-browser journeys for user-visible realtime behavior, exact-SHA gates, and T09 re-attack for lifecycle-critical changes.

## Stop conditions

Stop when realtime convenience would redefine durable domain truth, safety authority, identity policy or product lifecycle semantics.
