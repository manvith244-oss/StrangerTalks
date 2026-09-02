# StrangerTalks Construction System

Status: ACTIVE CONSTRUCTION GOVERNANCE

This directory is the operating system for building StrangerTalks across human teams, AI teams, coding agents, review agents, and future tools.

It is intentionally split into two layers:

1. **Universal documents** — every team must read and obey these.
2. **Team packets** — domain-specific ownership, goals, boundaries, dependencies, evidence, and handoff rules.

## Source-of-truth rule

This documentation branch is a **hosting and coordination branch**, not proof that `release/prep-2026-08-22` is the canonical product branch.

Repository truth must be reconstructed from the complete evidence corpus: relevant branches, commits, pull requests, tests, workflows, implementation, production/release lineage, architecture records, and explicit owner decisions.

A feature is not considered absent merely because it is absent from `main`, and it is not considered canonical merely because it exists on a newer branch.

## Universal documents

- `00_CONSTRUCTION_CHARTER.md` — mission, constitutional laws, construction principles, evolution clause.
- `01_REPOSITORY_TRUTH_PROTOCOL.md` — branch archaeology, provenance and salvage classification.
- `02_UNIVERSAL_TEAM_OPERATING_CONTRACT.md` — rules every team follows.
- `03_ORCHESTRATION_AND_PROMPT_CHAIN.md` — Owner Intent → Orchestrator → Owner Proxy → Prompt Compiler → Executor → Verifier.
- `04_EVOLUTION_AND_DECISION_GOVERNANCE.md` — how the end goal may evolve without silent architectural drift.
- `05_EVIDENCE_VERIFICATION_HANDOFF_STANDARD.md` — proof, exact-SHA, testing and handoff requirements.
- `06_TECHNOLOGY_DECISION_FRAMEWORK.md` — how technologies are adopted, deferred, triggered or rejected.
- `07_TEAM_REGISTRY_AND_DEPENDENCIES.md` — construction teams and ownership graph.
- `08_CURRENT_CONSTRUCTION_BASELINE.md` — current evidence-backed architecture and known non-main work.
- `09_OWNER_CONSTITUTION_AND_PROXY_BOUNDARIES.md` — reusable owner decisions and strict boundaries for the Owner Proxy.
- `10_BRANCH_SALVAGE_LEDGER.md` — branch/capability classification and archaeology queue.
- `TEAM_PACKET_TEMPLATE.md` — mandatory structure for dedicated team files.

## Dedicated team packets

Current packets:

- `teams/T00_REPOSITORY_INTEGRATION_AUTHORITY.md`
- `teams/T01_CORE_BACKEND_DOMAIN.md`
- `teams/T02_REALTIME_DISTRIBUTED_SYSTEMS.md`
- `teams/T03_FRONTEND_CLIENT_RUNTIME.md`
- `teams/T04_IDENTITY_SECURITY_PRIVACY.md`
- `teams/T05_MEDIA_WEBRTC.md`
- `teams/T06_AI_ML_AGENT_SYSTEMS.md`
- `teams/T07_DATA_SEARCH_ANALYTICS.md`
- `teams/T08_PLATFORM_DEVOPS_SRE.md`
- `teams/T09_QA_RELIABILITY_PERFORMANCE.md`
- `teams/T10_PRODUCT_UX_ACCESSIBILITY_I18N.md`
- `teams/T11_ARCHITECTURE_TECHNICAL_COUNCIL.md`

## Prompt-chain operating model

The construction system separates:

**Owner → Orchestrator → Owner Proxy (only when established policy can answer) → Prompt Compiler → Execution Team → Verifier/Break Team → Integration Authority.**

This formalizes the recent workflow in which one model coordinates work, another team can answer established owner-policy questions, a dedicated team compiles the final execution prompt, and a separate execution agent changes the repository.

The purpose is to preserve intent while preventing prompt drift, invented owner decisions and self-certified completion.

## Portability

These documents are written so they can be used by Claude, ChatGPT, Codex, human engineers, future agents, or another orchestration system. Model names are implementation details; roles and contracts are the durable interface.

GitHub is the preferred canonical storage location for construction law because the documents remain versioned beside the code and can be tied to exact SHAs. A Notion/Drive view may be created later as a navigation/mirror layer, but it should not silently become a second conflicting source of truth.

## Evolution clause

The current end-state is not frozen. StrangerTalks may evolve as product evidence, user behavior, safety requirements, legal constraints, scale, technical capability, cost, and owner decisions evolve.

Evolution is allowed. Silent drift is not.

Any team may challenge a current implementation or architecture choice with evidence, but it must not silently violate current product laws, safety boundaries, ownership boundaries, or cross-team contracts. Significant changes require an explicit decision record and a migration path from the previous assumption.
