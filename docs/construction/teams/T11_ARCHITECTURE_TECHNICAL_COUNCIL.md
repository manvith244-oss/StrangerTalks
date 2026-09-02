# T11 — Architecture & Technical Council

## Evolution Clause

Architecture exists to serve the product and its invariants. The council must be willing to change topology, languages or components when evidence earns the change, while resisting complexity added for prestige.

## Mission

Keep StrangerTalks technically coherent across backend, realtime, client, security, media, AI, data and operations as the product evolves.

## Owned authority

- architecture decision process;
- ADR review;
- shared protocol/boundary standards;
- modular-monolith boundaries;
- service extraction decisions;
- technology decision matrix;
- scalability/distributed-system evolution;
- cross-team architecture conflicts;
- technical debt prioritization where it spans owners.

## Current architectural thesis

Until stronger evidence says otherwise:

1. keep the social/realtime core in Elixir/Phoenix/OTP;
2. use PostgreSQL as durable source of truth;
3. structure the code as a strong modular monolith;
4. use HTTP/WebSockets according to interaction semantics;
5. extract services only when runtime/dependency/failure/scaling/ownership boundaries earn independence;
6. treat the Python/FastAPI AI branch as a serious first extraction candidate because its dependency and failure profile is materially different;
7. avoid Kafka/Kubernetes/GraphQL/Redis/vector databases/frontend rewrites until triggers are concrete;
8. make observability, security, release proof, backup/restore and concurrency correctness first-class before multiplying components.

## Questions T11 must review

- Is the Python AI service extraction justified now?
- What is the canonical participant-exclusivity/pairing authority?
- Which prep/integration shared seams should become explicit modules/contracts?
- When does horizontal Phoenix scaling require distributed coordination changes?
- What persistent media/storage boundaries will future Bonds/Circles require?
- What event/job infrastructure is actually needed versus predicted?
- When does TypeScript become worth the migration?
- What architectural changes are required before Circles, Happening or larger participation?

## Service extraction checklist

Do not approve extraction until the proposal defines:

- service responsibility;
- API/protocol;
- data ownership;
- authentication/authorization;
- failure/degradation behavior;
- timeout/retry/idempotency;
- deployment/observability;
- version compatibility;
- local development/testing;
- rollback;
- cost;
- owner/team;
- reason this is better than a module boundary.

## Architecture red flags

Challenge:

- multiple writable sources of truth for one authority;
- synchronous distributed chains on the realtime hot path without necessity;
- caches with undefined stale semantics;
- broker adoption without durable-work requirements;
- AI model output used as hidden truth;
- client-side authorization standing in for server authorization;
- business invariants enforced only by UI;
- microservice extraction before protocol/domain boundaries are stable;
- cloud-specific lock-in without a benefit worth the cost;
- generic platforms built before one product experience is excellent.

## Evidence

Architecture decisions should be grounded in repository reality, performance/failure evidence, product dependency order, abuse/privacy constraints and operational cost. Diagrams without migration/proof plans are proposals, not architecture completion.

## Stop conditions

T11 cannot override an unresolved product-law decision. When the technical architecture depends on what the product should mean, surface the choice to Owner/Product Council with concrete tradeoffs.
