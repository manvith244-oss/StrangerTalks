# StrangerTalks — Post-Convergence Audit Delta

**Audit date:** 2026-09-11 IST  
**Repository:** `manvith244-oss/StrangerTalks`  
**Canonical main:** `d69fd48889ba9c79a66a5653acd44ad329c97969`  
**Canonical tree:** `7577273953ed7d505b3c65b3c3900cff588390de`  
**Audit branch:** `audit/post-convergence-2026-09-11`

This file is a delta to `docs/audits/OUTSIDE_MAIN_AUDIT_2026-09-11.md`, which was frozen earlier at `main@65b6bf065193269c52cc73c5231dc64546b92d38`. It records what changed between that frozen audit and the current canonical repository. It does not authorize branch deletion, deployment, production database mutation, product-policy changes, or resurrection of historical branches.

## Executive verdict

GitHub PR convergence is complete at this checkpoint:

- canonical `main` is `d69fd48889ba9c79a66a5653acd44ad329c97969`;
- PR #265 was squash-admitted as that commit;
- PR #248 was closed unmerged as superseded;
- GitHub reports **0 open pull requests** after that closure;
- final main push CI re-proved Agent Systems, Python security, browser logic, product-event integrity, full `mix precommit`, exact SHA and clean tree on the squash commit;
- issues #259, #260 and #266 are intentionally open product decisions / experiment briefs, not missing convergence code.

The live branch search returned **364 branch refs**. That count must not be interpreted as hundreds of unfinished features. Most refs are proof, evidence, diagnostics, checkpoints, superseded release candidates, stale team branches, or historical implementation packets. A machine-readable disposition ledger now exists at `docs/audits/BRANCH_DISPOSITION_LEDGER_2026-09-11.json` on this audit branch.

## What the earlier audit called “live” that is now resolved

### Supabase CA bundle — RESOLVED / ADMITTED

Earlier audit classification: real outside-main release-readiness candidate through historical PR #246.

Final disposition:

- historical PR #246 is closed unmerged;
- its still-valid three-file CA/TLS intent was reconstructed from fresh main and admitted through PR #253;
- canonical main contains `priv/certs/supabase-prod-ca-2021.crt` and the associated TLS proof contract;
- therefore `release/staging-supabase-ca-trust-v2-2026-09-10` is historical/superseded, not pending product work.

Do not merge PR #246 or its branch.

### Conversation Language queue lock — RESOLVED / ADMITTED

Earlier audit classification: real current UI follow-up on `fix/p02-language-selector-queue-lock-2026-09-10`.

Final disposition:

- stale reconstruction PR #254 was closed;
- fresh-main PR #255 was merged;
- canonical behavior now keeps Conversation Language editable while Four Doors owns selection, disables the control after leaving Doors for queue/match/conversation, restores editability on a fresh Doors state, and preserves the minimum touch target;
- the old branch is therefore superseded source archaeology, not pending work.

Do not merge the historical branch directly.

### Product-event instrumentation — RESOLVED / ADMITTED

Historical PR #249 and intermediate PR #262 are closed unmerged and explicitly superseded.

Fresh-main PR #264 was admitted before this delta. Canonical main now contains the privacy-bounded provider-neutral entrance → queue → match → first accepted-message event contract. Vendor ingestion remains disabled by design.

### Production-migration safety machinery — RESOLVED / ADMITTED AS REPOSITORY CODE

Historical migration-runner candidates were superseded by fresh-main convergence:

- PR #261 admitted the reconstructed v3 safety chain;
- PR #263 admitted the corrective v4 authority hardening;
- live secret-bearing execution is isolated from PR rehearsal and guarded by owner/main/manual-dispatch authority;
- migration-tree pinning and database-URL TLS-override rejection are canonical.

This repository convergence does **not** mean the production Supabase migration has been executed. No such production mutation is authorized by this audit.

### Ring / Hangout presence authority — RESOLVED / ADMITTED

PR #265 was admitted as canonical commit `d69fd48889ba9c79a66a5653acd44ad329c97969` after exact-head proof.

Canonical outcome includes:

