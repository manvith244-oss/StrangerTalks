# T06 — AI, ML & Agent Systems Authority

## Evolution Clause

AI capabilities, providers and models will change quickly. The durable law is that model capability does not automatically equal product authority. New AI features must preserve privacy, user agency and deterministic safety/domain boundaries unless product governance explicitly changes them.

## Mission

Use AI where it materially improves StrangerTalks while keeping model failure isolated from core human communication and preventing silent surveillance or autonomous social authority.

## Current known model

Current project documentation describes bounded A01–A04 Agent Systems:

- A01 Conversation Companion — participant-invoked, draft/suggestion assistance;
- A02 Learning Advisor — bounded internal recommendations;
- A03 Safety Review Assistant — advisory review of existing Reports;
- A04 Trend/Bridge Research — operator/research support.

Deterministic services remain final authority for matchmaking, lifecycle and safety vetoes.

## Branch-only architecture candidate

`feature/first-safe-python-packet-2026-08-30` contains a substantial Python/FastAPI internal AI-service boundary plus an Elixir client with deadlines, validation and circuit-breaker behavior.

T06 must treat this as a **salvage candidate**, not as automatically accepted architecture.

## Owned authority

- model provider adapters;
- prompt/schema contracts;
- AI request minimization;
- bounded advisory feature implementation;
- model failure/circuit-breaker semantics;
- service-level AI observability without private payload leakage;
- RAG/embedding/vector/MCP evaluation when a concrete approved need exists;
- model-serving/MLOps proposals.

## Preserve

AI may not silently:

- choose final Matchmaking outcomes;
- weaken Blocks/safety vetoes;
- create user-authored messages;
- infer hidden psychological/identity facts as authoritative state;
- mutate production policy from analytics;
- gain broad Conversation history because it would improve model quality;
- create cross-context identity linkage.

## Immediate work

1. Compare current in-process provider paths against the branch-only Python service.
2. Determine whether extraction is justified by dependency isolation, failure isolation, scaling, security and ownership.
3. If accepted, define the Elixir↔Python service contract, deadlines, authentication, versioning, health/readiness and rollback.
4. Decide which existing A01–A04 paths move to the service and which remain in Elixir.
5. Preserve `store: false`/equivalent privacy behavior where applicable and explicit content minimization.
6. Add redaction-safe metrics and provider failure classification.

## Technology posture

- LLMs/Agents/Prompt Engineering: ACTIVE in bounded form.
- Python/FastAPI: BRANCH-ONLY SALVAGE CANDIDATE.
- OpenTelemetry for AI service: candidate/likely useful if extraction occurs.
- RAG/Embeddings/Vector DB: NOT JUSTIFIED until an approved corpus/retrieval use case exists.
- MCP: EVALUATE for tool integration, not hidden authority.
- model serving/MLOps: trigger-based when StrangerTalks owns model lifecycle rather than provider calls.
- multi-agent systems: valid for construction/orchestration; production use requires separate product justification.

## Evidence

Require contract tests across Elixir/Python, malformed response validation, timeout/circuit behavior, provider-disabled degradation, privacy/logging tests, prompt-injection/tool-authority review where relevant, and proof that core human Conversation remains operational when AI is unavailable.

## Stop conditions

Stop for product/privacy decision before increasing AI data access, adding autonomous actions, introducing personalized profiling, or making AI required for core human connection.
