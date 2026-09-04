# StrangerTalks Agent Collaboration Contract V1

Status: **NORMATIVE V1 COLLABORATION CONTRACT**

Owner: **T-A08 — Agent Collaboration, Orchestration & Capability Contracts**

Governance boundary: **T-A06 owns lifecycle/deployment/activation/governance truth** in `docs/AGENT_MASTER_REGISTRY.md`. T-A08 does not create a second Agent Master Registry. T-A06-002 has produced that governance artifact on its candidate branch; this contract consumes/cross-references its Agent ownership/runtime classifications while treating acceptance, deployment, activation and governance holds as T-A06 truth. Until that registry is accepted/merged as canonical on `main`, this contract does not restate lifecycle status as an independent source of truth.

This contract turns the current safe V1 property — **NO DIRECT AGENT-TO-AGENT COLLABORATION** — into an explicit collaboration boundary. It does not authorize a new Agent, activate a dormant Agent, create an orchestrator, or create a runtime dispatch layer.

## 1. Normative rules

### Capability identity

Callable intelligence capabilities use a stable identity of the form:

`domain.capability:vN`

A capability identity names a bounded function. It does not grant lifecycle state, deployment state, product authority, or permission to call another capability.

### Semantic owner

Every capability has exactly one primary semantic owner. T-A08 owns the collaboration contract around a capability; the domain owner owns what that capability means and may recommend or return.

### Caller class

The default caller policy: **DENY**.

A caller must belong to an explicitly allowed caller class. Agent identity does not itself grant permission to invoke another Agent capability. No A01-A04 Agent caller is admitted in V1.

### Request contract

Every capability declares the exact request boundary or the authoritative implementation/document reference that bounds the request. Callers may not forward fields merely because they can access them.

### Response contract

Every capability declares the meaning and authority ceiling of its output. A response is data from the producing capability; it is not executable control instruction to another Agent.

### Data class

V1 collaboration data classes are:

- `public`
- `operational`
- `participant-private`
- `Safety-sensitive`
- `secret/prohibited`

`secret/prohibited` data is never admitted to a collaboration contract unless separately owner-authorized and security-reviewed. A caller's access does not transfer to a callee.

### Authority class

V1 authority classes are:

- `deterministic authority`
- `human-authorized action`
- `advisory`
- `research`
- `evidence`
- `provider result`

The authority class of a result never increases merely because it is forwarded, summarized, reformatted, retried, or combined with another result.

### Mutation

Default:

`mutation_authority = false`

Any exception requires separate product/owner authorization plus T-A06 governance admission. A collaboration contract alone can never create mutation authority.

### Failure semantics

Capability failure must do exactly one declared thing: fail closed, degrade to an explicitly defined non-Agent path, or return a bounded unavailable result. Failure never transfers authority to the caller, provider, fallback, or another capability.

### Deadline

Every invocation has a local deadline. Any future multi-capability workflow must additionally carry one root deadline; each downstream local deadline must be bounded by the root time remaining. A new hop never receives a fresh independent root budget.

V1 currently has no direct Agent-to-Agent workflow, so no cross-Agent root-deadline propagation is implemented or implied by this document. Existing single-capability provider timeouts remain owned by their runtime implementations.

### Cancellation / staleness

A result becomes unusable when its initiating authority disappears or the authoritative source state on which the result depends is no longer valid.

- A01 performs explicit post-provider authority/staleness revalidation.
- A02 model output has no admitted current V1 runtime caller.
- Deterministic organizational-learning output is evidence for a later review, not a live authority token.
- A03 recommendations must be consumed only by the authorized Safety/review workflow against current canonical Safety state; this contract does not claim a new post-model mutation path.
- A04 candidates remain inert research until a separately reviewed publication/content change.

Any future collaboration edge must define cancellation propagation before admission.

### Version

The version suffix is part of the contract identity. Breaking request, response, caller, data, authority, failure, or mutation changes require a new compatible migration or new major capability version. Silent contract widening is forbidden.

### Provenance

A handoff must preserve, where applicable:

- producing capability;
- capability version;
- trust/data class;
- verification state.

Agent output must not be flattened into deterministic system fact. Provider output remains `provider result` until validated by the owning capability.

### Observability

Record only privacy-safe workflow metadata needed to prove execution, such as capability ID/version, caller class, root/request lineage identifier where introduced, timing, result classification, cancellation, contract failure, and retry count. Do not log private request/response payloads merely to visualize orchestration.