- one server-owned `PresenceAuthority` GenServer instead of a partitioned Registry;
- server-generated presence leases;
- serialized last-channel / replacement-channel authority;
- transport teardown coupling through `rest_for_one` supervision;
- VM-local crash-ledger reconciliation;
- crash-safe durable-disconnect retry when a teardown outlives a transient DB owner/connection;
- stale retry cancellation when a replacement channel has become authoritative;
- Ring reduced to authoritative lifecycle/mute presentation rather than speaking-amplitude inference;
- hostile computed-property Web Audio coverage and repository-wide Ring authority scanning.

Final exact candidate before admission: `7c2b8cf48b7069c89be2c03564583df5e5aff49b`.

All associated PR workflows on that exact SHA were green: Team 6 Media, Product Event Integrity V2, RPR V4 Contract Proof, Ring Authority Security, Team 6 Agent Registry, Team 4 Safety Privacy Agency, Agent Systems Closure, and Hangouts V1 Proof.

After squash admission, the push-triggered Agent Systems Closure gate on canonical `main@d69fd488...` also completed successfully, including full precommit and exact-SHA/clean-tree proof.

PR #248 is now closed unmerged and explicitly marked **SUPERSEDED — DO NOT MERGE**.

## Newly discovered unique outside-main packets

### D5 Hangouts durable interactions — PRESERVE / PRODUCT-PRIVACY DECISION

Branch: `fix/d5-hangouts-durable-interactions-2026-09-11`  
Head: `76afe490f26b67a94d81de3f1760f796d6ff6880`

Against final main it is diverged: **11 commits ahead, 15 behind**, merge base `1e23977246f42e2e4c918a89170156fc58dd5da5`.

It adds real runtime/database behavior:

- durable `hangout_content_items`;
- durable `hangout_room_content`;
- durable `hangout_reactions`;
- durable `hangout_skip_votes`;
- `Hangouts.DurableInteractions`;
- restart reconstruction and database-serialized skip-threshold behavior;
- Supabase-like Data API closure tests for those new tables.

This is not safe to classify as a routine reliability fix because it changes anonymous interaction data-at-rest semantics and the audit did not establish a canonical retention/deletion law bounding the new history. Issue **#266** now preserves the decision explicitly. Do not merge the historical branch. Reconstruct from current main only after deciding whether interactions remain ephemeral, become short-lived recovery state, or become durable room history with an explicit retention/privacy contract.

### Language P01 measurement specification — PRESERVE DOCUMENTATION

Branch: `language/p01-measurement-spec-2026-09-11` is **9 commits ahead / 16 behind** final main from merge base `65b6bf...`. Its diff is documentation/research protocol only: measurement contract, privacy gate, entrance comprehension study, instrumentation audit/review and baseline analysis. Preserve it as research provenance. It is not missing runtime code and should not be wholesale-merged as stale planning documentation.

### Historical construction system — PRESERVE DOCUMENTATION

Branch: `architecture/construction-system-2026-09-02` is **26 commits ahead / 386 behind** final main. Its unique content is the old construction charter, repository-truth protocol, team operating contracts, orchestration/governance docs and team packets. Preserve for archaeology; current repository authority has evolved too far to merge the old system wholesale.

## Intentionally preserved product decisions — NOT convergence defects

### Issue #259 — limited-view presentation capacity fairness

Keep open. The current bounded presentation-capacity behavior is not a demonstrated accounting leak. A change requires an explicit product decision about either the authority-commit point or per-participant/outstanding-capability fairness policy. Convergence must not invent that policy.

### Issue #260 — Living Thread minimum pilot

Keep open. This is a product hypothesis / experiment brief, not canonical architecture. Historical PR #251 remains closed unmerged. If scheduled later, reconstruct the smallest experiment from then-current main rather than merging the old branch.

### Issue #266 — Hangouts durable reactions / skip votes

Keep open. This is the explicit preservation point for the D5 branch described above. It is a product/privacy retention decision, not an automatic convergence merge.

## Unique future R&D preserved outside main

The earlier audit identified Circle formation/capacity work on historical T08 branches as unique future-social R&D:

- `t08/future-001-circle-formation-kernel`;
- `t08/future-002-circle-capacity-liquidity`.

No later admission makes those old branches merge candidates. Preserve the ideas/tests as source archaeology. If Circles become an approved StrangerTalks World feature, reconstruct accepted invariants from current main. Do not directly merge the old September-base branches.

