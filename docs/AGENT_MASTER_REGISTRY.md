# StrangerTalks Agent Master Registry

Status: **CURRENT GOVERNANCE TRUTH CANDIDATE — T-A06-002**

Last verified date: `2026-09-04`

This document is the repository-level registry for the current StrangerTalks Agent/capability organization. It records governance truth only. It does not create runtime authority, feature activation, deployment authority, a database registry, an Agent Router, or an autonomous Agent platform.

Unknown states are recorded as `UNKNOWN`; later lifecycle states are never inferred from earlier ones.

## Repository identity and provenance

- repository: `manvith244-oss/StrangerTalks`
- Agent Command comparison base before T-A06-002: `423442915e37fd6aadd25bd1c6a300eed2b464f0`
- comparison-base tree: `f4bb8b3b11a1b6423aaaed07664c2454995dee69`
- current `main` observed during T-A06-002: `20293425b0556d733f47d43714d236582df7948d`
- current `main` tree: `f4bb8b3b11a1b6423aaaed07664c2454995dee69`
- T-A06-002 working branch: `team6/agent-master-registry-002`

During T-A06-002 an operator mistake created a placeholder registry directly on `main` and immediately removed it with a normal revert commit. The two resulting housekeeping commits advanced `main` from `423442915e37fd6aadd25bd1c6a300eed2b464f0` to `20293425b0556d733f47d43714d236582df7948d`, but GitHub comparison reports **no net changed files**, and the resulting tree is exactly the original `f4bb8b3b11a1b6423aaaed07664c2454995dee69`. No history was force-rewritten.

Current known live Phoenix deployment provenance from the accepted runtime reconstruction:

- Render service: `strangertalks-phoenix`
- deployment branch: `release/prep-2026-08-22`
- deployed SHA: `2724d655a1ab7502c0caa39c91644cd6559a5f96`
- canonical source authority and deployed source are therefore different lineages.

Do not call current `main` deployed merely because it is source authority. Do not call the live deployment canonical source authority merely because it is running.

## Lifecycle evidence vocabulary

Use these states separately:

`SOURCE` → `IMPLEMENTED` → `TESTED` → `PROVEN` → `DEPLOYED` → `ENABLED` → `ACTIVE` → `PRODUCTION PROVEN`

No state implies the next state.

## Terminology freeze

### BOUNDED MODEL-ASSISTED CAPABILITY

A probabilistic/model-backed capability with explicit inputs, outputs, positive authority and negative authority.

### DETERMINISTIC INTELLIGENCE SERVICE

Analytics, rules or computation that requires no model runtime.

### RESEARCH CAPABILITY

A capability that produces candidate or review material without publication authority.

### AUTONOMOUS AGENT

A capability capable of independently initiating, planning or acting across meaningful authority boundaries.

Current StrangerTalks V1 has **NO GENERAL AUTONOMOUS AGENT PLATFORM**.

### HISTORICAL AGENT

An old architectural identity retained only for history. Historical naming does not grant current runtime authority.

### SUPERSEDED IMPLEMENTATION

Code or an artifact whose responsibility has moved elsewhere and which is not current runtime authority.

Python production Agent runtime: `NOT CANONICAL / HEALTH-ONLY FOUNDATION`

The current FastAPI application mounts only its health router. Python foundations may be used later only through separately authorized capability/runtime work.

# Current master registry

## A01 — Conversation Companion

