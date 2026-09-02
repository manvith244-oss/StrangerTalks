# 05 — Evidence, Verification and Handoff Standard

Status: UNIVERSAL / REQUIRED

## Principle

A completion claim is only as strong as the evidence attached to the exact code being claimed.

## Evidence ladder

Use the strongest relevant evidence available:

1. static source inspection;
2. focused unit tests;
3. property/adversarial tests;
4. database/integration tests;
5. process/restart/concurrency tests;
6. real browser tests;
7. multi-browser/multi-participant tests;
8. network/WebRTC/TURN tests;
9. load/performance tests;
10. release artifact/container proof;
11. staging proof;
12. production smoke/operational proof.

Not every task requires every layer. Authority-sensitive tasks require more than static inspection.

## Exact-SHA rule

Whenever a team says an exact candidate is PROVEN, record:

- repository;
- branch;
- candidate SHA;
- tested SHA;
- whether they are identical;
- commands/workflows run;
- results;
- post-test working-tree state.

A green test on an earlier SHA is historical evidence, not proof of a later SHA.

## Clean-tree rule

For release/integration-critical proof, verify that tests or formatters did not silently modify source files.

Recommended evidence includes:

- `git diff --check`;
- `git status --short`;
- exact checkout identity;
- clean tree after required gates.

## Test integrity

When a failing test is changed, handoff must state whether the change is:

- TEST FIX — test no longer represented current valid contract;
- PRODUCT CONTRACT CHANGE — behavior intentionally changed;
- HARNESS FIX — test environment/selector/timing was wrong;
- TEST EXPANSION — new case added;
- TEST WEAKENING — prohibited unless explicit product decision makes the old assertion invalid and replacement coverage is stronger/equivalent.

## Concurrency proof

Concurrency-sensitive systems should prefer deterministic synchronization, barriers, locks, controlled callbacks, process monitoring or repeated stress over arbitrary sleeps.

Test at least relevant combinations of:

- simultaneous operations;
- duplicate operations;
- stale operation arriving late;
- persistence failure between phases;
- retry after ambiguous response;
- disconnect/reconnect;
- second tab/device;
- server/process restart;
- new Conversation/session replacing an old one.

## Browser proof

Browser-sensitive claims should distinguish:

- DOM/unit simulation;
- headless real browser;
- multiple isolated browser contexts;
- responsive viewport emulation;
- real device.

Do not claim real-device proof from desktop emulation.

## Performance proof

Performance work must define:

- workload;
- hardware/environment;
- concurrency;
- dataset size;
- warm/cold state;
- percentile metrics;
- error rate;
- saturation behavior;
- bottleneck;
- comparison baseline.

"Fast" without a workload and metric is not proof.

## Security/privacy proof

Security/privacy handoffs should include relevant checks for:

- authorization bypass;
- cross-context identity leakage;
- stale access after revocation/Block;
- log/telemetry content;
- secrets handling;
- retention/deletion;
- upload/content validation;
- rate limits;
- replay/idempotency;
- model/AI payload minimization where applicable.

## Required handoff packet

Every meaningful team delivery should use this structure:

```text
TEAM:
MISSION:
INPUT BRANCH/SHA:
OUTPUT BRANCH/SHA:
VERDICT: PROVEN | PARTIALLY PROVEN | NOT PROVEN | FAILED | BLOCKED

SUMMARY:

FILES CHANGED:

BEHAVIOR CHANGED:

BEHAVIOR EXPLICITLY UNCHANGED:

PRODUCT / ARCHITECTURE DECISIONS MADE:

TESTS / WORKFLOWS RUN:
- command or workflow
- result
- exact SHA

ADVERSARIAL / FAILURE CASES COVERED:

KNOWN UNPROVEN AREAS:

RISKS / DEBT:

DEPENDENCIES / DOWNSTREAM IMPACT:

BRANCH ARCHAEOLOGY / SALVAGE NOTES:

OWNER DECISION REQUIRED:

INTEGRATION INSTRUCTIONS:

ROLLBACK / MIGRATION NOTES:
```

## Integration acceptance

Integration Authority must verify at minimum:

- the work is based on an acceptable lineage;
- no newer authority is overwritten;
- conflicts were resolved semantically, not by blindly taking a file version;
- tests still represent current contracts;
- cross-team gates relevant to the shared seam remain green;
- the salvage ledger is updated when branch status changes.

## Final wording standard

Prefer precise statements:

- "Focused tests pass on SHA X."
- "Real Chromium path proven."
- "Production behavior not yet verified."
- "Branch contains implementation but has not been integrated."

Avoid ceremonial certainty.

## Evolution clause

Evidence requirements may grow as StrangerTalks becomes more distributed, regulated or operationally complex. The standard should evolve upward with risk rather than forcing every early feature to carry enterprise-scale ceremony.