## 2. V1 capability contracts

### A01 — `conversation_companion.assist:v1`

- **Semantic owner:** A01 Conversation Companion domain / Agent Command Team 1.
- **Implementation:** `StrangertalksNew.Companion` plus bounded Companion context/output/provider modules.
- **Allowed caller class:** authorized product/participant assistance path only.
- **Agent callers:** none.
- **Request contract:** authenticated participant + authoritative Conversation at the product boundary; explicit mode/tone/request/draft; server-resolved bounded current-Conversation projection as defined by `docs/A01_CONVERSATION_COMPANION.md` and `StrangertalksNew.Companion.Context`.
- **Provider projection:** authoritative language, bounded Door/mode/tone/request/draft/current transcript/starter fields only; unrelated Conversations, private account data, Safety review notes, and hidden analytics are excluded.
- **Response contract:** bounded ready/declined assistance result containing request/conversation metadata, language/mode/tone, draft fingerprint, suggestions and/or reason. Suggestions are drafts only.
- **Data class:** `participant-private` + `operational`; provider receives only the minimized projection.
- **Authority class:** `advisory`.
- **Mutation:** `mutation_authority = false`; A01 cannot send, queue, match, Block, report, mutate Relationship/Safety/configuration, or deploy.
- **Failure:** bounded Companion error/unavailable result; ordinary human Conversation and deterministic product systems continue.
- **Deadline:** existing Companion/provider local timeout configuration; no cross-Agent root deadline exists because there is no A2A edge.
- **Cancellation/staleness:** `Companion.Context.revalidate/1` invalidates a completed model result when canonical Conversation/language/Safety/runtime/transcript/starter authority changed. Request-process exit also releases the V1 in-flight Registry lock.
- **Version:** `v1`.
- **Provenance:** output remains A01 advisory output; provider generation/critic/moderation output is never product authority.
- **Observability:** current privacy-safe Companion telemetry is mode/result/latency class; no raw private payload logging is authorized by this contract.

### Historical model A02 — `learning_advisor.model:v1`

- **Semantic owner:** A02 Organizational Learning domain / Agent Command Team 2.
- **Implementation:** `StrangertalksNew.AgentSystems.LearningAdvisor`.
- **Operational status reference:** defer to `docs/AGENT_MASTER_REGISTRY.md`; the current T-A06-002 candidate classifies A02 organizational responsibility CURRENT, the deterministic V1 runtime CURRENT, and `LearningAdvisor` `SUPERSEDED_FOR_CURRENT_V1 / DORMANT`. This is a cross-reference, not T-A08 lifecycle authority.
- **Allowed caller class:** no new current-V1 runtime caller admitted.
- **Agent callers:** none.
- **Request contract:** aggregate/system-only analytics projection; personal participant/conversation/message/report-context identifiers are rejected by implementation.
- **Response contract:** hypotheses/evidence/experiment recommendations with confidence and `mutation_authority: false`.
- **Data class:** `operational`; participant-private and Safety-sensitive raw evidence are prohibited.
- **Authority class:** `advisory` + `evidence`.
- **Mutation:** `mutation_authority = false`.
- **Failure:** bounded model/validation error; current deterministic V1 organizational learning is unaffected.
- **Deadline:** provider-local timeout only if the dormant module is explicitly invoked in an authorized proof/test context; no runtime caller is admitted here.
- **Cancellation/staleness:** no current production handoff exists; any result has no live authority token and cannot mutate production.
- **Version:** `v1`.
- **Provenance:** must remain identified as historical/dormant A02 model recommendation, never deterministic V1 truth.
- **Observability:** no new runtime observability path is created by this contract.

### Current deterministic learning — `organizational_learning.recommend:v1`