- id: `A01`
- name: `Conversation Companion`
- primary_owner: `T-A01 — Conversation Assistance & Bridge Intelligence`
- collaborators: `T-A04 runtime/provider, T-A05 evaluation, T-A06 governance, T-A09/Construction deployment proof, T-A10 security/privacy when required`
- organizational_status: `CURRENT`
- implementation_kind: `BOUNDED MODEL-ASSISTED PARTICIPANT CAPABILITY`
- runtime_status: `IMPLEMENTED IN ELIXIR / PROVIDER-BACKED WHEN CONFIGURED`
- source_sha: `20293425b0556d733f47d43714d236582df7948d` (same substantive source tree as `423442915e37fd6aadd25bd1c6a300eed2b464f0`)
- provider: `StrangertalksNew.Companion.OpenAIProvider; OpenAI Responses generation/critic path plus moderation`
- input_data_classes: `authenticated participant request; authoritative Conversation language; relevant Door; requested mode/tone; participant-supplied current draft; bounded current Conversation text; canonical active Conversation Start identity/text when still active`
- output_contract: `validated advisory suggestion candidates for explicit participant review/use; no Message or sender authority`
- positive_authority: `suggest/draft only`
- forbidden_authority: `send, impersonate, Matchmaking mutation, Safety mutation, Relationship mutation, deployment`
- safety_dependency: `persisted lifecycle/Block/Safety authority and live Conversation authority are checked before and after generation; deterministic authority wins`
- privacy_boundary: `bounded current-Conversation projection; participant/peer/account identifiers and unrelated Conversations excluded; no Agent transcript persistence; provider request configured with store:false`
- evaluation_status: `AUTHORITY TESTED; PRIVACY/SAFETY/PERFORMANCE PARTIAL; prompt-injection, multilingual benchmark, live deployment and production behavior NOT PROVEN by T-A05-001`
- exact_proof_sha: `UNKNOWN for current main; historical Agent Systems closure proof exists at d083c27b8533beefd8fcc482c60f89ec70b09437 (run 32592982085)`
- deployment_status: `DEPLOYED CODE PRESENT ON KNOWN LIVE PHOENIX SHA; CAPABILITY ACTIVATION NOT PROVEN`
- deployed_sha: `2724d655a1ab7502c0caa39c91644cd6559a5f96`
- activation_status: `UNKNOWN / NOT PROVEN ACTIVE`
- production_proof_status: `NOT PROVEN / T-A05-001: NOT PRODUCTION READY`
- open_dependencies: `T-A04 provider/runtime reliability; T-A05 independent hostile/privacy/multilingual proof; T-A09/Construction activation/deployment proof`
- historical_predecessors: `Conversation Assistance, Starter/Flow/Critic concepts, historical Icebreaker intelligence roles; none automatically restored as runtime Agents`
- retirement_state: `NONE — CURRENT CAPABILITY`
- last_verified_date: `2026-09-04`
- evidence_refs: `docs/A01_CONVERSATION_COMPANION.md; lib/strangertalks_new/companion.ex; lib/strangertalks_new/companion/open_ai_provider.ex; test/strangertalks_new/companion_test.exs; test/strangertalks_new_web/controllers/companion_controller_test.exs; T-A05-001; T-A04-001`

## A02 — Learning & Organizational Knowledge

