# 03 — Orchestration and Prompt Chain

Status: UNIVERSAL / REQUIRED

## Purpose

StrangerTalks is being built through a chain of humans and AI systems. Recent work has used one model to coordinate teams, another team to answer owner questions, another team to improve the assignment prompt, and an execution agent to make GitHub changes.

That workflow is powerful, but without a formal contract it can create telephone-game drift: each layer can accidentally add requirements, remove constraints, invent an owner decision, or overstate evidence.

This document turns the workflow into a durable engineering protocol.

## Durable roles

The roles are universal. The current tool/model occupying a role may change.

### R0 — OWNER

The human product authority.

Owns:

- product thesis;
- constitutional product-law changes;
- value judgments where evidence cannot decide;
- acceptance of meaningful scope changes;
- final decisions on unresolved product conflicts.

The Owner should not be required for routine implementation choices that remain inside an already approved contract.

### R1 — ORCHESTRATOR

Current implementation may be Claude or another capable coordinator.

Responsibilities:

- convert Owner Intent into workstreams;
- identify dependencies and ownership;
- choose which specialist teams are required;
- maintain the construction graph;
- ask only questions that genuinely require owner input;
- collect team outputs;
- detect conflicts rather than silently merging them;
- issue bounded assignments.

The Orchestrator is **not** automatically product authority and must not invent owner preferences.

### R2 — OWNER PROXY

A dedicated reasoning role that answers routine questions using the Owner Constitution, explicit historical decisions and current construction documents.

This role exists to prevent the human owner from becoming a bottleneck for questions already answered by established law.

The Owner Proxy may answer only when the answer is derivable from existing owner decisions or explicitly delegated policy.

Every answer must conceptually fall into one of these classes:

- `OWNER_DECISION_ALREADY_ESTABLISHED`
- `IMPLEMENTATION_DISCRETION`
- `EVIDENCE_CAN_DECIDE`
- `OWNER_DECISION_REQUIRED`

The Owner Proxy must never fabricate a preference merely to keep work moving.

If confidence is insufficient or two owner laws conflict, return `OWNER_DECISION_REQUIRED` with the smallest possible question.

### R3 — PROMPT COMPILER

This is the team's "reframe the whole prompt" role.

Its job is not to creatively reinterpret the assignment. It compiles a reliable execution packet.

The Prompt Compiler must:

- preserve the original goal;
- remove ambiguity that can be resolved from universal docs/repo evidence;
- include exact base ref/SHA where available;
- include relevant product laws;
- state owned boundaries and forbidden boundaries;
- include repository archaeology requirements where applicable;
- include dependencies and expected handoffs;
- include verification and proof gates;
- include stop conditions;
- include the Evolution Clause;
- separate requirements from suggestions;
- explicitly mark unresolved decisions rather than filling them in.

The Prompt Compiler must not:

- expand scope for sophistication;
- introduce technologies not justified by the task;
- change a product decision;
- weaken tests;
- convert a hypothesis into a requirement;
- turn an unproven branch into canonical truth.

### R4 — EXECUTION TEAM

The coding/research/design agent or human team that performs the assignment.

For repository work it must:

- inspect actual repository evidence;
- work on the exact authorized branch/worktree;
- implement only owned changes;
- test;
- produce exact-SHA evidence;
- hand off instead of self-declaring broad completion.

### R5 — VERIFIER / BREAK TEAM

Independently attacks the result.

Responsibilities may include:

- regression review;
- hostile concurrency tests;
- security/privacy review;
- browser/device testing;
- architecture contradiction check;
- diff audit;
- exact-SHA identity proof;
- confirmation that tests were not weakened;
- comparison against branch salvage ledger.

For release-critical authority, Executor and Verifier should be separate roles even if they use the same underlying model at different times.

### R6 — INTEGRATION AUTHORITY

Owns composition of accepted work into the canonical construction candidate.

It must preserve multiple specialist authorities simultaneously and may not resolve true product contradictions by merge mechanics alone.

## Current role mapping

A current practical mapping may be:

