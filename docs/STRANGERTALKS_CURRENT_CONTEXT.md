# StrangerTalks — Current Project Context

## Current checkpoint

**Agent Systems A01–A04 — closure candidate.**

The historical multi-Agent swarm is superseded. Canonical runtime boundaries are defined in `docs/AGENT_SYSTEMS_V1_BOUNDARIES.md`.

## Canonical Agent inventory

- **A01 — Conversation Companion:** participant-invoked, bounded current-Conversation assistance; suggestions/draft only; no Send or product mutation authority.
- **A02 — Learning Advisor:** internal/offline recommendations from aggregated/system analytics only; no silent production mutation.
- **A03 — Safety Review Assistant:** contextual recommendation for an existing Report; no Block/ban/report-state mutation; severe/media cases require human review.
- **A04 — Trend / Bridge Research:** operator-supplied current signals to candidate Conversation Bridges; no automatic publication or live Conversation injection.

Historical Queue, Compatibility, Opportunity, Scarcity, Matchmaking Lead, Category, Language, Complexity, Confidence, Icebreaker Lead, Safety, Learning, Stewardship and HCIL Agent identities remain absorbed into deterministic services, content rules, analytics, or human/product governance. There is no generic Agent Router/Executor/Decision Bus and no always-on Flow/Trust/intimacy surveillance layer.

## Verified conversation features

1A — Reply / Quote: VERIFIED COMPLETE
1B — Emoji Reactions: VERIFIED COMPLETE
1C — Session Pinned Messages: VERIFIED COMPLETE
1D — GIFs & Stickers: VERIFIED COMPLETE
1E — Voice Note Experience: VERIFIED COMPLETE
1F — Conversation Presence: VERIFIED COMPLETE
1G — Quiet Mode: VERIFIED COMPLETE
1H — Atmosphere / Chat Themes: VERIFIED COMPLETE
1I — Ambient Audio: VERIFIED COMPLETE
1J — Conversation Prompt Cards: VERIFIED COMPLETE
Ephemeral Conversation UX: VERIFIED COMPLETE.

Conversational Polls (1K) remains a separate product-roadmap feature and is not part of Agent Systems closure.

## Architecture map

Browser: `priv/static/assets/app.js` + IndexedDB (`local_data.mjs`) manages composer/timeline/local state and the A01 Companion UI.

Socket surface: `UserSocket`, `ParticipantChannel`, `ConversationChannel` validates and rate-limits realtime participant actions.

Realtime authority: `ConversationLifecycle.ConversationServer` owns ephemeral message delivery, epoch/sequence authority, replay/pruning, presence and Conversation Start lifecycle.

Persistence: Ecto/Postgres owns durable Conversation/Match/Relationship/Safety/analytics metadata. Live Conversation text remains ephemeral rather than being copied into a transcript table.

Agent model boundary: `Companion.OpenAIProvider` is the only provider-specific runtime surface. A01 uses generation + critic + moderation. A02–A04 use the shared schema-constrained `AgentSystems.Provider.structured/5` boundary. Requests use `store: false` and no model tools.

Operational internal agents: `mix strangertalks.agents learning`, `mix strangertalks.agents safety REPORT_ID`, and `mix strangertalks.agents trends LANGUAGE ...`.

## Deterministic authorities Agents cannot override

- Matchmaking final authority: `Matchmaking.MatchmakingEngine` under `ParticipantActivityLock`.
- Durable safety veto / boundary enforcement: deterministic `MatchingRules` and canonical safety services.
- Conversation Language: persisted Match authority (`en`, `te`, `hi`).
- Conversation Start: curated `IcebreakerCatalog` / ConversationServer authority.
- Participant message authorship: ordinary Send boundary only.
- Recovery: persisted Conversation/Match state + ConversationServer lifecycle rules.

## Privacy / safety rules

Product content must not enter ordinary logs or telemetry. Agent payloads are minimized per task. Historical readiness/psychological fields are not active Agent inputs. No Agent may infer hidden participant state as authoritative fact, relax a Block/safety invariant, silently mutate production behavior, or impersonate a participant.

## Agent Systems closure evidence

`.github/workflows/a01-conversation-companion.yml` is the **Agent Systems Closure Gate**. A valid completion claim requires an exact-feature-SHA checkout proof, focused A01–A04 functional/adversarial tests, browser authorship/draft tests, full `mix precommit`, and a clean-checkout proof after precommit.

## Runtime configuration

A01 live model calls require `COMPANION_ENABLED=true` and `OPENAI_API_KEY`.

A02–A04 live model calls require `AGENT_SYSTEMS_ENABLED=true` and the same provider credential. Optional model overrides are `COMPANION_MODEL` and `AGENT_SYSTEMS_MODEL`.

If the provider is disabled/unavailable, model-backed assistance fails independently; human Conversation and deterministic product authorities continue.

## Known unrelated technical debt

Dependency audit currently reports existing security advisories in the pinned Bandit/Postgrex dependency set. These are infrastructure/dependency remediation items rather than Agent authority design and should be handled as separate release hardening work.