- **Semantic owner:** A02 Organizational Learning domain / Agent Command Team 2.
- **Implementation:** `StrangertalksNew.Intelligence.V1Metrics` -> `StrangertalksNew.Intelligence.V1Recommendations`.
- **Kind:** deterministic organizational-learning capability; **not an Agent-to-Agent capability**.
- **Allowed caller class:** authorized operator/Agent Command organizational-learning review workflow.
- **Agent callers:** none admitted through this Team 8 contract.
- **Request contract:** privacy-safe aggregate metrics derived from canonical durable Match, Conversation, Relationship and Report state through `V1Metrics`.
- **Response contract:** deterministic recommendation/evidence packet from `V1Recommendations` for human/Command review.
- **Data class:** `operational` aggregate evidence.
- **Authority class:** `evidence` + `advisory`; deterministic computation does not equal autonomous product-change authority.
- **Mutation:** `mutation_authority = false`; final change authority remains human/Agent Command/separately authorized product work.
- **Failure:** bounded operator failure/no recommendation; no automatic fallback to the historical model A02 runtime.
- **Deadline:** synchronous operator/local execution; no Agent workflow deadline is created.
- **Cancellation/staleness:** snapshots/recommendations are evidence; callers must treat later canonical state as newer authority and must not treat an old packet as a mutation token.
- **Version:** `v1`.
- **Provenance:** preserve V1Metrics/V1Recommendations origin and the underlying aggregate snapshot period where supplied.
- **Observability:** aggregate/operator metadata only; no participant-level collaboration tracing.

### A03 — `safety_review.recommend:v1`

- **Semantic owner:** A03 Safety Review Assistant domain / Agent Command Team 3.
- **Implementation:** `StrangertalksNew.AgentSystems.SafetyReviewAssistant`.
- **Governance/input hold reference:** `docs/AGENT_MASTER_REGISTRY.md` currently records sensitive-evidence external-provider enablement on HOLD pending input-truth hardening and coordinated security closure. This collaboration contract does not lift, narrow, or override that hold.
- **Allowed caller class:** authorized operator/Safety review workflow.
- **Agent callers:** none.
- **Request contract:** existing Report category/status, bounded textual evidence, and boolean media-presence projection. Participant IDs, Conversation IDs and raw Safety media are outside the model payload. This request description is a collaboration-contract boundary, not authorization to bypass the T-A06/T-A10 provider hold.
- **Response contract:** severity, recommendation, rationale, required human-review flag, and `mutation_authority: false` after deterministic output validation.
- **Data class:** `Safety-sensitive` + `operational`; receiving callers do not acquire raw Safety evidence rights beyond their pre-existing authorization.
- **Authority class:** `advisory`.
- **Mutation:** `mutation_authority = false`; A03 cannot ban, Block, punish, terminalize, mutate Report/SafetyReview/Matchmaking, or deploy.
- **Failure:** bounded review error/unavailable result; canonical deterministic Safety continues independently and no weaker authority substitutes for it.
- **Deadline:** provider-local timeout only when separately authorized by the governing provider/security boundary; no A2A root chain is created here.
- **Cancellation/staleness:** recommendation remains advisory. Any effectful human/system action must be based on current canonical Safety/report authority; this contract creates no automatic post-model mutation path.
- **Version:** `v1`.
- **Provenance:** output remains A03 recommendation and must retain human-review requirement where validation requires it.
- **Observability:** privacy-safe invocation/result metadata only; raw report evidence is not collaboration telemetry.

### A04 — `trend_bridge.research:v1`

- **Semantic owner:** A04 Trend / Bridge Research domain / Agent Command Team 1.
- **Implementation:** `StrangertalksNew.AgentSystems.TrendBridgeResearch`.
- **Allowed caller class:** authorized operator/content-research workflow.
- **Agent callers:** none.
- **Request contract:** one canonical language (`en`, `te`, `hi`) plus 1-12 explicit operator-supplied bounded signals; no autonomous browsing and no private Conversation mining.
- **Response contract:** 3-8 bounded Universal/Broad/Niche Conversation Bridge research candidates with rationale and `publication_authority: false`.
- **Data class:** `public`/`operational` research input only; participant-private and Safety-sensitive data are prohibited.
- **Authority class:** `research`.
- **Mutation:** `mutation_authority = false`; A04 cannot publish, mutate `IcebreakerCatalog`, inject content into a live Conversation, or deploy.
- **Failure:** bounded research error/unavailable result; existing curated Conversation Start authority remains unchanged.
- **Deadline:** provider-local timeout inside the operator research call; no A2A root chain.
- **Cancellation/staleness:** candidates are inert until separately reviewed; stale/obsolete signals invalidate usefulness but never create product mutation authority.
- **Version:** `v1`.
- **Provenance:** preserve A04 research origin and language; a candidate must never be re-labeled as canonical published content until the separate publication authority acts.
- **Observability:** privacy-safe research invocation/result metadata only; input signals must not become a general behavioral tracking stream.

