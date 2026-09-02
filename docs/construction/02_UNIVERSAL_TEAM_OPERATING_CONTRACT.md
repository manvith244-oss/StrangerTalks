# 02 — Universal Team Operating Contract

Status: UNIVERSAL / REQUIRED

Every StrangerTalks team, whether human or AI, must follow this contract unless an explicit higher-level decision overrides it.

## 1. Read before acting

Before proposing or changing implementation, a team must read:

- `00_CONSTRUCTION_CHARTER.md`;
- `01_REPOSITORY_TRUTH_PROTOCOL.md`;
- this operating contract;
- `04_EVOLUTION_AND_DECISION_GOVERNANCE.md`;
- `05_EVIDENCE_VERIFICATION_HANDOFF_STANDARD.md`;
- its dedicated team packet;
- relevant current code/tests/docs/branches for the owned subsystem.

A prompt summary is not a substitute for repository evidence where repository access exists.

## 2. Start from the exact assignment

Each team must restate internally:

- mission;
- exact scope;
- non-scope;
- current base ref/SHA;
- authorities it may modify;
- authorities it must preserve;
- dependencies;
- required evidence;
- explicit stop conditions.

If these are contradictory, stop and escalate instead of guessing.

## 3. Authority ownership

A team may change only the authority it owns or has been explicitly authorized to coordinate.

Examples:

- frontend presentation cannot silently redefine backend terminal truth;
- AI cannot silently become Matchmaking or Safety authority;
- route/history code cannot silently end a Conversation;
- analytics cannot become participant profiling because the metric is convenient;
- a database migration cannot weaken a safety invariant for schema convenience.

Cross-boundary work requires an explicit handoff or integration decision.

## 4. Product decision boundary

Teams may make normal implementation decisions inside an approved product contract.

Teams must stop for an owner/product decision when a change would alter, among other things:

- who may reach whom;
- anonymity or disclosure rules;
- what a Bond means;
- retention or user-visible privacy expectations;
- age eligibility;
- safety/Block/Report authority;
- whether content becomes public or portable;
- what data an AI system may consume;
- a major interaction model;
- the product wedge or dependency order.

## 5. Regression-first rule

For defects and risky behavior changes, prefer:

1. reproduce the defect;
2. add or identify a failing test/proof where practical;
3. implement the minimum coherent fix;
4. prove the focused case;
5. run surrounding regressions;
6. re-attack stale/race/failure cases;
7. run the required gate.

Do not weaken a valid test merely to obtain green CI.

If the test itself is stale, prove why and update the test contract explicitly.

## 6. Concurrency and stale-operation rule

Any feature involving realtime actions, lifecycle, async callbacks, media, network requests, multi-tab/device behavior, or durable state must consider:

- duplicate requests;
- retries;
- out-of-order callbacks;
- stale generations/epochs;
- ABA-shaped races;
- disconnect/reconnect;
- process restart;
- transaction failure;
- partial failure;
- idempotency;
- cancellation;
- conflicting simultaneous actions.

Happy-path-only proof is insufficient for authority-sensitive code.

## 7. Privacy and security rule

Never place secrets, raw private Conversation content, media payloads, unnecessary identifiers, credentials or sensitive internal state into logs, telemetry, prompts, analytics or test artifacts unless explicitly required and protected.

Use least privilege and fail closed at access/safety boundaries.

## 8. Dependency rule

Do not add a framework, service, database, queue, model, cache or cloud component because it is fashionable.

Every material dependency must answer:

- what problem exists now;
- why current primitives are insufficient;
- what new failure modes it introduces;
- what operational ownership it creates;
- how it is tested and observed;
- what trigger justifies adoption.

## 9. Evidence language

Use precise verdicts:

- PROVEN
- PARTIALLY PROVEN
- NOT PROVEN
- FAILED
- BLOCKED
- SUPERSEDED

Do not say "done", "production-ready", "safe", "scalable" or "verified" without defining what was actually proven.

## 10. No invisible cleanup

Do not opportunistically refactor unrelated code during narrow authority work unless necessary for correctness. If broader cleanup is justified, separate it into a deliberate change.

## 11. Handoff requirement

Every completed work packet must report:

- exact input SHA;
- exact output SHA;
- files changed;
- behavior changed;
- behavior explicitly unchanged;
- tests run and outcomes;
- unresolved risks;
- downstream teams affected;
- migration/deployment notes;
- verdict.

## 12. Evolution clause

The current goal and architecture may evolve. A team may propose evolution, but must distinguish:

- implementation improvement inside current law;
- architecture evolution;
- product-law change;
- owner decision required.

Never silently reinterpret yesterday's contract to match today's code.
