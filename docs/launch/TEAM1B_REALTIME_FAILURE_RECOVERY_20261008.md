# Team 1B — Realtime Failure Recovery and Reliability Evidence

**Date:** 2026-10-08 (Asia/Kolkata)  
**Mission:** Core one-to-one realtime resilience for an October 18 controlled global-access beta.  
**Status:** PARTIAL / launch core NO-GO pending failure-injection and real WebSocket proof.  
**Scope:** Read-only production review; isolated GitHub Actions tests; no main merge, production deployment, live migrations, paid resources, or live outage injection.

## 1. Canonical state

- Repository: `manvith244-oss/StrangerTalks`
- `main`: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e` (confirmed unchanged at Team 1B start)
- Inherited Team 1 tested SHA: `825e9018b35cfb70b14999050fe327d3b5aa45fd`
- Inherited branch: `team1/2026-10-08-scarcity-clock-wakeup`
- Team 1B continuation branch: `team1b/2026-10-08-failure-recovery`, forked directly from inherited SHA.
- Inherited Team 1 candidate is 10 commits ahead of main, zero behind; five changed paths.
- Cross-team branches differ from main and were **not** merged into Team 1B:
  - Team 2B: `security/team2b-launch-closure-20261008` (Hangouts retention decision document).
  - Team 3B: `audit/team3b-browser-ux-2026-10-08` (CSS and browser UX test).
  - Team 4B: `audit/team4b-staging-recovery-2026-10-08` (isolation and recovery gate document).
  - Team 5B: `docs/team5b-beta-ops-20261008` (launch operations documents).

## 2. Inherited Team 1 work preserved

Team 1's automated 15-second cross-Door scarcity re-evaluation, same-attempt reconnect, survivor requeue, the original channel regression, and the synthetic 2/10/50/100/200 participant authority matrix are preserved. Historical verified CI: https://github.com/manvith244-oss/StrangerTalks/actions/runs/37702085423 (success; focused and full precommit gates). This was a synthetic direct-engine matrix, not 200 real WebSockets.

Team 1B added two channel edge tests without replacing or weakening existing checks:

1. An expired timer from a cancelled queue attempt must never match its replacement attempt.
2. Concurrent wake-ups from two tabs of one participant must produce no duplicate Match/Conversation.

New test commit: `4945cb142a478f55037f6b739423de3665e1ce7d`. New isolated candidate CI workflow commit: `8500643a8dc0959b45d39046d872bdd05f93fe55`. Verification URL: https://github.com/manvith244-oss/StrangerTalks/actions/runs/37704249065. **Do not claim these new tests PASS unless that exact SHA's completed run reports success.**

## 3. Database failure boundaries and evidence

**Code-reviewed, failure-injection NOT RUN:**

| Boundary | Source finding | Risk/status |
|---|---|---|
| ParticipantChannel join | `ParticipantChannel.join/3` directly invokes `SessionReconciliation.reconcile/1` after tracker registration. | `Repo.all` may raise; no verified structured error or channel-survival proof. |
| Queue admission | `MatchmakingEngine.put_queue_entry/6` calls `resolve_active_conversation/1` under participant lock. | Reconciliation returns busy on a returned error, but raised adapter errors/exits have no local guard. |
| Safety veto | `MatchingRules.check_safety_veto?/2` uses `Repo.one` for BoundaryBlock and closed Relationship. | A DB error does not prove authorization bypass; it can interrupt evaluator execution. Fail-closed behavior under timed outage untested. |
| Pair persistence | `Repo.transaction` / `Ecto.Multi` inserts Match, reservations, Conversation. | Ordinary `{:error, ...}` is handled; transaction exit/exception and commit-then-lost-notification not injected. |
| Postcommit handoff | Queue deletion, telemetry and PubSub broadcast occur *after* transaction success. | Durable match may exist before channel notification, requiring on-demand reconciliation; deterministic notification-loss race not run. |
| Cancellation | `cancel_queue` with queue absent calls reconciliation. | Database exception could interrupt cancellation; customer-visible response unverified. |
| ConversationServer startup | `fetch_durable_lifecycle_state/1` rescues exceptions as `:not_found`. | Outage and actual missing Conversation can be conflated; classification and retry contract need correction/test, not a broad catch-all. |
| RecoverySweeper | Two `Repo.all` sweeps then per-row `Repo.get` / transition. | Database outage may terminate the sweeper GenServer's current pass; supervised recovery under repeated failures is unverified. |

**Non-negotiable next scenarios:** PG unavailable before join; after queue admission; safety-query timeout; lost connection mid-Multi; postcommit/pre-notification; unavailable DB during cancellation; recovery with queued live channels; repeated cycling. Use local disposable PG or certified isolated staging only. Record channel survival, no duplicates, safety, durable/transient authority, and user-facing errors. Do not log credentials or message bodies.

## 4. Recovery contract versus suspected defect

- `ConversationServer` documents ephemeral pending messages/idempotency metadata, new epoch on process loss, and a 60-second live reconnection window. No server-side transcript/replay promise may be invented.
- `SessionReconciliation.orphaned?/1` attempts `ConversationServer.ensure_started/1` for ACTIVE/PAUSED rows.
- `RecoverySweeper.sweep_orphans/0` immediately terminalizes ACTIVE/PAUSED rows with no registered runtime at sweep time, while PENDING rows have an age threshold.
- This immediate behavior is **currently intentional and regression-tested** by `recovery_restart_test.exs` and `team3_recovery_coordination_test.exs` (restart-vs-sweep authority, no terminal resurrection). It presents a deliberate sweeper/reconnect winner-takes-authority policy and may end a conversation before a later reconnect.
- Do not change the terminalization window without a founder-approved lifecycle/product contract and new tests for crash, node restart, two-party reconnect, and race with end/block.

**Failure-injection evidence:** ConversationServer single-process restart and sweeper race tests already exist; actual full-node restart / lost network / DB outage proof is NOT RUN in Team 1B.

## 5. Memory, queue and backpressure

- `RamMonitor` checks `:erlang.memory(:total)` every 5s and warns of “LRS Eviction” above a 435.2 MiB used-memory trigger; `QueueState.evict_stale_connections/0` explicitly performs **no eviction**. Treat the present response as **not a functioning backpressure mechanism**, not memory safety.
- `ParticipantConnectionTracker` synchronously calls `MatchmakingEngine.leave_queue/1` inside its GenServer for a final channel removal. Queue leave takes participant serialization locks; if another operation holds the same lock due to DB latency, unrelated tracker calls may wait. Reproduce under contention before an async rewrite because re-register versus final-cleanup ordering is security/authority sensitive.
- `RecoverySweeper` fetches all aged PENDING and all ACTIVE/PAUSED rows without limit in the shown query; volume, query plans, DB latency and sweep duration remain UNVERIFIED.
- `Hangouts.Matcher` explores combinations recursively up to configured group size and checks safety via DB queries, while `try_form/1` uses an infinite GenServer call timeout. Incompatible large queues may produce excessive work. Hangouts is additionally gated by Team 2B's privacy decision; do not expand or enable it as a performance shortcut.

**Remediation rule:** No blind eviction of connected participants, no infinite retry storm, no unsanctioned transcript persistence. Prove bounded admission, cleanup, shedding, and fairness before claiming PASS.

## 6. Real WebSocket capacity

| Synthetic users (actual live WebSockets) | Result |
|---|---|
| 20 | NOT RUN |
| 50 | NOT RUN |
| 100 | NOT RUN |
| 200 | NOT RUN |

The inherited matrix directly exercised internal matching and is not protocol-accurate WSS load. UserSocket applies source and participant rate limiting; a socket harness must distinguish intended rate-limit behavior from capacity bottlenecks. No CPU/RSS, p95 delivery, PG pool, disconnect or reconnect measurements have been acquired on this branch.

## 7. Deployment topology

`ParticipantActivityLock` uses `:global.trans` with `[node()]`. `QueueState`, `ParticipantConnectionTracker`, `Registry`, `ConversationServer` and timers are node-local. Database uniqueness is not equivalent to distributed queue/ownership safety.

Team 4B reports one configured free production Render instance. **Single-node is the required V1 operational contract; tested beta capacity is UNVERIFIED.** Explicitly prevent any rollout with multiple active Phoenix engines until a reviewed distributed design exists. Do not enable DNS clustering as if this limitation were resolved.

## 8. Current CI / local tooling

- Inherited Team 1 CI: **PASS** on `825e9018b35cfb70b14999050fe327d3b5aa45fd`, with isolated PostgreSQL, focused tests, synthetic matrix, formatting and full `mix precommit`.
- Team 1B new edge tests: validation initiated on `8500643a8dc0959b45d39046d872bdd05f93fe55`, outcome must be read from its workflow run. New workflow inherited PostgreSQL 16, Elixir 1.18.4 and OTP 27.3.4.
- Current assistant container lacks `mix` and `elixir`, and cannot clone GitHub via external DNS. It is **not** a local runtime, test, or WSS proof.
- Full GitHub Actions checkout status on the candidate, if successful, proves tests only, not environment outage behavior or global uptime.

## 9. P0/P1 blocker register

| ID | Priority | Owner | Closure condition |
|---|---|---|---|
| CORE-01 | P1 | Team 1B successor | Deterministic DB outage matrix shows safe fail-closed behavior, bounded errors, no stale queues/duplicate matches. |
| CORE-02 | P1 | Team 1B successor | Postcommit lost-notification/startup failure races reconciled and reported to clients; no false ACKs. |
| CORE-03 | P1 | Team 1B successor + Team 4B | Actual single-node restart, sweeper race, browser reconnect truth tested at one exact SHA. |
| CORE-04 | P1 | Team 1B successor | Memory/backpressure admission limits and final-disconnect contention measured, safe remedial behavior tested. |
| CORE-05 | P1 | Team 1B successor + Team 4B | Isolated real WSS tests at proposed pilot tier with CPU/RSS/PG pool and lifecycle/latency data. |
| CORE-06 | P1 | Team 4B + Founder | Certified staging DB/secret/integration isolation before deploying/restarting or injecting faults. |
| CORE-07 | P1 | Central Command | Exact candidate integration of security/UX/infra branches and final release gates. |

These are launch verification blockers, not claims of currently exploitable vulnerability.

## 10. Cross-team handoffs

- **Team 2B:** Confirm safety-veto exception policy, sensitive logging and Hangouts retention decision before performance remediation.
- **Team 3B:** Verify clear queue interrupted, connection lost, retry, terminalization and reconnect messages in real browsers; do not promise transcript replay.
- **Team 4B:** Prove isolation, supply isolated PG/runtime test and performance monitoring; enforce single-instance topology.
- **Team 5B:** No advertised tested capacity, SLA, or reconnect promises until evidence exists; declare incident/stop-admission triggers once measured.

## 11. Launch verdict

**Core realtime: NO-GO for the October 18 controlled global-access beta today.** Passing precommit and synthetic pairing tests are not evidence for database failure handling, recovered sessions under actual outages, or concurrent WSS capacity. There is no certified tested pilot size in the present evidence.

A narrower controlled pilot is only **conditional** after tested capacity, safety and DB recovery gates close and Central Command approves exact integrated SHA. Production must not be modified by this assignment.

## 12. Successor handoff / dissolution

Preserve both inherited Team 1 work and newly added timer tests. Do not rerun the prior synthetic matrix gratuitously; run it after remediation or when the final integrated SHA is ready. Start from `team1b/2026-10-08-failure-recovery` **at its currently verified tip**, refresh main and cross-team branches, inspect the new CI run, and prioritize an isolated deterministic DB failure harness. No source-level fixes beyond edge regression tests were claimed.

TEAM 1B STATUS: PARTIAL  
INHERITED TEAM 1 SHA: `825e9018b35cfb70b14999050fe327d3b5aa45fd`  
FINAL BRANCH: `team1b/2026-10-08-failure-recovery`  
SCARCITY TIMER: INHERITED PASS / TWO NEW TESTS PENDING CI OUTCOME  
DATABASE OUTAGE RESILIENCE: PARTIAL — STATIC CODE REVIEW ONLY  
RESTART AND RECOVERY: PARTIAL — HISTORICAL TESTS / NO NODE OUTAGE PROOF  
MEMORY AND BACKPRESSURE: FAIL TO ESTABLISH — NO-OP HOOK  
REAL WEBSOCKET CAPACITY: 20/50/100/200 NOT RUN  
SINGLE-NODE RELEASE CONTRACT: REQUIRED / CAPACITY UNVERIFIED  
CORE LAUNCH GATE: NO-GO  
NEXT TEAM MUST START FROM: the latest exact SHA on the Team 1B branch after CI verification  
TEAM 1B DISSOLVED (partial evidence handoff; unfinished blockers remain)
