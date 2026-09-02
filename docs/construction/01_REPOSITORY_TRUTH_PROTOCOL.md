# 01 — Repository Truth Protocol

Status: UNIVERSAL / REQUIRED

## Purpose

Recent StrangerTalks work is distributed across multiple branch families and PR lineages. Auditing only `main` or only one release branch can silently lose implementation, tests, architecture decisions and safety/reliability work.

This protocol defines how repository truth is reconstructed before construction decisions are made.

## Core law

**The repository is an evidence corpus, not a single-branch document.**

No branch is canonical merely because of its name, recency or merge status.

## Required evidence sources

For every material subsystem inspect, where relevant:

- current and historical release branches;
- integration branches;
- open and closed PRs;
- merged and intentionally unmerged specialist branches;
- feature/fix branches with unique changes;
- diagnostic/proof branches;
- tests and CI workflows;
- migrations and schemas;
- architecture/product documents;
- production/deployment lineage;
- explicit owner decisions.

## Branch classification

Every relevant branch or work packet receives one primary classification:

### CANONICAL
Current authority for the owned behavior.

### INTEGRATED
Meaningful work is already present in a later accepted lineage. Preserve provenance but do not re-merge blindly.

### SUPERSEDED
A later implementation deliberately replaced this work.

### SALVAGE
Contains useful or important work not currently present in the intended construction baseline.

### CONFLICT
Contains valuable work that contradicts or overlaps another authority and needs explicit reconciliation.

### PROOF / DIAGNOSTIC ONLY
Evidence, tests, temporary workflows or investigation; not product authority by itself.

### ARCHIVE
Historically useful but not a current construction input.

## Salvage rule

Never cherry-pick a branch merely because it is classified SALVAGE.

Before salvage:

1. identify the exact invariant or capability being recovered;
2. establish whether later work already implements it differently;
3. inspect dependency and schema assumptions;
4. rebase or port the minimum coherent change onto the actual construction candidate;
5. run current tests plus focused hostile tests;
6. record the source SHA and new destination SHA;
7. obtain Integration Authority acceptance.

## Merge-status rule

`merged` does not mean `current`.

`unmerged` does not mean `discard`.

Examples of legitimate unmerged value include:

- proof-first branches;
- work intentionally held for integration authority;
- security hardening blocked by another owner;
- architecture experiments that established a reusable boundary;
- changes later consumed manually through another integration carrier.

## Evidence ranking

When evidence conflicts, prefer:

1. explicit current product/owner decision;
2. exact current implementation behavior proven by tests;
3. durable data/authority invariants;
4. accepted integration/release decisions;
5. maintained architecture documents that match code;
6. PR descriptions and handoff records;
7. older design intent;
8. branch names and commit messages alone.

No single item automatically overrides a safety or legal constraint.

## Required archaeology ledger fields

For each relevant work packet record:

- branch name;
- head SHA;
- base / merge-base where known;
- date range;
- PR/issue references;
- subsystem;
- meaningful unique files/behavior;
- tests/proof added;
- whether production code changed;
- relationship to current candidate;
- classification;
- salvage/conflict notes;
- owner/team;
- confidence;
- next action.

## No-common-ancestor handling

If GitHub reports no common ancestor between branches, do not infer that one is wrong. Treat them as separate repository lineages until their origin and intended role are established.

## Current known warning

The current `main` lineage is not the full Phoenix application tree. The construction documents are therefore hosted from a known Phoenix release branch while branch truth is reconstructed independently.

Likewise, recent `release/prep-*` and `release/integration-*` work has diverged, and specialist branches contain additional work. The final construction baseline must therefore be declared only after the salvage/conflict ledger is sufficiently complete.

## Audit completion criteria

Repository archaeology is not complete when every branch has been read line-by-line. It is complete when the team can answer, with evidence:

- what the current product actually does;
- where each material authority comes from;
- what important work exists outside the candidate baseline;
- what is intentionally excluded and why;
- what conflicts remain;
- what must be salvaged before further construction;
- which exact SHA becomes the next integrated baseline.

## Evolution clause

The branch map will continue changing. This protocol remains valid even if the preferred release branch, architecture or product goal changes. New lineages must be added to the ledger rather than forcing history into an outdated model.
