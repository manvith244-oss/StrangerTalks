# T01 — Core Backend & Domain Authority

## Evolution Clause

This packet defines the current backend/domain ownership model. The social-core architecture may evolve, including future service extraction, but product law and durable invariants must migrate explicitly rather than being silently reinterpreted.

## Mission

Keep StrangerTalks' durable social truth correct, simple and enforceable: participants, access, Matches, Conversations, Bonds/Relationships, safety-linked domain state and transactional invariants.

## Current technical direction

Preferred current core: **Elixir + Phoenix + Ecto + PostgreSQL in a strong modular monolith**.

Microservices, additional databases and brokers are not goals by themselves.

## Owned authority

- Ecto schemas and migrations for core social-domain state;
- PostgreSQL constraints/indexes/transactions;
- core domain services;
- durable Match/Conversation/Relationship/Bond invariants;
- backend authorization decisions owned by the domain;
- atomic transitions that must survive process/browser failure;
- participant exclusivity at durable commit boundaries.

## Preserve

- T02 owns realtime process/protocol lifecycle details;
- T04 owns identity/security/privacy engineering policy;
- T05 owns media-specific authority;
- T06 AI may advise but does not own deterministic domain truth;
- T10 owns user-facing interpretation, not backend truth.

## Immediate archaeology inputs

T01 must inspect at minimum:

- current prep and integration matchmaking/domain implementations;
- `feat/participant-pairing-reservation-2026-08-30`;
- prior participant-activity locking and reconciliation work;
- terminal-truth lineages;
- Bond/continuity/Relationship branches;
- retention branch dependencies on domain rows;
- tests that intentionally inject corrupt/ambiguous durable states.

## Current priority question

Determine the canonical invariant for **"one participant cannot be authoritatively consumed into conflicting active pairing/conversation states"**.

The pairing-reservation branch is a candidate solution, not yet an automatic truth source.

Evaluate whether the invariant should be enforced through:

- database uniqueness/reservations;
- existing participant-activity lock/transaction boundaries;
- Conversation/Match constraints;
- a coherent combination.

The answer must survive concurrent evaluators, retries, crashes and stale operations.

## Scope

- establish domain module boundaries;
- remove accidental duplicate authorities;
- strengthen DB-enforced invariants where application-only checks are insufficient;
- make transactional ownership explicit;
- expose stable APIs to realtime/client layers;
- ensure migrations have rollback/forward safety appropriate to production;
- document data lifecycle implications with T04/T08.

## Non-scope

- changing who users are allowed to meet without product approval;
- inventing new Bond semantics;
- UI redesign;
- deploying a second datastore because of anticipated scale;
- replacing Phoenix/Elixir without an architecture decision.

## Required failure cases

Tests should cover relevant combinations of:

- simultaneous pairing;
- duplicate queue/evaluate calls;
- transaction rollback;
- stale match commit;
- participant already in active Conversation;
- terminalization failure;
- retry after ambiguous response;
- process restart between phases;
- integrity violation from intentionally corrupt fixture;
- idempotent duplicate terminal operations.

## Technology posture

- Elixir/Phoenix/Ecto/PostgreSQL/SQL: ACTIVE NOW.
- Modular Monolith: preferred current structure.
- Redis: EVALUATE only for proven shared ephemeral-state need.
- Kafka/RabbitMQ: NOT JUSTIFIED for core domain transactions currently.
- Microservices: trigger-based extraction only.
- GraphQL: not owned/needed by default.

## Evidence requirement

Domain completion requires focused schema/transaction tests, hostile concurrency proof, integration with T02 lifecycle tests, and exact-SHA regression evidence. A DB constraint alone is not enough if process/client semantics can contradict it; a process lock alone is not enough if durable races can bypass it.

## Stop conditions

Escalate if implementation requires changing matchmaking product rules, Bond meaning, safety veto behavior, retention policy or another team's authority.
