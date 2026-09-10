# StrangerTalks — Outside-Main Audit

**Audit date:** 2026-09-11 IST  
**Repository:** `manvith244-oss/StrangerTalks`  
**Frozen canonical baseline:** `main@65b6bf065193269c52cc73c5231dc64546b92d38`  
**Baseline tree:** `5d518f5bc149d0b9f540ab1a33837091f13e1011`  
**Latest baseline commit:** merge PR #245, `RPR v2: close future public RPC default authority`  
**Audit branch:** `audit/outside-main-2026-09-11`

## Safety / scope

This audit does **not** modify `main`. The audit branch was created exactly from the frozen canonical SHA above. No source feature was merged, rebased, force-pushed, deleted, deployed, or promoted during the audit.

The purpose is to distinguish four very different things that currently coexist outside `main`:

1. genuinely unfinished or unadmitted work;
2. useful future/R&D work that should be reconstructed on fresh `main` if revived;
3. proof/evidence branches whose product change is already in `main`;
4. stale historical branches/PRs that should never be merged directly.

A branch being “ahead” of its historical merge base is **not** by itself evidence that its feature is missing. StrangerTalks has had heavy convergence/reconstruction since the September 2 canonical base, so semantic equivalence and later fresh-main admission matter more than old commit ancestry.

---

# Executive verdict

The repository has a very large historical branch surface — more than 300 live branch refs were returned across four 100-item branch pages, with the fifth page empty. There are currently **21 open PRs** and **67 closed-but-unmerged PRs**. Most of that surface is evidence, diagnostics, temporary CI, old release bases, checkpoints, superseded candidates, or historical team packets rather than missing product code.

The amount of **real work still outside `main` is much smaller than the raw branch count suggests**.

## Highest-confidence live leftovers

### P0 / release-readiness candidate — Supabase CA bundle

**PR #246** — `Release v2: bundle verified Supabase database root CA`  
Branch: `release/staging-supabase-ca-trust-v2-2026-09-10`  
Head: `0feaa008ffb710c7cc979e8747f84b86942cefdf`

This is the cleanest genuinely unadmitted current-main descendant found in the audit:

- status versus frozen `main`: **ahead**;
- ahead by **3** commits;
- behind by **0**;
- merge base is exactly the frozen canonical `main` SHA;
- scope is only:
  - `priv/certs/supabase-prod-ca-2021.crt`;
  - `test/strangertalks_new/production_database_tls_config_test.exs`;
  - `test/strangertalks_new/supabase_ca_bundle_test.exs`.

Purpose: bundle the verified Supabase Root 2021 CA so staging can set `DB_CA_CERT_FILE` without weakening the already-admitted `verify_peer` + hostname/SNI PostgreSQL TLS contract.

**Classification:** REAL CURRENT OUTSIDE-MAIN WORK.  
**Recommended handling:** independently verify exact head against the *latest* `main`; then admit through a fresh/current PR only if it remains required. Do not substitute the older sibling `release/staging-supabase-ca-trust-2026-09-10`.

### P1 / current UI follow-up — language selector queue-lock

Branch: `fix/p02-language-selector-queue-lock-2026-09-10`  
Head observed: `eca9adb7dfff2c988d38a0512f18cc0a701c3c14`

This branch is **not fully contained in main**. Against the frozen baseline it is:

- diverged;
- **5 commits ahead** of merge base `777439b3c28c0554ac438a348620f46e0cd27b24`;
- **3 commits behind** current `main`;
- effective touched surfaces are the interface-language placement module and its browser/geometry tests.

The current branch version adds behavior not present in the frozen main copy of `interface_language_placement.mjs`, notably:

- a minimum 44px-style control target;
- `syncLanguageAvailability(...)`;
- disabling the 1:1 language selector when the Four Doors screen is not the active screen;
- synchronizing that availability through a `MutationObserver`.

Observed follow-up commit messages include:

- `test(language): prove header placement and queue lock`;
- `test(language): follow header-first keyboard order`;
- `fix(language): preserve 44px header selector target`;
- `test(language): allow CI margin for geometry matrix`.

No PR was found whose head is this follow-up branch, and no PR-triggered workflow run was returned for its current head.

