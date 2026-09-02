# 08 — Current Construction Baseline

Status: PRELIMINARY / EVIDENCE-BACKED / NOT YET FINAL CANONICAL BASELINE

Research date: 2026-09-02

## Important warning

This document records what is currently known well enough to guide continued archaeology. It does **not** declare that one existing branch is the complete StrangerTalks product.

## Repository lineages currently observed

### `main`

Observed head: `83e8ee9cdd6131c0bcfdeb217cb3de5327d8b7f2`.

The observed tree is a small proof/workflow lineage and does not contain the full Phoenix application tree. GitHub comparison also reports no common ancestor between this `main` lineage and the inspected Phoenix release branches.

Conclusion: **do not use `main` as the sole audit baseline.**

### `master`

Observed head: `82ed9df067f2bbf89a65561a5f1916865a539730`.

GitHub comparison reports no common ancestor with the inspected Phoenix release-prep lineage.

Conclusion: treat as a separate historical/cutover lineage until fully classified.

### `release/prep-2026-08-22`

Observed head: `2724d655a1ab7502c0caa39c91644cd6559a5f96`.

Contains a full Phoenix application tree including `lib`, `config`, `priv`, `test`, `ops`, `docs`, `mix.exs`, Docker/build files and extensive CI workflows.

This branch is used only as the **host base for the construction documentation branch** because it contains the full application tree. That hosting choice is not a canonicality verdict.

### `release/integration-2026-08-28`

Observed head: `f781a0796e68db26409c1744d7633a22cc6b11d0`.

Comparison against `release/prep-2026-08-22` reports `diverged`, with integration 32 commits ahead and 83 commits behind relative to prep from merge base `a533309e676a2d41783cb19ba6a6abd5618689d9`.

Observed integration-only/shared seam changes include routing/history, session reconciliation, WebRTC signaling, expression runtime, browser E2E and K2 integration workflow changes.

Conclusion: **prep and integration must be semantically reconciled; neither may overwrite the other wholesale.**

## Current core implementation evidence

The inspected Phoenix project currently uses:

- Elixir;
- Phoenix 1.8;
- Ecto;
- PostgreSQL/Postgrex;
- Phoenix Channels/WebSockets;
- OTP processes/supervision;
- JavaScript browser modules;
- IndexedDB/local browser state in the current architecture documentation;
- Docker/release tooling;
- CI workflows with extensive exact-SHA proof patterns;
- telemetry libraries;
- Req HTTP client;
- JOSE;
- Gettext/internationalization primitives.

Current architecture documentation identifies:

- browser state/runtime as a client authority for local presentation/drafts;
- `UserSocket`, `ParticipantChannel` and `ConversationChannel` as realtime surfaces;
- `ConversationLifecycle.ConversationServer` as an important ephemeral realtime authority;
- Ecto/PostgreSQL as durable Conversation/Match/Relationship/Safety/analytics metadata authority;
- ordinary live Conversation text as ephemeral rather than a normal durable transcript;
- deterministic services as final authority for Matchmaking, safety vetoes and Conversation lifecycle rules;
- bounded A01–A04 Agent Systems with no generic autonomous decision bus.

All of these remain subject to branch reconciliation where later branches changed the implementation.

## Known important branch-only work

### Python/FastAPI AI boundary

Branch: `feature/first-safe-python-packet-2026-08-30`.

Comparison against current integration shows a distinct Python service plus an Elixir client boundary, including:

- `services/ai/pyproject.toml`;
- FastAPI application structure;
- OpenAI dependency;
- Pydantic contracts;
- HTTPX;
- OpenTelemetry SDK;
- structured logging;
- service authentication;
- privacy helpers;
- provider protocol;
- Elixir transport/client/deadline/circuit-breaker/response-validation code;
- Python and Elixir boundary tests;
- dedicated CI workflow.

Preliminary classification: **SALVAGE CANDIDATE / ARCHITECTURE REVIEW REQUIRED**.

It is not to be merged blindly. T6 AI + T11 Architecture + T0 Integration must determine whether it should become the first extracted service boundary.

### Participant pairing reservation authority

Branch: `feat/participant-pairing-reservation-2026-08-30`.

Contains a PostgreSQL `participant_pairing_reservations` schema with an active-participant unique index, server/matchmaking changes and extensive acquisition/release/concurrency tests.

Preliminary classification: **SALVAGE CANDIDATE / CORE CONCURRENCY REVIEW REQUIRED**.

The key question is whether this reservation invariant is the correct current solution for participant exclusivity and whether it composes with current integration/realtime authority.

### Privacy & retention authority

Branch: `team7/privacy-retention-2026-08-26`.

Comparison against current prep shows 28 unique branch commits and dedicated implementation/tests, including:

- centralized retention policy;
- retention cleanup service;
- operator task;
- privacy persistence guards;
- safety-media retention tests;
- telemetry privacy tests;
- database cleanup/closure tests;
- dedicated workflow and handoff docs.

Preliminary classification: **SALVAGE / CONFLICT REVIEW REQUIRED**.

It is materially behind the current prep lineage, so the policy and invariants must be ported deliberately rather than branch-merged wholesale. Product/legal retention decisions must be reconciled with the latest policy and India legal validation before becoming canonical.

## Known open/specialist lineage caution

Recent PR history demonstrates that some specialist branches remained open or unmerged even when their meaningful work was later consumed through integration carriers. Therefore PR state alone cannot determine whether work is missing.

The archaeology ledger must map **capability provenance**, not merely branch status.

## Preliminary architecture direction

Until evidence forces a different decision:

- preserve a strong **modular Phoenix/Elixir social core**;
- keep PostgreSQL as durable authority unless a concrete use case earns another store;
- treat browser/client runtime as non-authoritative where server/durable truth exists;
- make lifecycle/concurrency authority explicit through OTP + database invariants;
- extract services only where the boundary earns operational independence;
- treat the Python AI boundary as a credible first extraction candidate, not an automatic merge;
- do not introduce Kafka, Kubernetes, GraphQL, Redis, vector databases or a frontend-framework rewrite without a concrete trigger;
- strengthen testing, privacy, observability, release and disaster-recovery disciplines before multiplying infrastructure.

## Next archaeology priorities

1. Build exhaustive-enough branch/PR capability ledger for 2026-08-22 through present.
2. Reconcile `release/prep-*` and `release/integration-*` shared seams.
3. Determine whether pairing reservation is required and current.
4. Reconcile privacy/retention branch with later domain schema and latest legal/product decisions.
5. Classify open specialist PRs that may already be integrated elsewhere.
6. Audit production/release infrastructure lineage and actual deployment topology.
7. Convert surviving architectural decisions into ADRs.
8. Freeze one **construction candidate**, not necessarily a production release, from the reconciled evidence.

## Evolution clause

This baseline must change when archaeology reveals stronger evidence. Updating it is expected. Rewriting history without preserving provenance is not.