- id: `A02`
- name: `Learning & Organizational Knowledge`
- primary_owner: `T-A02 — Learning & Organizational Knowledge Intelligence`
- collaborators: `T-A05 evaluation, T-A06 governance, domain teams supplying bounded questions/evidence, T-A09/Construction only for separately authorized product changes`
- organizational_status: `CURRENT`
- implementation_kind: `DETERMINISTIC INTELLIGENCE SERVICE`
- runtime_status: `CURRENT / DETERMINISTIC V1`
- source_sha: `20293425b0556d733f47d43714d236582df7948d` (same substantive source tree as `423442915e37fd6aadd25bd1c6a300eed2b464f0`)
- provider: `NONE for current deterministic V1; historical LearningAdvisor used the shared OpenAI provider but is superseded`
- input_data_classes: `privacy-safe aggregate evidence derived from canonical Match, Conversation, Relationship and Report rows; no raw Conversation content, participant/account identifiers or psychological/profile fields`
- output_contract: `deterministic evidence/recommendation packet for human or Agent Command review; separately authorized change required before product mutation`
- positive_authority: `aggregate interpretation, hypotheses, recommendations, contradiction detection, experiment/failure-learning design`
- forbidden_authority: `production mutation, Matchmaking mutation, Safety mutation, Conversation mutation, Relationship mutation, participant profiling, deployment`
- safety_dependency: `A02 recommendations cannot relax or replace deterministic Safety or participant rights`
- privacy_boundary: `V1Metrics returns aggregate-only output and recursively rejects forbidden identifying/content/profile keys; current V1 creates no second raw analytics store`
- evaluation_status: `CURRENT DETERMINISTIC PATH HAS HOSTILE PRIVACY/NON-MUTATION TESTS; independent T-A05 production-readiness proof remains incomplete; historical model path has separate privacy-remediation evidence`
- exact_proof_sha: `UNKNOWN for current main as a complete Agent/production proof target`
- deployment_status: `CURRENT DETERMINISTIC V1 CODE PRESENT ON KNOWN LIVE PHOENIX SHA; OPERATOR USE/ACTIVATION NOT PROVEN`
- deployed_sha: `2724d655a1ab7502c0caa39c91644cd6559a5f96`
- activation_status: `UNKNOWN for real operator use; no model activation is required for current V1`
- production_proof_status: `NOT PROVEN as an end-to-end production intelligence operation`
- open_dependencies: `T-A02-002 current documentation/authority reconciliation; T-A05 independent evaluation; any future product change requires separate authorization`
- historical_predecessors: `historical Learning Agent; LearningAdvisor — SUPERSEDED_FOR_CURRENT_V1 / DORMANT; participant-linked LearningRecord architecture`
- retirement_state: `ORGANIZATIONAL A02 NOT RETIRED; LearningAdvisor MODEL RUNTIME = SUPERSEDED_FOR_CURRENT_V1 / DORMANT / NO CURRENT NORMAL RUNTIME AUTHORITY`
- last_verified_date: `2026-09-04`
- evidence_refs: `lib/strangertalks_new/intelligence/v1_metrics.ex; lib/strangertalks_new/intelligence/v1_recommendations.ex; lib/mix/tasks/strangertalks.agents.ex; test/strangertalks_new/intelligence_v1_hostile_test.exs; docs/TEAM8_INTELLIGENCE_V1.md; T-A02-002; T-A05-001`

Canonical A02 interpretation:

`A02 organizational role = CURRENT`

`V1Metrics + V1Recommendations = CURRENT / DETERMINISTIC V1`

`AgentSystems.LearningAdvisor = SUPERSEDED_FOR_CURRENT_V1 / DORMANT / NO CURRENT NORMAL RUNTIME AUTHORITY`

A02 does not automatically imply model execution.

## A03 — Safety Review Assistant

- id: `A03`
- name: `Safety Review Assistant`
- primary_owner: `T-A03 — Safety Intelligence, Abuse Analysis & Moderation Assistance`
- collaborators: `canonical deterministic/human Safety authority, T-A04 runtime/provider, T-A05 evaluation, T-A06 governance, T-A10 security/privacy/trust, T-A09/Construction activation proof`
- organizational_status: `CURRENT`
- implementation_kind: `BOUNDED MODEL-ASSISTED SAFETY ADVISORY CAPABILITY`
- runtime_status: `IMPLEMENTED NON-PUBLIC OPERATOR CAPABILITY; INPUT-TRUTH HARDENING OPEN`
- source_sha: `20293425b0556d733f47d43714d236582df7948d` (same substantive source tree as `423442915e37fd6aadd25bd1c6a300eed2b464f0`)
- provider: `shared StrangertalksNew.Companion.OpenAIProvider`
- input_data_classes: `current implementation uses Report category/status, bounded free-form report evidence and a media-presence boolean; T-A03-002 is establishing canonical SafetyReview status and fail-closed evidence-availability truth`
- output_contract: `validated severity/action recommendation and human-review requirement; advisory vocabulary only`
- positive_authority: `recommendation only`
- forbidden_authority: `ban, Block, punish, terminalize, Matchmaking mutation, SafetyReview mutation, deployment`
- safety_dependency: `canonical deterministic/human Safety remains authoritative; media-origin reports must remain human-review-required even if evidence bytes are unavailable; missing canonical truth must fail closed`
- privacy_boundary: `participant/Conversation identifiers and raw safety media are excluded from the model payload, but current free-form evidence may contain sensitive information; external-provider sensitive-evidence enablement remains on HOLD until minimization/redaction and trust-boundary proof are accepted`
- evaluation_status: `AUTHORITY TESTED; privacy/safety/provider failure PARTIAL; injection/multilingual/live-runtime proof MISSING; T-A03-002 active and T-A05-001 rates A03 NOT PRODUCTION READY`
- exact_proof_sha: `UNKNOWN for current main; historical Agent Systems closure evidence is not current-main production proof`
- deployment_status: `DEPLOYED CODE PRESENT ON KNOWN LIVE PHOENIX SHA; SENSITIVE-EVIDENCE EXTERNAL-PROVIDER ENABLEMENT HOLD; ACTIVATION NOT PROVEN`
- deployed_sha: `2724d655a1ab7502c0caa39c91644cd6559a5f96`
- activation_status: `UNKNOWN / NOT PROVEN ACTIVE; sensitive-evidence external-provider path = HOLD`
- production_proof_status: `NOT PROVEN / T-A05-001: NOT PRODUCTION READY`
- open_dependencies: `T-A03-002 canonical review/evidence-state proof; T-A10 privacy/trust-boundary closure for external sensitive evidence; T-A04 provider/runtime failure isolation; T-A05 independent privacy/injection/multilingual proof; T-A09/Construction activation proof`
- historical_predecessors: `historical Safety Agent and Safety Intelligence concepts; enforcement responsibilities remain deterministic/human rather than inherited by A03`
- retirement_state: `NONE — CURRENT ADVISORY CAPABILITY`
- last_verified_date: `2026-09-04`
- evidence_refs: `lib/strangertalks_new/agent_systems/safety_review_assistant.ex; test/strangertalks_new/agent_systems_functional_test.exs; T-A03-002; T-A05-001; T-A04-001`