The earlier placement work itself is **already in main** through the predecessor line (PR #242 / `language/p02-interface-placement-2026-09-10` is now ancestral). This branch is specifically a later refinement, not the original relocation.

**Classification:** REAL CURRENT OUTSIDE-MAIN FOLLOW-UP, NOT YET ADMISSION-READY FROM THIS AUDIT.  
**Recommended handling:** reconstruct/rebase the two-file intent on latest main, rerun accessibility/browser/JS/full gates, and open a fresh-main PR. Do not merge the diverged branch as-is.

### P2 / future-social R&D — Circle formation and capacity/liquidity

Branches:

- `t08/future-001-circle-formation-kernel` — 6 commits ahead of the September 2 base;
- `t08/future-002-circle-capacity-liquidity` — **19 commits ahead** of the September 2 base.

Current main does **not** contain `lib/strangertalks_new/future_social/circle_formation.ex`.

The later branch carries actual future-social code and tests:

- `lib/strangertalks_new/future_social/circle_formation.ex`;
- `test/strangertalks_new/future_social/circle_formation_test.exs`;
- `test/strangertalks_new/future_social/circle_formation_hostile_capacity_test.exs`;
- T08 proof workflows.

Historical PR #150 for FUTURE-001 was **closed without merge**. Its scope deliberately kept the existing Four Doors → 1:1 Match → private Conversation architecture untouched. It implemented a pure deterministic formation kernel but explicitly did **not** implement Circle persistence, Phoenix group channels, a Fifth Door/Happening UI, public feed, group media, or new safety policy.

The later FUTURE-002 branch contains additional capacity/liquidity work, but its history also contains proof/CI/scratch-cleanup commits. It is 227 current-main commits behind and therefore should be treated as an **R&D source packet**, not an integration branch.

**Classification:** UNIQUE FUTURE PRODUCT WORK OUTSIDE MAIN.  
**Recommended handling:** preserve the design/tests, but if Circles become part of the new StrangerTalks world, reconstruct the accepted invariants on a fresh branch from current main. Do not merge either T08 branch directly.

---

# Important work that looked stranded but is already in main

## Hangouts

The accepted historical Hangouts persistence/context milestone SHA `788c59fca21c2eef64d281f59f02aafcf1c272d8` is an ancestor of current `main` — **0 commits ahead, 124 behind**. The current `feature/hangouts-v1` branch is also fully behind current main, and the temporary Hangouts safety RED branches checked are ancestral as well.

**Verdict:** do not classify the existing Hangouts branch as stranded code. Future Hangouts work may still be planned, but that is new work after the admitted foundation, not unmerged content from this branch.

## Brand / logo

`brand/strangertalks-master-logo-001` is fully ancestral to main — 0 ahead. The full-color identity PR lineage is therefore not stranded.

**Verdict:** historical brand branch is archival, not a pending merge.

## Arrival / old frontend feature branches

Checked examples including:

- `feature/arrival-first-60-seconds`;
- `feature/instagram-chat-ui`;
- `doors-visual-structure-2026-08-30`;
- `settings-risk-gradient-2026-08-29`;
- `feature/a01-conversation-companion`;
- `feature/agent-provider-config-observability`.

These are fully behind current main in ancestry checks.

**Verdict:** no merge work remains from these branches themselves.

## Docker and CI cleanup

Recent convergence branches:

- `convergence/docker-release-image-fix-2026-09-10-final`;
- `convergence/ci-cleanup-obsolete-workflows-2026-09-10`.

Both are ancestors of current main.

**Verdict:** already admitted.

## T01 participant-integrity work

Old T01 branches for Relationship distinctness and Match/Conversation participant integrity still appear ahead of their September 2 base, but current main contains fresh C3 replacement authority:

- `20260909183000_enforce_distinct_relationship_participants_c3.exs`;
- Relationship application validation + DB check constraint;
- Match participant distinctness validation;
- `c3_relationship_distinctness_test.exs`;
- `c3_match_conversation_integrity_test.exs`.

**Verdict:** old T01 PRs #143 and #154 are historical carriers, not missing code.

## Legacy `COMPLETED` Conversation status cleanup

Current main contains `c3_legacy_completed_status_test.exs` explicitly proving application authority rejects legacy `COMPLETED`, and current lifecycle code uses `ENDED` + completion semantics.

**Verdict:** PR #152 is historical/superseded; do not merge it.

## A02 authority reconciliation

Current main contains `a02_authority_reconciliation_test.exs` and the current context explicitly defines A02 as deterministic `V1Metrics` + `V1Recommendations`, with the old model-backed `LearningAdvisor` superseded.

**Verdict:** PR #164 is historical; its authority reconciliation is present in evolved main.

## T07 recursive privacy/provider closure

Current main contains `t07_ai_003_privacy_boundary_test.exs` and evolved provider/privacy boundaries. The older T07 branches still diverge from the September 2 base because their original commits were not necessarily admitted verbatim.

**Verdict:** do not infer missing T07 work from old ancestry. The old branches are source archaeology unless a fresh current-main test demonstrates a regression.

## T05 NET-003 fatal-call closure

The later fresh convergence branch `convergence/c1-t05-net003-main-2026-09-10` is an ancestor of current main. Current main also contains `test/js/t05_net_003_ice_failure_test.mjs`.

**Verdict:** the source correction represented by open PR #161 has been converged. PR #161 now mainly preserves historical proof and the warning that real production TURN / two-independent-network proof was not established at the time.

## T05 limited-view atomicity

Current main contains the T05 presentation-atomicity test family and explicit runtime handling for `presentation_capacity_unavailable`, including avoiding a View burn when capacity is unavailable before consumption.

**Verdict:** PR #156 is not a safe pending source merge. Its original owner-decision narrative should be treated as historical context and re-evaluated against current main before opening any new fairness/quotas work.

---

# Open PR audit — all 21 currently open PRs

| PR | Classification | Action |
|---|---|---|
| #246 Release v2 Supabase CA | **Active real candidate** | Verify exact current head on latest main; candidate for admission |
| #171 A04 provenance fail-open RED | Proof-only / historical | Do not merge; close after evidence retention review |
| #170 A02 baseline formatter proof | Proof-only / no product source | Close/archive candidate |
| #169 T02 Conversation Start verification | Verification-only historical | Do not merge; closure now represented by later convergence |
| #167 A12 provider test double proof | Proof-only | Do not merge from historical release base |
| #166 T-A10 Python security verification | Verification-only | Do not merge |
| #165 T-A10 security-gate alignment | Historical gate candidate | Re-audit only if current main lacks equivalent gate; never merge old base blindly |
| #164 A02 authority reconciliation | Superseded by current main | Close/archive candidate |
| #163 A01 restart verification | Verification-only | Do not merge |
| #162 A01 Conversation Start restart RED | Test-only historical RED | Do not merge |
| #161 T05 NET-003 | Source intent already converged; historical proof remains | Do not merge old PR; retain deployment-proof caveat separately |
| #156 T05 limited-view atomicity/capacity | Tests/behavior evolved into main | Do not merge; reopen only a fresh current-main product decision if needed |
| #155 T07 exact candidate diff check | Verification-only | Do not merge |
| #154 T01 Match/Conversation distinctness | Reimplemented/admitted by C3 | Close/archive candidate |
| #153 T07 provider output/failure verification | Historical verification | Do not merge; later T07 line evolved beyond it |
| #152 T01 `COMPLETED` authority | Reimplemented/admitted | Close/archive candidate |
| #146 T05 stale `call:end` ABA proof | Test lineage absorbed by later T05 work | Close/archive candidate |
| #144 T02 multi-tab authority proof | Historical validation packet | Recheck only if fresh-main regression exists; otherwise close/archive |
| #143 T01 Relationship distinctness | Reimplemented/admitted by C3 | Close/archive candidate |
| #123 PREP-A DB TLS proof | Historical proof; production TLS has newer admitted implementation | Close/archive candidate |
| #84 F-X07 terminal-truth boundary | Very old historical packet | Do not merge; archaeology only |

The key point: **21 open PRs does not mean 21 features are waiting to merge.** Only #246 currently presents as a clean, direct, current-main descendant. Most other open PRs explicitly say proof-only / DO NOT MERGE or have since been superseded by fresh-main convergence.

---

# Closed-but-unmerged PR surface

GitHub currently reports **67 closed, unmerged PRs**. This category includes intentional RED/proof packets, superseded candidates, closed R&D work, and branches replaced by fresh-main reconstruction.

The most important unique product item found in this category is historical **PR #150 / Circle Formation Kernel**, because its source module is absent from current main and its later FUTURE-002 branch continues the idea.

Closed-unmerged PRs must therefore not be bulk-deleted blindly. Recommended rule:

- if current main contains equivalent/fresher authority: archive/delete branch later;
- if it is evidence-only: retain only as long as evidence provenance is useful;
- if it contains unique product/R&D concepts: tag/catalog it before branch cleanup;
- never resurrect by direct merge from the September 2 base.

---

# Branch-hygiene finding

The branch namespace is carrying substantial historical noise:

- `evidence/*` exact-SHA proof branches;
- `proof/*` and `validation/*` branches;
- `diagnostics/*`, `diag/*`, `probe/*`, and `bisect/*` branches;
- `checkpoint/*` and `backup/*` branches;
- old `release/prep-*` and `release/integration-*` authority bases;
- many `convergence/*-red*` branches, several of which point at identical or near-identical proof heads;
- old team branches whose semantic work was later reconstructed.

This makes GitHub visually look as if hundreds of things are unfinished when that is not true.

**Recommended cleanup policy:** do not start by deleting branches. First create a machine-readable branch disposition ledger with at least:

- branch;
- head SHA;
- merge base/current-main relation;
- associated PR(s);
- purpose (`product`, `proof`, `evidence`, `diagnostic`, `backup`, `release`, `R&D`);
- semantic status (`admitted`, `superseded`, `unique`, `unknown`);
- delete/archive decision.

Only delete after `unique` and `unknown` are driven to zero or explicitly preserved.

---

# Remaining project-level verification/deployment work visible from canonical main

These are not necessarily represented by a single mergeable branch, but they matter because some historical outside-main PRs mention them and the canonical documentation still retains them as real limitations:

- dependency security advisories in pinned Bandit/Postgrex-related dependency set require release-hardening work;
- real physical microphone/OS audio verification remains a hardware validation item in the recorded closeout;
- real Google OAuth + approved redirect/deployment HTTPS verification remains external-provider work;
- real Google Drive `appDataFolder` operation and cross-device restore remain provider/device verification work;
- multi-node locking/distributed coordination is not a V1 guarantee;
- long soak, large reconnect-herd, and multi-node recovery remain higher-scale verification gaps;
- real production TURN/two-independent-network media proof should be treated separately from the now-admitted NET-003 source correction;
- staging/production deployment proof remains separate from code admission.

Do not pull old branches into main merely because one of these external proof gaps remains. Create fresh verification/deployment packets from current main instead.

---

# Recommended convergence order from this audit

## 1. Finish current release edge

Start with PR #246 because it is the only checked open PR that is a clean descendant of the frozen current main. Revalidate head and canonical main before any admission.

## 2. Reconstruct P02 language queue-lock follow-up

Do not merge `fix/p02-language-selector-queue-lock-2026-09-10` directly. Recreate its still-desired behavior on a fresh main branch and prove keyboard order, accessibility target size, screen lifecycle, queue semantics, browser geometry, and full precommit.

## 3. Decide whether Circles are now part of the active World roadmap

If yes, treat T08 FUTURE-002 as a research/input packet. Port invariants/tests deliberately onto fresh main, then design persistence/realtime/safety/world integration under the new product architecture. If no, preserve branch/PR metadata and mark it deferred R&D.

## 4. Close the open-PR cemetery

After a final semantic spot-check, close old proof/verification PRs that explicitly say DO NOT MERGE and are already superseded. This is repository hygiene, not product integration.

## 5. Build the full branch disposition ledger

The next audit phase should reduce every remaining branch ref into one of:

`KEEP-ACTIVE | PRESERVE-R&D | EVIDENCE-ARCHIVE | SUPERSEDED | SAFE-DELETE | UNKNOWN`

No `UNKNOWN` branch should be deleted automatically.

---

# Bottom line

StrangerTalks does **not** have hundreds of unfinished features sitting outside `main`.

At this frozen checkpoint, the strongest actual outside-main engineering work is:

1. the **Supabase CA bundle** on PR #246;
2. the **P02 language-selector queue-lock/accessibility follow-up** with no current PR;
3. the **Circle formation/capacity R&D line**, which remains genuinely absent from main but is too stale to merge directly.

Most of the remaining visible GitHub surface is historical proof machinery or superseded branch ancestry. Hangouts foundation, logo/brand, T01 integrity, T05 NET-003 source closure, Docker release fix, CI cleanup, A02 reconciliation, legacy `COMPLETED` cleanup, and several earlier UI feature branches have already reached main through later convergence or reconstruction.

The next useful job is therefore **not “merge everything outside main.”** It is to preserve the few unique packets, finish the current release edge, and then clean the branch/PR archaeology with an evidence-backed disposition ledger.
