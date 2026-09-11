# StrangerTalks — Successor Handoff

**Handoff date:** 2026-09-11 IST  
**Repository:** `manvith244-oss/StrangerTalks`

## Canonical GitHub state

- `main`: `d69fd48889ba9c79a66a5653acd44ad329c97969`
- tree: `7577273953ed7d505b3c65b3c3900cff588390de`
- canonical commit message: `security: reconstruct Ring and Hangout presence authority (#265)`
- open pull requests: **0**
- PR #265: merged by squash
- PR #248: closed unmerged; explicitly superseded / never merge

Post-merge push verification on `main@d69fd488...` is green:

- Agent Systems Closure Gate: success, including focused Elixir/Python/browser/product-event checks, full `mix precommit`, exact SHA and clean tree.
- GitHub Pages build/deploy/report: success.

No production Supabase migration, live secret change, or production experiment/traffic mutation was executed during this convergence.

## The #265 failure that was actually fixed

Old exact candidate `ea8f96e283d0f9d3f342d82494f2644b9ea88abf` had nondeterministic full-suite failures even though focused Hangout/Team4 suites were green.

Root cause proved from GitHub Actions logs:

- a channel test process owned an Ecto SQL sandbox DB connection;
- the test process/channel could exit while the long-lived supervised `StrangertalksNew.Hangouts.PresenceAuthority` was still handling the linked channel `EXIT`;
- `PresenceAuthority` then called `RoomServer.disconnect/2` through the dead sandbox owner connection;
- `PresenceAuthority` crashed;
- crash-ledger restart reconciliation could falsify a later live membership as `DISCONNECTED`;
- downstream Hangout channel join then failed `not_hangout_member`.

Final candidate:

`7c2b8cf48b7069c89be2c03564583df5e5aff49b`

Correction in `lib/strangertalks_new/hangouts/presence_authority.ex`:

- retain dead channel ledger entry until durable disconnect succeeds;
- catch transient DB exception/exit rather than crashing shared authority;
- retry durable disconnect;
- cancel stale retry when a replacement channel has registered;
- replacement remains authoritative and cannot be knocked offline by stale teardown.

Final candidate exact-head CI had all eight associated PR workflows green: Team 6 Media, Product Event Integrity V2, RPR V4 Contract Proof, Ring Authority Security, Team 6 Agent Registry, Team 4 Safety Privacy Agency, Agent Systems Closure and Hangouts V1 Proof.

## Review disposition

Older Codex review found three blockers on prior architecture:

1. stale disconnect could beat replacement registration — resolved by serialized PresenceAuthority ownership;
2. partitioned Registry could restart internally while sockets survived — resolved by replacing Registry with one supervised PresenceAuthority under transport `rest_for_one` coupling;
3. computed-property Web Audio aliases could bypass Ring gate — resolved with hostile static-concatenation/computed-property proofs and recursive production JS/MJS scanning.

All old review threads are resolved. A final-SHA Codex review request was posted; it acknowledged with `eyes` but did not submit a new blocking review before the merge. Merge admission was made only after the exact head remained unchanged, mergeable, all exact-head workflows were green, all existing P1/P2 threads were resolved, and main had not moved.

## Post-convergence branch audit

Audit branch:

`audit/post-convergence-2026-09-11`

It is based exactly on canonical `main@d69fd488...` and contains documentation only.

Files:

- `docs/audits/POST_CONVERGENCE_DELTA_2026-09-11.md`
- `docs/audits/BRANCH_DISPOSITION_LEDGER_2026-09-11.json`
- this handoff

Observed live remote branch refs: **364**.

The ledger intentionally does not authorize bulk deletion. It separates explicit semantic exceptions from namespace-derived historical/evidence classes.

### Unique runtime/product packets intentionally outside main

1. `fix/d5-hangouts-durable-interactions-2026-09-11`
   - head `76afe490f26b67a94d81de3f1760f796d6ff6880`
   - 11 ahead / 15 behind final main from merge base `1e239772...`
   - adds durable content/reaction/skip-vote tables + DB-backed Hangout interaction reconstruction
   - no PR existed
   - **DO NOT MERGE AS-IS**
   - preserved as product/privacy decision issue #266 because this changes anonymous interaction state-at-rest and retention semantics.