## 3. Provider infrastructure dependency

Provider execution is infrastructure, not Agent collaboration.

Current shared model surface: `StrangertalksNew.Companion.OpenAIProvider` implementing the bounded Companion/AgentSystems provider contracts.

- **Runtime owner:** provider/runtime organization (T-A04 boundary); Team 8 does not own provider implementation.
- **Input:** only the projection supplied by the owning capability and only where governance/security admission permits external-provider execution.
- **Output authority class:** `provider result`.
- **Product authority:** none.
- **Mutation authority:** none.
- **Agent identity:** none.
- **Collaboration edge:** none. `Axx -> provider` is an infrastructure dependency, not `Axx -> Ayy`.
- **Failure:** owning capability handles unavailable/invalid provider output according to its capability contract; provider failure never grants fallback authority.
- **Data rule:** provider access is limited to the supplied projection and does not imply database, queue, Safety, Conversation, content-publication, deployment, or tool authority.
- **Governance rule:** recording a provider dependency here does not activate or approve a provider path that T-A06/T-A10 has placed on hold.

## 4. Direct A2A V1 baseline

The following is the complete authorized V1 direct Agent-to-Agent graph:

```text
A01 -> A02 = NO EDGE
A01 -> A03 = NO EDGE
A01 -> A04 = NO EDGE

A02 -> A01 = NO EDGE
A02 -> A03 = NO EDGE
A02 -> A04 = NO EDGE

A03 -> A01 = NO EDGE
A03 -> A02 = NO EDGE
A03 -> A04 = NO EDGE

A04 -> A01 = NO EDGE
A04 -> A02 = NO EDGE
A04 -> A03 = NO EDGE
```

**NO EDGE** means:

- no direct runtime call;
- no authority delegation;
- no private-data forwarding;
- no callback edge;
- no Agent-generated capability discovery;
- no implicit permission through a shared provider;
- no permission obtained merely because two capabilities share an organizational owner.

The absence of an edge is the V1 permission state, not missing implementation work.

## 5. Direct-edge guard

`test/strangertalks_new/agent_collaboration_contract_test.exs` is the focused Team 8 guard.

It must prove:

1. this normative contract exists and freezes the required capability identities/classes;
2. the T-A06 master-registry ownership boundary and current A03 governance hold are cross-referenced rather than duplicated or weakened;
3. all twelve possible directed A01-A04 pairs remain `NO EDGE`;
4. current A01-A04 runtime source surfaces do not directly reference another Agent capability module, including grouped/leaf aliases;
5. historical model A02 remains superseded in the current operator path while `V1Metrics`/`V1Recommendations` remain the deterministic V1 learning implementation.

The shared provider module is explicitly sanitized from the static edge check because provider execution is infrastructure, not an A01 collaboration edge.

A future direct Agent-to-Agent call must not be implemented by weakening, deleting, bypassing, or path-excluding this guard. It requires a separately authorized T-A08 collaboration-admission packet and any T-A06/T-A05/T-A10 review required by the change.

## 6. Collaboration admission rule

Before changing any `NO EDGE` to an admitted edge, the proposing packet must establish at minimum:

1. demonstrated capability need;
2. why deterministic logic is insufficient;
3. why approved offline knowledge is insufficient;
4. exact caller and callee capability IDs/versions;
5. allowed caller class;
6. minimum request/response fields;
7. data classification/minimization;
8. unchanged or explicitly authorized authority boundary;
9. failure behavior;
10. root/local deadline semantics;
11. cancellation/staleness semantics;
12. loop/depth analysis;
13. latency/cost budget;
14. provenance/trust treatment;
15. adversarial evaluation plan;
16. governance review when lifecycle/authority/data scope materially changes;
17. rollback path.

Default admission result remains **DENY**.

## 7. Explicit non-authority

This document does **not**:

- activate an Agent;
- declare production deployment;
- replace T-A06 lifecycle state;
- create a second Agent Master Registry;
- create a central orchestrator/router;
- create an Event Bus;
- grant Agent-to-Agent calls;
- grant tool use;
- grant model/provider mutation authority;
- lift an external-provider or sensitive-evidence hold;
- grant autonomous planning or delegation;
- turn deterministic learning recommendations into product-change authority.

Those remain separate governed decisions.
