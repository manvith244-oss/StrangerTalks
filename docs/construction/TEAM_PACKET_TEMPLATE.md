# StrangerTalks Dedicated Team Packet Template

Status: TEMPLATE

Use this template for every construction team or temporary specialist workstream.

---

# TEAM <ID> — <NAME>

## 0. Evolution Clause

This packet describes the best current construction assignment. The eventual StrangerTalks end-state may evolve. The team may propose evidence-backed improvements, but must not silently change current product law, safety boundaries, cross-team authority, or scope. Product-law changes require explicit governance; architecture changes require the appropriate ADR/review.

## 1. Mission

One paragraph describing the outcome this team exists to produce.

## 2. Why this team exists now

Explain the current dependency/problem and why it is prioritized now.

## 3. Required universal documents

List the construction documents every team must read.

## 4. Current repository truth

Include:

- repository;
- exact current construction baseline SHA;
- important alternate branches/PRs to inspect;
- known salvage/conflict candidates;
- known superseded branches;
- relevant architecture/product docs.

Do not imply that only the base branch matters.

## 5. Owned authority

Explicitly list state, modules, protocols and product behavior this team may change.

## 6. Authorities to preserve

List neighboring authorities the team must not redefine.

## 7. Scope

Concrete tasks.

## 8. Non-scope

Concrete exclusions.

## 9. Technical domains

Classify relevant technologies from `06_TECHNOLOGY_DECISION_FRAMEWORK.md`.

Example:

```text
Elixir/Phoenix: ACTIVE NOW
PostgreSQL: ACTIVE NOW
Redis: EVALUATE — no adoption without measured trigger
Kafka: NOT JUSTIFIED
Python: not owned by this team
```

## 10. Required invariants

State the laws that must remain true before and after implementation.

## 11. Failure and adversarial cases

Enumerate races, failures, abuse or edge cases that are part of the assignment.

## 12. Dependencies

Upstream teams, downstream teams, APIs/contracts and decision dependencies.

## 13. Required implementation deliverables

Files/services/migrations/contracts/docs expected.

## 14. Required tests and evidence

Focused tests, integration/browser/concurrency/performance/security evidence, exact-SHA gate, clean tree.

## 15. Stop conditions

Examples:

- product decision required;
- branch authority conflict;
- legal/privacy contradiction;
- need to weaken a valid safety invariant;
- need to change another team's owned protocol;
- missing reproducible baseline.

## 16. Handoff format

Use `05_EVIDENCE_VERIFICATION_HANDOFF_STANDARD.md`.

## 17. Integration instructions

State how T0 Integration should consume the work and what shared seams need re-testing.

## 18. Reconsideration triggers

What future evidence or scale should cause this packet's architecture to be revisited?
