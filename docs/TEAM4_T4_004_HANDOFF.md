# T4-004 — Cross-Team Matchmaking Concurrency Defect Handoff

## Status

**HIGH / RELEASE BLOCKER**

Primary owner: **Team 2 — Matchmaking & Human Connection**  
Affected verifier: **Team 4 — Safety, Privacy & Human Agency**  
Team 4 re-attack after accepted fix: **REQUIRED**

## Exact failing reproduction

Validated on Team 4 candidate SHA:

`4d8771820622fda11ef9867f3cd94ffb0827510e`

GitHub Actions Team 4 gate:

`32718993358`

Full `mix precommit` result on that SHA:

- 653 tests
- 652 passed
- 1 failed

Failing regression:

`StrangertalksNew.Matchmaking.MatchmakingEngineTest`

`Dynamic Matrix Pipeline Verification independent A-B and A-C admissions race with exactly one winner`

Location at the failing SHA:

`test/strangertalks_new/matchmaking_engine_test.exs:713`

## Scenario

Three queued participants exist: A, B, and C.

Two independent evaluations are staged so one evaluates A-B and the other evaluates A-C. Both admissions are then allowed to proceed concurrently.

## Expected

Participant A may appear in **at most one authoritative successful Match/Conversation**.

Exactly one of A-B or A-C may win. The losing peer must remain eligible according to the existing matchmaking contract.

## Actual

The failing execution persisted **two durable Matches** approximately milliseconds apart. Both Matches contained the same participant A, paired once with B and once with C.

The failure was not a UI projection problem and not merely duplicate event delivery: two database Match rows existed.

## First divergence

**Matchmaking admission/evaluation serialization boundary.**

`evaluate_pending_matches/0` takes a QueueState snapshot and can be invoked concurrently. Pair-level persistence later enters the participant activity lock, but the hostile A-B/A-C execution demonstrated that the current end-to-end admission boundary did not guarantee the V1 invariant under that timing.

This handoff intentionally does **not** prescribe Team 2's implementation mechanism.

## Ownership rule

Team 4 must not patch or redesign MatchmakingEngine serialization in PR #8.

Team 4 preserves this reproduction and treats the defect as release blocking until Team 2/Command provides an accepted correction and Team 11 supplies an integration candidate containing both teams' changes.

## Permanent regression requirement

Retain a repeatable concurrent **A-B vs A-C admission** attack that requires:

- exactly one durable Match;
- exactly one durable Conversation;
- A appears in that one winner only;
- no duplicate Conversation authority;
- the losing peer remains in the canonical post-race state;
- subsequent evaluation does not create a second Match involving already-consumed A.

Do not weaken this regression to probabilistic assertions.

## Team 4 integrated re-attack after Team 2 correction

On one exact integrated validation SHA, Team 4 must re-run:

- T4-004 A-B/A-C concurrency regression;
- Block vs Match, both hostile orderings;
- Cancel vs Match where relevant to the Safety boundary;
- BoundaryBlock vs recovery;
- focused Team 4 Safety/Privacy tests;
- browser privacy/media/stale-state tests;
- `mix hex.audit`;
- full `mix precommit`;
- `git diff --check`;
- clean-tree proof.

Team 4 must not combine green evidence from different SHAs to close this blocker.
