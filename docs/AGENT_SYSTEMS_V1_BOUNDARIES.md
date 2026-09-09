# StrangerTalks Agent Systems — Canonical Runtime Boundaries

Status: current Agent Systems authority ledger on `main`, preserving the historical `feature/a01-conversation-companion` lineage where it remains useful evidence.

The earlier release remediation correctly removed the historical multi-Agent swarm from V1. Four bounded capability identities were later documented, but current V1 authority must distinguish organizational responsibility from model execution. This document is the current authority ledger for what is an Agent responsibility, what is not, and what each capability may do.

## Canonical Agent inventory

### A01 — Conversation Companion

Participant-invoked, user-visible advisory assistant inside an existing Conversation.

- Explicit invocation only; no continuous semantic surveillance.
- Receives only bounded current-Conversation context and the participant's explicit draft/request.
- Uses generation -> independent critic -> moderation -> deterministic validation -> authority revalidation.
- Can suggest text; cannot send, queue, match, block, report, change a Relationship, or mutate configuration.
- `Use in draft` is local composer assistance only; ordinary human Send remains the authorship boundary.

Detailed contract: `docs/A01_CONVERSATION_COMPANION.md`.

### A02 — Organizational Learning Advisor

Current organizational learning responsibility over deterministic, privacy-safe V1 evidence and recommendations.

- `StrangertalksNew.Intelligence.V1Metrics` is the current read-only aggregate evidence owner.
- `StrangertalksNew.Intelligence.V1Recommendations` is the current deterministic analysis/recommendation implementation.
- A02 interprets evidence, develops hypotheses/recommendations and preserves organizational-learning responsibility; it does not imply model execution.
- A02 has zero authority to change matchmaking thresholds, Conversation Start content, safety rules, runtime configuration, code or deploys.
- Every recommendation remains evidence for human/Agent Command review and requires a separately authorized product change before production behavior can change.
- Current V1 A02 organizational learning uses no model provider.

Historical model-backed implementation:

`StrangertalksNew.AgentSystems.LearningAdvisor`

is classified `SUPERSEDED_FOR_CURRENT_V1`. It may remain compiled for historical/test compatibility, but its existence does not make it current authority and it must not be reactivated without a separately authorized model-necessity case.

### A03 — Safety Review Assistant

Internal contextual assistant for an already-created canonical `Report`.

- Receives report category/status, bounded textual evidence and only a boolean indicating whether safety media is attached.
- Participant IDs, Conversation IDs and raw safety media are outside its model payload.
- Produces severity/action recommendations only.
- HIGH/CRITICAL recommendations, permanent-ban recommendations and media-bearing reports must require human review.
- It cannot write `Report`, `SafetyReview`, `BoundaryBlock`, Matchmaking or participant restriction state.
- Deterministic boundary enforcement remains authoritative and is never relaxed by model output.

### A04 — Trend / Bridge Research

Internal research Agent that turns explicit current signals into candidate Conversation Bridges.

- Supports canonical Conversation languages `en`, `te`, `hi`.
- Current cultural/seasonal/sports/shared-life signals are supplied explicitly by operations; the Agent has no autonomous web-browsing authority.
- Produces Universal/Broad/Niche research candidates.
- Has no publication authority and cannot write `IcebreakerCatalog` or push content into a live Conversation.
- Candidate publication remains a reviewed content change.

## What is NOT an Agent

The following historical names remain absorbed into explicit deterministic owners and must not be resurrected as autonomous runtime identities:

- Matchmaking Lead Agent -> `Matchmaking.MatchmakingEngine`
- Queue Intelligence Agent -> QueueState / MatchmakingEngine
- Compatibility Agent -> MatchmakingEngine algorithm/rules
- Opportunity Agent -> Matchmaking strategy/policy
- Scarcity Agent -> Matchmaking strategy/policy
- Language Intelligence Agent -> language normalization + matching/start rules
- Icebreaker Lead / Category / Complexity / Confidence agents -> Conversation Start / curated content rules
- Safety Agent -> deterministic Safety Gate / Safety Services / designated review authority
- Learning Agent / Icebreaker Learning Agent -> deterministic analytics/recommendations under A02 organizational responsibility
- Stewardship Agent / HCIL runtime master -> human/product governance
- generic Decision Engine / Agent Priority System -> rejected
- Intern/Senior/Lead/Executive runtime hierarchy -> rejected