2. `t08/future-001-circle-formation-kernel`
3. `t08/future-002-circle-capacity-liquidity`
   - unique Circle future-social R&D absent from main
   - stale September ancestry; preserve as research/input packets
   - reconstruct from fresh main only if Circles are approved.

### Unique non-runtime packets intentionally preserved

- `language/p01-measurement-spec-2026-09-11`
  - nine commits of measurement/privacy/study/instrumentation documentation only.
- `architecture/construction-system-2026-09-02`
  - historical construction/governance/team-operation documentation only.

Preserve these for archaeology; do not wholesale-merge stale process/planning docs.

### Product decision issues to preserve

- #259 — limited-view presentation capacity fairness
- #260 — Living Thread minimum pilot
- #266 — Hangouts durable reactions/skip-vote persistence

These are not convergence defects and must not be silently converted into implementation.

### September 11 freshness sweep

Exactly 20 branch refs containing `2026-09-11` were returned. Every one was classified as audit, admitted/superseded convergence/release/security proof, evidence/RED validation, Living Thread, D5, or language research. No second unclassified September 11 runtime packet was found.

### Important weird-branch ancestry checks

- `construction/issue-184-durable-terminal-restart`: 0 ahead / 232 behind final main
- `full-source-recovery`: 0 ahead / 1276 behind
- `staging/candidate-2026-09-10`: 0 ahead / 19 behind
- `reconcile/complete-strangertalks-2026-09-01`: 0 ahead / 264 behind
- `adopt/unified-strangertalks-into-main-2026-09-02`: 0 ahead / 244 behind
- `master`: no common ancestor with current main; disconnected historical root, never an integration source

## Frozen audit findings now obsolete

Do not re-open these from the older `OUTSIDE_MAIN_AUDIT_2026-09-11.md`:

- Supabase CA bundle: reconstructed/admitted through PR #253.
- P02 language queue-lock/accessibility refinement: reconstructed/admitted through PR #255.
- product-event instrumentation: reconstructed/admitted through PR #264.
- production-migration repository safety machinery: current hardened version admitted through PR #263.
- dependency security-advisory warning: final exact-head `mix hex.audit` is green with no retired/advisory packages.

## Remaining work that cannot be completed from this GitHub-only environment

### 1. Reconcile Manvith's Windows clone

This environment cannot access the actual local checkout under `C:\Users\manvi\...`.

A terminal-capable successor must first run, from the real repo:

```text
git status --short --branch
git stash list
git worktree list
git branch -vv
git fetch --all --prune
```

Then compare any local-only commits, working-tree edits, stashes and extra worktrees against:

`origin/main@d69fd48889ba9c79a66a5653acd44ad329c97969`

Preserve/disposition local work before changing refs. **Do not run `git reset --hard` as a first step.** Earlier Antigravity activity may have produced local test edits after an earlier clean checkpoint.

### 2. External / physical / production proofs remain separate

These are fresh verification/deployment tasks from canonical main, not reasons to merge historical branches:

- real staging/production deployment proof;
- real provider/OAuth + cross-device provider verification where applicable;
- real physical microphone / OS audio behavior;
- real TURN / independent-network media proof where required;
- longer soak/reconnect-herd/multi-node/distributed-coordination validation;
- production Supabase migration only through the separately guarded owner-authorized workflow.

No production action is authorized merely by this handoff.

## Successor operating rule

Start from repository truth, not old chat snapshots:

1. refresh `main` and confirm it still contains `d69fd488...` or identify what advanced it;
2. check open PRs/issues before acting;
3. read the post-convergence delta + branch ledger;
4. do not merge old branches merely because they are ahead/diverged;
5. for D5/Circles/product decisions, reconstruct from fresh main only after the corresponding product decision is explicit;
6. do not weaken tests to obtain green CI;
7. keep production mutation authority separate from repository convergence.
