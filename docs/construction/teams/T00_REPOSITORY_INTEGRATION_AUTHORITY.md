# T00 — Repository & Integration Authority

## Evolution Clause

This packet is a current construction mandate, not a permanent organizational design. Branch topology and final product architecture may evolve. T00 may change integration mechanics, but may not silently change product law or specialist authority.

## Mission

Reconstruct the real StrangerTalks codebase from distributed branch/PR history, prevent loss of valuable recent work, and establish one evidence-backed construction candidate that all other teams can build from.

## Immediate goal

**Do not build new product surface yet. First make repository truth navigable and integration-safe.**

## Required universal documents

Read all `docs/construction/00` through `08`, plus `TEAM_PACKET_TEMPLATE.md`.

## Current repository truth

Known lineages include:

- `main` @ `83e8ee9...` — not full Phoenix application tree;
- `master` @ `82ed9df...` — separate historical/cutover lineage;
- `release/prep-2026-08-22` @ `2724d655...` — full Phoenix tree and documentation-host base;
- `release/integration-2026-08-28` @ `f781a079...` — diverged integration lineage;
- branch-only Python AI service work;
- branch-only pairing reservation work;
- branch-only privacy/retention work;
- numerous specialist branches whose work may have been consumed through integration carriers despite open/closed PR state.

## Owned authority

- archaeology ledger;
- provenance graph;
- integration candidate branch;
- semantic conflict resolution process;
- merge/cherry-pick/port strategy;
- exact baseline declarations;
- architecture documentation synchronization after accepted integration.

## Authorities to preserve

T00 does not own:

- product laws;
- Safety policy;
- Matchmaking semantics;
- Conversation lifecycle semantics;
- AI authority policy;
- UX meaning;
- retention duration decisions.

When two implementations encode different product behavior, stop and route to the owning team/Owner rather than choosing whichever merges easiest.

## Scope

1. Enumerate relevant branch and PR families from at least 2026-08-22 onward, plus older lineages that remain operationally relevant.
2. Group branches by capability rather than just name.
3. Build a capability provenance map: where each material feature/invariant originated, where it was integrated, and whether a newer implementation superseded it.
4. Classify each important work packet: CANONICAL / INTEGRATED / SUPERSEDED / SALVAGE / CONFLICT / PROOF-DIAGNOSTIC / ARCHIVE.
5. Diff `release/prep-*` vs `release/integration-*` semantically, especially shared browser/runtime files.
6. Review branch-only salvage candidates with the owning teams.
7. Create a clean construction candidate branch only after conflicts are understood.
8. Run cross-team regression gates before declaring the candidate authoritative for new construction.
9. Update `08_CURRENT_CONSTRUCTION_BASELINE.md` and the branch ledger with exact SHAs.

## Non-scope

- feature invention;
- broad refactoring for aesthetics;
- changing tests simply because integration is hard;
- force-merging unrelated histories;
- treating merge status as product truth;
- production deployment before release authority accepts the candidate.

## Required invariants

- no accepted newer authority is overwritten by an older whole-file version;
- no branch-only safety/reliability invariant is dropped without an explicit decision;
- tests retain or increase meaningful coverage;
- every salvaged capability has source provenance;
- every conflict has an owner;
- final candidate has one exact SHA.

## Required evidence

- branch ledger;
- PR/capability mapping;
- semantic diff notes for shared seams;
- exact-source and exact-destination SHAs for salvage ports;
- focused gates from affected teams;
- full precommit/regression suite appropriate to candidate;
- `git diff --check` and clean-tree proof;
- independent T9 re-attack before broad completion claim.

## Stop conditions

Stop and escalate when:

- two branches implement contradictory product law;
- a salvage packet depends on an obsolete schema and behavior cannot be ported mechanically;
- a merge would weaken a safety or privacy invariant;
- an open specialist branch appears newer but its current authority cannot be established;
- no reproducible baseline exists.

## Handoff

Produce an exact construction baseline SHA plus an updated archaeology ledger. Other teams must not infer canonicality from branch name; they consume T00's explicit baseline declaration.
