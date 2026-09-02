# 04 — Evolution and Decision Governance

Status: UNIVERSAL / REQUIRED

## Why this exists

StrangerTalks is not finished enough for a fake frozen master plan, and it is too complex for undocumented improvisation.

The construction system therefore distinguishes **stable law**, **current decisions**, **experiments**, and **open questions**.

## Decision layers

### L0 — Constitutional product law

Defines the kind of social system StrangerTalks is trying to be.

Examples: context before identity, mutuality before access, no automatic public social graph, voluntary contextual disclosure.

Changing L0 requires explicit Owner/Product Council authority and a documented contradiction audit.

### L1 — Product contract

Defines current behavior within the constitution.

Examples: meaning of a Bond, current Door semantics, which media capability is allowed, current language contract, age boundary, retention expectation visible to users.

Changing L1 requires explicit product approval and cross-team impact review.

### L2 — Architecture decision

Defines how a product contract is implemented across major technical boundaries.

Examples: modular monolith vs extracted service, PostgreSQL authority model, Python AI service boundary, WebSocket topology, object storage adoption.

Significant L2 changes require an ADR.

### L3 — Team implementation decision

Local design inside an approved product and architecture contract.

Examples: function boundaries, module organization, index shape, retry implementation, internal data structure.

Owning teams may decide L3 with normal engineering evidence.

### L4 — Experiment / hypothesis

Not canonical product truth.

Examples: a candidate recommendation model, alternative matching heuristic, UI experiment, possible queue technology.

Experiments must be labeled and must not silently become authority.

## Decision record states

Every meaningful unresolved decision should be one of:

- `ACTIVE`
- `PROVISIONAL`
- `EXPERIMENTAL`
- `DEPRECATED`
- `SUPERSEDED`
- `REJECTED`
- `OWNER_DECISION_REQUIRED`

## Architecture Decision Record minimum

```text
ADR ID / title
Status
Date
Decision owner
Problem
Constraints
Options considered
Decision
Why
Consequences
Migration / rollback
Security/privacy impact
Operational impact
What would cause reconsideration
Supersedes / superseded by
Evidence links / SHAs
```

## Reconsideration triggers

A current decision should be reconsidered when evidence shows one or more of:

- unacceptable reliability or latency;
- abuse economics changed materially;
- privacy or legal obligation changed;
- operational cost becomes disproportionate;
- scale invalidates the current boundary;
- team ownership becomes a bottleneck;
- dependency risk becomes unacceptable;
- product thesis changed;
- user comprehension contradicts the assumed mental model;
- a simpler mechanism can preserve the same invariants.

## Technology migration rule

A future architecture may move from modular monolith to services, PostgreSQL-only to additional stores, direct provider calls to internal model serving, or web-only to native clients.

Migration must be treated as an authority transfer, not just code movement.

For every migration define:

- old authority;
- new authority;
- dual-write/read period if any;
- conflict resolution;
- rollback;
- observability;
- data migration;
- compatibility window;
- proof that safety and access controls survive the transition.

## Product contradiction rule

When new research conflicts with current law, classify the result explicitly:

- EXTENDS
- CLARIFIES
- EXPANDS SAFE FRONTIER
- TENSION
- CONTRADICTION
- REJECT NEW CLAIM
- OWNER DECISION REQUIRED

Do not hide a contradiction by rewriting the older document.

## Open-question register

Important unanswered questions should live in a visible register with:

- question;
- why it matters;
- decision level;
- owner;
- evidence needed;
- deadline/trigger if any;
- temporary safe default.

A temporary safe default must be described as temporary.

## Evolution clause

The purpose of governance is not to slow evolution. It is to make evolution legible.

Future StrangerTalks may look materially different from today's implementation. The system is healthy when it can explain **what changed, why, who decided, what evidence moved the decision, and how existing users/data/authorities were protected during the transition**.