## Branch-freshness sweep

A search for branch names containing `2026-09-11` returned exactly 20 refs. They are all accounted for as one of:

- current/frozen audit branches;
- already admitted or superseded convergence/release/security packets;
- RED/evidence validation branches;
- Living Thread issue #260;
- D5 issue #266;
- P01 language research docs.

No second unclassified September 11 runtime packet was found.

Spot checks also established:

- `construction/issue-184-durable-terminal-restart`: 0 ahead / 232 behind — fully ancestral;
- `full-source-recovery`: 0 ahead / 1276 behind — fully ancestral;
- `staging/candidate-2026-09-10`: 0 ahead / 19 behind — fully ancestral;
- `reconcile/complete-strangertalks-2026-09-01`: 0 ahead / 264 behind — fully ancestral;
- `adopt/unified-strangertalks-into-main-2026-09-02`: 0 ahead / 244 behind — fully ancestral;
- `master`: no common ancestor with canonical main — disconnected historical root, never an integration source.

## Historical branch namespace policy

The repository continues to contain many refs under namespaces such as:

- `evidence/*`;
- `proof/*`;
- `validation/*`;
- `diagnostics/*`, `diag/*`, `probe/*`, `bisect/*`;
- `checkpoint/*`, `backup/*`;
- old `release/*` / integration bases;
- historical team branches;
- superseded convergence candidates.

These branches should **not** be bulk-deleted merely to make GitHub look tidy. The new JSON ledger classifies explicit semantic exceptions and namespace provenance. It intentionally marks **no branch SAFE_DELETE** because destructive cleanup requires one more ancestry/reference pass for the branch being deleted.

At this checkpoint, the important repository truth is: **0 open PRs does not mean 0 historical branches; historical branches do not mean pending merges.**

## Remaining non-code / external verification boundaries

The frozen audit's dependency-advisory warning is no longer a current blocker: the final exact-head workflows ran `mix hex.audit` successfully and reported no retired or security-advisory packages. Do not reopen dependency-hardening work from that stale finding unless a fresh audit on current main reports a new advisory.

The remaining checks below are not solved by merging historical code:

- real production/staging deployment proof;
- real provider/OAuth and cross-device provider verification where applicable;
- real physical microphone/OS audio validation;
- real TURN / independent-network proof where required;
- longer soak, reconnect-herd, multi-node and distributed-coordination validation beyond V1 guarantees;
- production Supabase migration execution only through the separately guarded owner-authorized path.

Treat these as fresh verification/deployment work from canonical main, never as justification for merging stale branches.

## Local Windows clone boundary

This audit has GitHub authority only. It does not prove the state of Manvith's Windows checkout.

A terminal-capable successor must inspect the local clone before any destructive reconciliation:

1. `git status --short --branch`
2. `git stash list`
3. `git worktree list`
4. `git branch -vv`
5. `git fetch --all --prune`
6. compare local-only commits/changes against canonical `main@d69fd48889ba9c79a66a5653acd44ad329c97969`
7. preserve or explicitly disposition any local edits/stashes/worktrees
8. only then fast-forward/switch/reconcile the local main

Do **not** issue `git reset --hard` until local-only work is proven disposable. Earlier Antigravity activity may have produced local test edits after an earlier clean-worktree checkpoint.

## Production boundary

During the convergence represented by this delta:

- no production Supabase migration was executed;
- no live production secret was changed;
- no production experiment or traffic exposure was authorized;
- GitHub repository/CI state was the only mutation surface.

## Final repository checkpoint

Canonical GitHub state for the next agent:

- `main`: `d69fd48889ba9c79a66a5653acd44ad329c97969`
- open PRs: `0`
- #265: merged
- #248: closed, unmerged, superseded
- #259: open product decision — preserve
- #260: open experiment/product decision — preserve
- #266: open Hangouts persistence/product-privacy decision — preserve
- branch refs observed: `364`
- unique runtime packets intentionally outside main: D5 durable Hangout interactions + two Circle R&D branches
- unique non-runtime packets intentionally preserved: P01 measurement/research docs + historical construction-system docs
- next destructive operation on branches or the Windows clone requires a fresh provenance/local-state check