## A04 — Trend / Bridge Research

- id: `A04`
- name: `Trend / Bridge Research`
- primary_owner: `T-A01 — Conversation Assistance & Bridge Intelligence`
- collaborators: `T-A04 runtime/provider, T-A05 evaluation, T-A06 governance, T-A09/Construction activation proof`
- organizational_status: `CURRENT`
- implementation_kind: `BOUNDED RESEARCH CAPABILITY`
- runtime_status: `IMPLEMENTED NON-PUBLIC OPERATOR RESEARCH CAPABILITY`
- source_sha: `20293425b0556d733f47d43714d236582df7948d` (same substantive source tree as `423442915e37fd6aadd25bd1c6a300eed2b464f0`)
- provider: `shared StrangertalksNew.Companion.OpenAIProvider`
- input_data_classes: `explicit operator-supplied supported language and bounded current/cultural/conversational signals; no autonomous participant dossier collection`
- output_contract: `candidate Conversation Bridges/research material for review; no publication or live-injection authority`
- positive_authority: `research/candidate generation only`
- forbidden_authority: `autonomous publication, live Conversation injection, autonomous browsing unless separately authorized, catalog mutation, deployment`
- safety_dependency: `research output remains subordinate to Safety/content review and cannot override deterministic Safety`
- privacy_boundary: `operator-supplied bounded signals only; no authority to fetch private participant data or build participant profiles`
- evaluation_status: `AUTHORITY TESTED; privacy/safety/provider failure PARTIAL; cultural/freshness, prompt-injection, multilingual, deployment and live-runtime proof incomplete; T-A05-001 rates A04 NOT PRODUCTION READY`
- exact_proof_sha: `UNKNOWN for current main; historical Agent Systems closure evidence is not current-main production proof`
- deployment_status: `DEPLOYED CODE PRESENT ON KNOWN LIVE PHOENIX SHA; CAPABILITY ACTIVATION NOT PROVEN`
- deployed_sha: `2724d655a1ab7502c0caa39c91644cd6559a5f96`
- activation_status: `UNKNOWN / NOT PROVEN ACTIVE`
- production_proof_status: `NOT PROVEN / T-A05-001: NOT PRODUCTION READY`
- open_dependencies: `T-A01 domain-quality work; T-A04 provider/runtime failure isolation; T-A05 independent cultural/freshness/injection/multilingual proof; T-A09/Construction activation proof`
- historical_predecessors: `historical Trend Intelligence, Category/Language/Complexity/Confidence/Context and Icebreaker Lead responsibilities where relevant; historical identities are not current runtime Agents`
- retirement_state: `NONE — CURRENT RESEARCH CAPABILITY`
- last_verified_date: `2026-09-04`
- evidence_refs: `lib/strangertalks_new/agent_systems/trend_bridge_research.ex; lib/mix/tasks/strangertalks.agents.ex; test/strangertalks_new/agent_systems_functional_test.exs; T-A01; T-A05-001; T-A04-001`

