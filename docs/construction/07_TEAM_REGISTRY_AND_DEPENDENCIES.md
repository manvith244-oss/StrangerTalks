# 07 — Team Registry and Dependencies

Status: UNIVERSAL / LIVING DOCUMENT

## Principle

Teams are organized around **authority and failure boundaries**, not around a random list of technologies.

Technologies may span teams. Authority should not.

## T0 — Repository & Integration Authority

Mission: reconstruct repository truth, maintain the salvage/conflict ledger, establish exact construction baselines, compose accepted specialist work without destroying newer authorities.

Owns:

- branch archaeology;
- integration branches;
- merge provenance;
- construction baseline declarations;
- architecture document synchronization;
- cross-team merge conflict resolution process.

Does not own product law.

Dependency: every team consumes T0's current baseline/ledger.

## T1 — Core Backend & Domain Authority

Mission: own durable social-domain rules and transaction boundaries.

Primary areas:

- participants/accounts domain seams;
- matchmaking durable transactions;
- Conversation/Match/Bond/Relationship data models;
- Ecto/PostgreSQL integrity;
- domain services;
- server-side authorization boundaries.

Coordinates closely with T2 realtime and T4 security/privacy.

## T2 — Realtime & Distributed Systems Authority

Mission: make live human interaction correct under concurrency, retries, reconnects and stale operations.

Primary areas:

- Phoenix Channels;
- ConversationServer/OTP lifecycle;
- queue/realtime orchestration;
- presence;
- sequencing/epochs/generations;
- distributed/multi-node evolution;
- Pub/Sub;
- backpressure;
- future durable queue/broker decisions.

Does not redefine durable domain law by convenience.

## T3 — Frontend & Client Runtime Authority

Mission: make browser/client state accurately represent server authority while delivering a coherent user experience.

Primary areas:

- JS/possible future TypeScript runtime;
- route/history/presentation coordination;
- IndexedDB/local state;
- mobile/desktop responsive behavior;
- composer and interaction surfaces;
- stale client callback protection;
- frontend API/channel contracts.

Coordinates with T10 Product UX and T2 realtime.

## T4 — Identity, Security, Privacy & Safety Engineering Authority

Mission: protect contextual identity, access boundaries, safety authority and data minimization.

Primary areas:

- authentication;
- authorization;
- participant/session credentials;
- scoped identity;
- Block/Report/safety engineering boundaries;
- retention;
- encryption;
- secrets;
- access control;
- rate limits and abuse friction;
- privacy architecture;
- security review.

Product-level safety/policy changes still require product governance.

## T5 — Media & WebRTC Authority

Mission: make voice/video/media capabilities bounded, consent-aware and lifecycle-correct.

Primary areas:

- WebRTC;
- signaling;
- TURN/STUN;
- voice notes;
- normal/ephemeral media;
- media storage boundaries;
- media lifecycle cleanup;
- permission races;
- media privacy and abuse constraints.

Dependencies: T2 realtime, T3 client, T4 security/privacy, T8 platform.

## T6 — AI, ML & Agent Systems Authority

Mission: provide bounded intelligence without silently creating product authority or surveillance.

Primary areas:

- A01–A04/current agent boundaries;
- LLM providers;
- Python/FastAPI service salvage/evaluation;
- prompts/contracts/schema validation;
- moderation/critic boundaries;
- RAG/embeddings/vector/MCP evaluation when justified;
- model observability and privacy;
- model-serving/MLOps triggers.

Cannot override deterministic matchmaking/safety/identity/lifecycle authority unless product law explicitly changes.

## T7 — Data, Search, Analytics & Recommendation Authority

Mission: make measurement, discovery and future recommendations useful without turning the system into identity surveillance or engagement optimization by default.

Primary areas:

- analytics contracts;
- aggregate metrics;
- data pipelines if earned;
- search;
- recommendation evaluation;
- privacy-safe experimentation;
- data quality;
- future warehouse/streaming decisions.

Dependencies: T4 privacy, T1 domain, T6 AI when models are involved.

## T8 — Platform, DevOps, DevSecOps & SRE Authority

Mission: make the system buildable, deployable, observable, recoverable and operationally honest.

Primary areas:

- Docker;
- CI/CD;
- release management;
- environments;
- cloud/deployment platform;
- networking/ingress/DNS/reverse proxy;
- secrets infrastructure;
- monitoring/logging/metrics/tracing;
- backups/restore/DR;
- IaC triggers;
- capacity and incident operations.

Does not mark a product feature correct merely because deployment is green.

## T9 — QA, Reliability & Performance Authority

Mission: independently attack cross-system correctness and performance.

Primary areas:

- test strategy;
- browser/E2E;
- hostile concurrency;
- property/fuzz testing;
- load/performance;
- regression integrity;
- exact-SHA verification;
- failure injection;
- release-candidate re-attack.

T9 should remain independent of the feature executor for high-risk changes.

## T10 — Product UX, Accessibility, Localization & Human Comprehension

Mission: ensure technically correct features remain understandable, accessible and culturally/language coherent.

Primary areas:

- UX mental models;
- UI systems;
- accessibility;
- responsive/device behavior in coordination with T3;
- localization/internationalization;
- user-facing privacy/safety copy;
- onboarding/first-minute comprehension;
- ordinary-language interpretation of Bonds, anonymity, disclosure and scoped identity.

Does not change backend authority to make UI implementation easier.

## T11 — Architecture & Technical Council

Mission: maintain system-wide architecture coherence across T0–T10.

This is a review/council role rather than a feature factory.

Owns:

- ADR quality;
- service-extraction decisions;
- shared protocol/boundary standards;
- technology matrix;
- cross-domain architecture conflicts;
- scalability/distributed-systems evolution.

Cannot override Owner product law.

## Dependency graph

```text
                         OWNER / PRODUCT LAW
                                |
                         T11 Architecture Council
                                |
                  T0 Repository & Integration Authority
                                |
        +-----------------------+-----------------------+
        |                       |                       |
     T1 Core                 T2 Realtime             T4 Security
        |                       |                       |
        +-----------+-----------+-----------+-----------+
                    |                       |
                  T3 Client               T5 Media
                    |                       |
                    +-----------+-----------+
                                |
                             T10 UX

     T1/T4 ------------------- T7 Data ---------------- T6 AI

                  all construction outputs
                                |
                             T9 QA
                                |
                             T8 SRE
                                |
                       T0 integration candidate
```

The actual dependency order for a feature may differ; dedicated team packets must state it.

## Team scaling rule

At early scale these teams may be AI roles rather than separate humans. Do not create organizational bureaucracy just because the documents use team names.

One capable engineer/agent may execute several low-conflict roles, but outputs must still respect ownership boundaries and independent verification for high-risk work.

## Evolution clause

Teams may split, merge or disappear as the product changes. The stable principle is to preserve clear authority, handoffs and verification rather than preserve team names forever.
