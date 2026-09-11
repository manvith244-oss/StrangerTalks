# Branch Ledger Coverage Check — 2026-09-11

Baseline: `main@d69fd48889ba9c79a66a5653acd44ad329c97969`  
Observed live branch refs: **364**

The full branch search was paged through all returned refs. The following leading namespaces / top-level branch families were observed:

`adopt`, `agent-central`, `architecture`, `audit`, `backup`, `baseline`, `bisect`, `brand`, `central`, `checkpoint`, `ci`, `codex`, `construction`, `convergence`, `diag`, `diagnostics`, `doors-visual-structure-*`, `evidence`, `experiment`, `f01`, `f02`, `f03`, `f04`, `f06`, `f07`, `f09`, `f10`, `f11`, `f-x07`, `feat`, `feature`, `fix`, `full-source-recovery`, `fx04`, `fx05`, `fx07`, `ignore`, `k`, `language`, `main`, `master`, `newteam`, `noop*`, `ops`, `phase3`, `probe`, `proof`, `reconcile`, `release`, `security`, `settings-risk-gradient-*`, `st-work-k`, `staging`, `t01`, `t08`, `team1`…`team13`, `team-a01`, `team-a04`, `temp`, `tmp`, `validation`, `verify`.

Every observed family is covered by either:

1. an explicit semantic entry in `BRANCH_DISPOSITION_LEDGER_2026-09-11.json`; or
2. a namespace provenance rule in that ledger.

Explicit exceptions are used wherever namespace classification would be unsafe, including:

- canonical `main`;
- audit branches;
- D5 Hangouts durable interactions → issue #266;
- Living Thread → issue #260;
- Circle FUTURE-001 / FUTURE-002 R&D;
- language P01 measurement/research docs;
- historical construction-system docs;
- #265 Ring/Hangout authority admission branch;
- superseded #248 Ring B1/B3 branch;
- admitted/superseded P02, CA, product-event, pairing and migration branches;
- verified fully-ancestral weird roots;
- disconnected historical `master` root.

## Coverage verdict

**Namespace coverage holes: 0 identified.**

This means there is no observed branch family that falls through the ledger without a classification rule. It does **not** mean all 364 refs are safe to delete. Namespace-derived entries remain provenance classifications, while destructive deletion still requires per-ref ancestry/reference checks.

The cleanup invariant remains:

> No historical branch may be merged because it merely appears ahead/diverged, and no branch may be deleted merely because its namespace looks temporary.