# Current normative sources

Current governance claims should be interpreted using this precedence:

1. owner laws and explicit owner decisions;
2. accepted Agent Command decisions, including the T-A06-002 A02 resolution;
3. canonical repository/runtime evidence for implementation facts;
4. this registry for current Agent identity, taxonomy, ownership and recorded lifecycle status after Agent Command acceptance;
5. current specialist-team proof for their owned open dependencies.

A current repository document that contradicts a later accepted Agent Command decision is not silently rewritten into authority. Its stale claim remains evidence of an earlier state until the owning team reconciles it.

# Historical evidence

Historical Agent documents, old organization charts, old Agent names, previous model-backed implementations and old proof SHAs remain historical evidence. They may explain design intent and lineage, but they do not grant current authority.

In particular:

- historical Matchmaking Lead / Queue / Compatibility / Opportunity / Scarcity Agent identities are not current model/runtime Agents;
- historical Icebreaker Lead / Category / Language / Complexity / Confidence / Context / Learning Agent identities are not automatically current runtime Agents;
- historical Safety Agent does not supersede deterministic/human Safety;
- historical Stewardship/HCIL runtime-master concepts do not supersede Agent Command/human governance;
- historical `AgentSystems.LearningAdvisor` does not supersede the current deterministic A02 V1 path.

# Contradiction ledger

| Conflict | State | Current governance truth / owner |
| --- | --- | --- |
| A02 organizational/runtime terminology | `RESOLVED BY AGENT COMMAND` | A02 organizational role current; `V1Metrics + V1Recommendations` current deterministic V1; `LearningAdvisor` runtime superseded/dormant. |
| Stale repository documentation advertising model-backed A02 as current | `OPEN — T-A02-002 ACTIVE` | Team 2 owns current-document reconciliation; Team 6 does not duplicate it. |
| Agent activation state | `OPEN — RUNTIME/OPERATIONS PROOF REQUIRED` | A01/A03/A04 activation is `UNKNOWN`; deployment/source presence is not activation proof. |
| Exact-current-main Agent proof | `OPEN` | T-A05-001 establishes gaps and historical evidence, not complete exact-current-main production proof. |
| A03 canonical review/evidence input truth | `OPEN — T-A03-002 ACTIVE` | Team 3 owns A03-side canonical review input and fail-closed evidence-state proof. |
| A03 sensitive-evidence external-provider privacy | `HOLD / T-A10 DEPENDENCY` | Do not enable/expand sensitive-evidence provider processing until minimized/redacted trust boundary is accepted and proven. |
| Provider/runtime failure isolation | `OPEN — T-A04-002 ACTIVE` | Optional Agent provider probe must not control core Phoenix availability. |
| Independent Agent evaluation | `OPEN — T-A05-001 PRODUCTION-READINESS FAILURE` | Authority is better covered than privacy/injection/multilingual/live-runtime proof; T-A05-002 is not assumed authorized merely because proposed. |
| Canonical source vs live deployment | `KNOWN DIVERGENCE` | Source main is not the live deployed SHA; both identities must remain recorded. |
| T-A06-002 accidental placeholder on main | `RESOLVED — NO NET TREE CHANGE` | Two normal commits advanced main history; compare from `4234429...` to `20293425...` has no changed files and identical tree. |

# Production and activation truth

Current recorded production lineage:

- canonical source `main`: `20293425b0556d733f47d43714d236582df7948d`
- substantive tree: `f4bb8b3b11a1b6423aaaed07664c2454995dee69`
- known live Phoenix deployed SHA: `2724d655a1ab7502c0caa39c91644cd6559a5f96`
- A01 activation: `UNKNOWN / NOT PROVEN ACTIVE`
- A02 deterministic operator use: `UNKNOWN`; model-backed LearningAdvisor is superseded and does not need activation for current V1
- A03 activation: `UNKNOWN / NOT PROVEN ACTIVE`; sensitive-evidence external-provider processing `HOLD`
- A04 activation: `UNKNOWN / NOT PROVEN ACTIVE`
- Python production Agent service: `NOT PRESENT / NOT CANONICAL` in current accepted runtime evidence

No registry entry may convert deployed source into enabled, active or production-proven status without explicit runtime/operations evidence.

# Owner law ledger

These are the current owner laws relevant to Agent governance. This registry adds no additional owner laws.

1. intelligence serves human connection;
2. Agents do not manufacture relationships;
3. Agents do not manipulate participants;
4. addiction/time-on-platform/emotional-dependence optimization is not an Agent goal;
5. relationship outcomes remain human;
6. human authorship remains human;
7. deterministic Safety remains authoritative;
8. Agents do not silently acquire fundamental product authority;
9. privacy/minimum-data boundaries remain binding;
10. Manvith remains owner authority.

# New Agent admission standard

A new Agent/capability proposal must establish all of the following before implementation authority exists:

1. concrete problem;
2. existing owner;
3. AI necessity;
4. separation necessity;
5. inputs;
6. outputs;
7. positive authority;
8. forbidden authority;
9. privacy;
10. Safety dependency;
11. runtime/provider;
12. cost/capacity;
13. failure behavior;
14. evaluation plan;
15. human benefit.

Team 6 governance recommendations are limited to:

- `ACCEPT AS AGENT CANDIDATE`
- `MERGE INTO EXISTING CAPABILITY`
- `USE DETERMINISTIC SYSTEM`
- `USE ANALYTICS`
- `USE HUMAN PROCESS`
- `REJECT`
- `OWNER DECISION REQUIRED`

A recommendation does not authorize implementation, deployment or activation.

# Retirement standard

Canonical retirement progression:

`ACTIVE`
→ `DEPRECATED`
→ runtime callers removed/disabled
→ activation disproven
→ tests converted to non-resurrection regressions
→ documentation updated
→ history preserved
→ `RETIRED`

For A02 this lifecycle applies to the historical `LearningAdvisor` **MODEL RUNTIME**, not to the continuing A02 organizational learning responsibility.

# Governance regression

`test/strangertalks_new/agent_master_registry_test.exs` is the narrow normative regression for this registry. It checks current sections only and is intentionally not a ban on historical text. It guards against the following obvious drift:

- presenting `LearningAdvisor` as the current A02 V1 runtime while the current operator path explicitly rejects it;
- presenting Python as canonical production Agent runtime while FastAPI remains health-only;
- granting A03 enforcement authority;
- granting A01 Send authority;
- granting A04 publication authority.

# Cross-team ownership boundary

Team 6 consumes proven states; it does not duplicate domain work:

- `T-A02`: A02 runtime/document reconciliation;
- `T-A03`: Safety input/evidence/privacy semantics;
- `T-A04`: provider/runtime implementation, failure isolation and activation mechanics;
- `T-A05`: independent evaluation;
- `T-A09 / Construction`: deployment, activation, rollback and release proof;
- `T-A10`: Agent security/privacy/trust-boundary engineering.

# Current governance disposition

- A01: `CURRENT / BOUNDED MODEL-ASSISTED / PRODUCTION NOT PROVEN`
- A02 organizational role: `CURRENT`
- A02 deterministic V1: `CURRENT`
- LearningAdvisor model runtime: `SUPERSEDED_FOR_CURRENT_V1 / DORMANT`
- A03: `CURRENT / BOUNDED MODEL-ASSISTED SAFETY ADVISORY / SENSITIVE-EVIDENCE PROVIDER HOLD / PRODUCTION NOT PROVEN`
- A04: `CURRENT / BOUNDED RESEARCH / PRODUCTION NOT PROVEN`
- general autonomous Agent platform: `ABSENT / NOT AUTHORIZED`

This registry must be updated when accepted evidence changes any current ownership, taxonomy, authority, data boundary, runtime, deployment, activation, production-proof or retirement state.
