# StrangerTalks Agent Systems — Canonical Runtime Boundaries

Status: canonical Agent Systems boundary on `feature/a01-conversation-companion`, superseding the earlier zero-Agent remediation note.

The earlier release remediation correctly removed the historical multi-Agent swarm from V1. After that cleanup, four bounded capabilities have now earned explicit Agent status. This document is the authority ledger for what is an Agent, what is not, and what each Agent may do.

## Canonical Agent inventory

### A01 — Conversation Companion

Participant-invoked, user-visible advisory assistant inside an existing Conversation.

- Explicit invocation only; no continuous semantic surveillance.
- Receives only bounded current-Conversation context and the participant's explicit draft/request.
- Uses generation -> independent critic -> moderation -> deterministic validation -> authority revalidation.
- Can suggest text; cannot send, queue, match, block, report, change a Relationship, or mutate configuration.
- `Use in draft` is local composer assistance only; ordinary human Send remains the authorship boundary.

Detailed contract: `docs/A01_CONVERSATION_COMPANION.md`.

### A02 — Learning Advisor

Offline/internal recommendation Agent over aggregated/system analytics.

- Reads only `AnalyticsRecord` rows with `contains_personal_data=false` and aggregation level `AGGREGATED` or `SYSTEM_ONLY` when using `advise_latest/1`.
- Direct snapshots reject participant/conversation/message/report-context identifiers.
- Produces hypotheses, evidence summaries, confidence and small reversible experiment recommendations.
- Has zero authority to change matchmaking thresholds, Conversation Start content, safety rules, runtime configuration, code or deploys.
- Any recommendation requires normal human/product review and an explicit code/configuration change before production behavior can change.

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
- Learning Agent / Icebreaker Learning Agent -> analytics pipeline plus A02 recommendations
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

`StrangertalksNew.Companion.OpenAIProvider` is the single provider-specific runtime surface. It exposes:

- A01's dedicated `generate/1` pipeline with critic and moderation; and
- the schema-constrained `AgentSystems.Provider.structured/5` boundary used by A02-A04.

Provider requests use the Responses API, `store: false`, JSON Schema structured output and no tools. Provider credentials are environment/configuration secrets and are never committed.

Runtime flags:

- `COMPANION_ENABLED=true` enables A01.
- `AGENT_SYSTEMS_ENABLED=true` enables A02-A04 through the shared provider.
- `OPENAI_API_KEY=<secret>` is required for live model calls.
- optional `COMPANION_MODEL` and `AGENT_SYSTEMS_MODEL`; default model is `gpt-5.6-luna`.
- optional `OPENAI_BASE_URL`, timeout and moderation settings remain provider configuration.

Agent failure is isolated: ordinary human Conversation, deterministic Matchmaking, Safety and Recovery continue when model service is unavailable.

## Operational invocation

Non-public agents are intentionally not exposed through unauthenticated HTTP administration routes.

Operators can use:

```text
mix strangertalks.agents learning [limit]
mix strangertalks.agents safety REPORT_ID
mix strangertalks.agents trends LANGUAGE "signal one" "signal two"
```

A01 remains participant-invoked through the authenticated Conversation Companion endpoint/UI.

## Deterministic authority retained from remediation

Matchmaking authority remains `Matchmaking.MatchmakingEngine` under `ParticipantActivityLock`, with persisted safety veto and active-Conversation checks immediately before atomic Match + Conversation creation.

Conversation Language remains Match-authoritative (`en`, `te`, `hi`). `IcebreakerCatalog` remains the canonical curated Conversation Start source; A01 may read the active starter but A04 cannot publish to it.

Conversation recovery reconstructs from persisted Conversation/Match state. Terminal durable Conversations are not resurrected. `ParticipantActivityLock` remains a single-node V1 serialization boundary; horizontal authoritative BEAM scaling requires a separate distributed-coordination design.

Historical readiness/psychological fields and analytics `*_agent_accuracy` naming remain non-authoritative legacy schema vocabulary.

## Closure gate

`.github/workflows/a01-conversation-companion.yml` is now the **Agent Systems Closure Gate**. It must:

- check out and prove the exact feature SHA;
- run focused A01/A02/A03/A04 functional and adversarial Elixir tests;
- run focused browser authorship/draft tests;
- run full `mix precommit`;
- prove precommit leaves the checkout unchanged.

No Agent Systems completion claim is valid without a green exact-head closure run.