Elixir's OTP `Agent` state primitive is never evidence of product Agent status.

## Shared Agent constitution

1. **Safety over optimization.** No Agent can relax a deterministic safety boundary.
2. **Privacy over curiosity.** Each Agent receives the minimum data needed for its explicit task.
3. **Human authorship.** Agent output never becomes participant-authored content without an explicit human action through the ordinary product boundary.
4. **Advice is not authority.** A recommendation does not mutate production state unless a separately authorized deterministic/human workflow performs that mutation.
5. **No hidden surveillance.** There is no always-on Flow/Trust/intimacy/psychological monitoring Agent.
6. **No god-object runtime.** There is no generic Agent Router, Executor, Decision Bus or autonomous hierarchy.
7. **Fail closed.** Missing credentials, invalid schema, stale Conversation authority, unsafe output or ambiguous ownership produces no Agent result.
8. **No silent self-learning.** A02 may recommend; production changes require reviewed code/configuration.

## Shared model provider boundary

`StrangertalksNew.Companion.OpenAIProvider` is the single provider-specific runtime surface for the currently model-backed bounded services. It exposes:

- A01's dedicated `generate/1` pipeline with critic and moderation; and
- the schema-constrained `AgentSystems.Provider.structured/5` boundary used by A03 and A04.

The historical model-backed A02 implementation can still reference that shared provider as compiled compatibility, but it is `SUPERSEDED_FOR_CURRENT_V1` and is not the current organizational-learning path.

Provider requests use the Responses API, `store: false`, JSON Schema structured output and no tools. Provider credentials are environment/configuration secrets and are never committed.

Runtime flags:

- `COMPANION_ENABLED=true` enables A01.
- `AGENT_SYSTEMS_ENABLED=true` enables the current A03/A04 shared-provider operations.
- `OPENAI_API_KEY=<secret>` is required for live model calls.
- optional `COMPANION_MODEL` and `AGENT_SYSTEMS_MODEL`; default model is `gpt-5.6-luna`.
- optional `OPENAI_BASE_URL`, timeout and moderation settings remain provider configuration.

Current V1 A02 organizational learning uses no model provider. Agent/provider failure therefore cannot block the A02 deterministic V1 report; ordinary human Conversation, deterministic Matchmaking, Safety and Recovery also continue when model service is unavailable.

## Operational invocation

Non-public capabilities are intentionally not exposed through unauthenticated HTTP administration routes.

Current operators use:

```text
mix strangertalks.intelligence [hours]
mix strangertalks.agents safety REPORT_ID
mix strangertalks.agents trends LANGUAGE "signal one" "signal two"
```

Historical/superseded reference: `mix strangertalks.agents learning [limit]` previously invoked model-backed A02. It is no longer a current operator path; the Mix task returns `:learning_advisor_superseded_by_team8_v1`.

A01 remains participant-invoked through the authenticated Conversation Companion endpoint/UI.

## Deterministic authority retained from remediation

Matchmaking authority remains `Matchmaking.MatchmakingEngine` under `ParticipantActivityLock`, with persisted safety veto and active-Conversation checks immediately before atomic Match + Conversation creation.

Conversation Language remains Match-authoritative (`en`, `te`, `hi`). `IcebreakerCatalog` remains the canonical curated Conversation Start source; A01 may read the active starter but A04 cannot publish to it.

Conversation recovery reconstructs from persisted Conversation/Match state. Terminal durable Conversations are not resurrected. `ParticipantActivityLock` remains a single-node V1 serialization boundary; horizontal authoritative BEAM scaling requires a separate distributed-coordination design.

Historical readiness/psychological fields and analytics `*_agent_accuracy` naming remain non-authoritative legacy schema vocabulary.

## Closure gate

`.github/workflows/a01-conversation-companion.yml` remains the historical Agent Systems closure workflow. Current completion claims must still be grounded in exact-head tests appropriate to the changed authority surface, including focused Agent/intelligence privacy regressions and full `mix precommit`; documentation history is not runtime authority by itself.
