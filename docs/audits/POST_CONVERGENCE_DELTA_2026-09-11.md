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
- issues #259 and #260 remain intentionally open because they are product decisions / experiment briefs, not missing convergence code.

The repository still carries a large historical branch namespace. That branch count must not be interpreted as hundreds of unfinished features. Most refs are proof, evidence, diagnostics, checkpoints, superseded release candidates, stale team branches, or historical implementation packets.

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

PR #248 is now closed unmerged and explicitly marked **SUPERSEDED — DO NOT MERGE**.

## Intentionally preserved product decisions — NOT convergence defects

### Issue #259 — limited-view presentation capacity fairness

Keep open. The current bounded presentation-capacity behavior is not a demonstrated accounting leak. A change requires an explicit product decision about either the authority-commit point or per-participant/outstanding-capability fairness policy. Convergence must not invent that policy.

### Issue #260 — Living Thread minimum pilot

Keep open. This is a product hypothesis / experiment brief, not canonical architecture. Historical PR #251 remains closed unmerged. If scheduled later, reconstruct the smallest experiment from then-current main rather than merging the old branch.

## Unique future R&D preserved outside main

The earlier audit identified Circle formation/capacity work on historical T08 branches as unique future-social R&D. No later admission in the convergence sequence makes those old branches merge candidates.

Preserve the ideas/tests as source archaeology. If Circles become an approved StrangerTalks World feature, reconstruct accepted invariants from current main. Do not directly merge the old September-base branches.

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

These branches should **not** be bulk-deleted merely to make GitHub look tidy. A branch can be deleted only after its unique product/R&D/provenance value is classified. Prefer a machine-readable disposition ledger before mass cleanup.

At this checkpoint, the important repository truth is: **0 open PRs does not mean 0 historical branches; historical branches do not mean pending merges.**

## Remaining non-code / external verification boundaries

The earlier audit also recorded several checks that are not solved by merging historical code:

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
- historical branch namespace: still large, mostly archival/evidence/superseded; do not equate branch count with unfinished product work
- next destructive operation on branches or the Windows clone requires a fresh provenance/local-state check