- Manvith → R0 Owner
- Claude coordinator → R1 Orchestrator
- dedicated ChatGPT/Claude "Manvith proxy" team → R2 Owner Proxy
- dedicated prompt-reframing team → R3 Prompt Compiler
- ChatGPT/Codex/GitHub execution team → R4 Executor
- separate Break/Closure teams → R5 Verifier
- dedicated integration/release team → R6 Integration Authority

This mapping is replaceable. The protocol is not.

## Canonical information flow

```text
OWNER INTENT
    |
    v
ORCHESTRATOR
    |-- reads Universal Construction Docs
    |-- reads current work graph
    |-- queries Owner Proxy only for established policy
    |-- escalates true product decisions to Owner
    v
ASSIGNMENT DRAFT
    |
    v
PROMPT COMPILER
    |-- preserves intent
    |-- grounds branch/SHA/scope
    |-- adds proof + stop conditions
    |-- removes accidental ambiguity
    v
EXECUTION PACKET
    |
    v
EXECUTION TEAM
    |-- repo-grounded work
    |-- focused proof
    v
HANDOFF PACKET
    |
    v
VERIFIER / BREAK TEAM
    |-- independent attack
    v
INTEGRATION AUTHORITY
    |-- compose or reject
    v
NEW CONSTRUCTION BASELINE
    |
    +----> Universal docs / ADR / ledger updated if truth changed
```

## Owner Proxy contract

The Owner Proxy should be backed by a concise Owner Constitution rather than vague personality imitation.

It should know:

- current product laws;
- prior explicit owner decisions;
- risk tolerance expressed by the owner;
- current product dependency order;
- what decisions have deliberately been left open.

It should not guess personal preference from tone.

### Required response shape for owner-proxy decisions

```text
CLASSIFICATION: <one of four classes>
DECISION: <answer if established>
BASIS: <specific product law / explicit prior decision / technical delegation>
CONFIDENCE: HIGH | MEDIUM | LOW
OWNER REQUIRED: YES | NO
IF YES: <one minimal question>
```

This can be machine-readable later if useful.

## Prompt Compiler output contract

Every execution prompt should contain, in this order where relevant:

1. Role and mission
2. Exact repository / branch / SHA
3. Why the work exists
4. Current truth to preserve
5. Scope
6. Explicit non-scope
7. Owned authorities
8. Dependencies / upstream inputs
9. Branches or PRs that must be inspected
10. Required implementation behavior
11. Safety/privacy constraints
12. Concurrency/failure cases
13. Testing / proof requirements
14. Handoff format
15. Stop conditions
16. Evolution Clause

The prompt should be long when the risk justifies it, not long for ceremony.

## Prompt integrity checks

Before a prompt reaches an Executor, the Prompt Compiler asks:

- Did I preserve the original objective?
- Did I add a product decision that nobody approved?
- Did I erase a stop condition?
- Did I imply `main` is canonical?
- Did I confuse a suggestion with a requirement?
- Did I require a technology merely because it is in the architecture vocabulary?
- Did I accidentally grant the Executor integration or release authority?
- Is the branch/SHA current enough for this task?
- Does the assignment explain how to prove completion?

## Conflict protocol

If Orchestrator, Owner Proxy, Prompt Compiler or Executor detect contradictory laws:

1. do not silently choose one;
2. identify both authorities and their evidence;
3. classify the conflict as implementation, architecture, product or safety/legal;
4. resolve implementation conflicts at the lowest owning role possible;
5. escalate genuine product value choices to Owner;
6. record the decision.

## Context compression rule

Not every prompt should contain every StrangerTalks document.

Universal documents act as shared law. Dedicated prompts should reference them and include only the task-specific clauses necessary to prevent drift.

This reduces token waste while keeping the system consistent.

## Failure mode this system is designed to prevent

Without this protocol:

```text
Manvith says A
Claude interprets A+B
Owner-proxy invents C
Prompt team makes it A+B+C+D
Executor builds D
Verifier proves D works
...but nobody built A.
```

A technically perfect answer to the wrong assignment is still failure.

## Evolution clause

Models, providers and tooling will change. Claude may be replaced. ChatGPT may occupy a different role. Some roles may eventually be automated through APIs or an internal control plane.

The durable requirement is that intent, authority, compilation, execution, verification and integration remain distinguishable and auditable.
