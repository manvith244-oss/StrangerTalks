# 10 — Branch Salvage Ledger

Status: ACTIVE / PARTIAL / MUST EXPAND

Research date: 2026-09-02

This ledger records capability-level branch truth. It is deliberately incomplete until T00 finishes archaeology. `PARTIAL` means absence from this table is not evidence that a branch is irrelevant.

## Classification key

- CANONICAL
- INTEGRATED
- SUPERSEDED
- SALVAGE
- CONFLICT
- PROOF / DIAGNOSTIC ONLY
- ARCHIVE
- REVIEW REQUIRED

## Current entries

| Branch / lineage | Observed head / reference | Capability | Evidence observed | Preliminary classification | Action |
|---|---|---|---|---|---|
| `main` | `83e8ee9cdd6131c0bcfdeb217cb3de5327d8b7f2` | proof/workflow lineage | observed tree lacks full Phoenix app; no common ancestor reported with inspected release branches | ARCHIVE / SEPARATE LINEAGE REVIEW | do not use as sole construction baseline |
| `master` | `82ed9df067f2bbf89a65561a5f1916865a539730` | legacy Render/Phoenix cutover lineage | no common ancestor reported with current prep | REVIEW REQUIRED | classify deployment historical role |
| `release/prep-2026-08-22` | `2724d655a1ab7502c0caa39c91644cd6559a5f96` | full Phoenix release-prep lineage | full app tree, docs, tests, workflows; many later merges | CURRENT HOST / NOT CANONICAL VERDICT | use for docs hosting and semantic comparison |
| `release/integration-2026-08-28` | `f781a0796e68db26409c1744d7633a22cc6b11d0` | controlled composition of specialist frontend/realtime work | diverged from prep; 32 ahead / 83 behind relative to prep comparison | CONFLICT / HIGH-PRIORITY INTEGRATION INPUT | reconcile with prep semantically |
| `feature/first-safe-python-packet-2026-08-30` | branch observed in current repo | Python/FastAPI internal AI boundary + Elixir client | FastAPI, OpenAI, Pydantic, HTTPX, OpenTelemetry, service auth, privacy helpers, circuit breaker, tests, CI | SALVAGE / ARCHITECTURE REVIEW | T06+T11 evaluate extraction; port only if accepted |
| `feat/participant-pairing-reservation-2026-08-30` | branch observed in current repo | durable participant pairing reservation/concurrency | migration with active-participant unique index; Matchmaking/Conversation changes; extensive acquisition/release tests | SALVAGE / CORE CONCURRENCY REVIEW | T01+T02 prove against current candidate |
| `team7/privacy-retention-2026-08-26` | branch diverged 28 ahead / 328 behind current prep | retention/privacy authority | centralized retention policy, cleanup service, operator task, DB/privacy/media/telemetry tests and workflow | SALVAGE + POLICY CONFLICT REVIEW | port invariants deliberately; reconcile current schema/legal/product policy |
| `phase3/prep-a-tls-proof-2026-08-29` | one unique commit vs merge base | database TLS runtime proof | current diff vs prep contains only `runtime_db_ssl_config_test.exs`; implementation not in that branch delta | PROOF / DIAGNOSTIC ONLY unless later implementation located elsewhere | trace intended implementation/proof lineage; do not merge test alone as feature |
| `fix/rank5-draft-test-sync-2026-08-30` | two commits; one-line test delta vs current prep | Conversation draft browser synchronization | only `conversation_draft_browser_test.mjs` 1-line test change in compare | PROOF/HARNESS FIX CANDIDATE | verify current test contract before integrating |
| `f06/settings-secondary-flow-2026-08-26` | specialist branch | settings/reflections/preference serialization | branch contains secondary-flow and preference-save implementation/tests; later integration history contains F06-related authority | LIKELY INTEGRATED / SEMANTIC VERIFY | map exact consumption path; do not re-merge branch wholesale |
| `f-x07/canonical-terminal-truth` | open specialist lineage | alternate terminal-truth/matching-rules work | differs from the later canonical `fx07/canonical-terminal-truth-2026-08-27`; PR history explicitly preserved the latter and excluded this branch | SUPERSEDED / REVIEW FOR UNIQUE TEST VALUE | do not treat open PR as newer authority |
| `fx07/canonical-terminal-truth-2026-08-27` | `01d20a8261fed0a490e3c6c1ac723f37f2f19b72` source lineage | canonical terminal-truth boundary | PR history marks exact proven head and controlled consumption into integration | INTEGRATED / PROVEN SOURCE LINEAGE | preserve provenance; current code still requires semantic regression proof |
| `settings-risk-gradient-2026-08-29` | merged through PR #128 into prep lineage | presentation-only Settings risk gradient | PR scope limited to Settings presentation/runtime/tests; merged into prep | INTEGRATED | no separate salvage unless later diff proves missing behavior |
| `doors-visual-structure-2026-08-30` | `5e37dfc1510b7c0df36c736baf17a5383b14f95d` merged through PR #134 | Doors presentation restructuring | merged into prep head `2724d655...`; PR documents known regression evidence during development | INTEGRATED | preserve current prep version; verify composed browser behavior |
| `fix/module-purity-node-imports-2026-08-30` | merged through PR #139 | isolate browser-only media startup from pure Node helper import | current integration contains later merge lineage; compare branch is behind integration | INTEGRATED | archive specialist branch after provenance capture |
| `fix/group-a-oncurrent-stale-assertions-2026-08-30` | merged through PR #141 | stale source-shape test corrections | PR explicitly test-contract correction only, no production code | INTEGRATED / TEST FIX | retain as provenance of test-contract update |

## Important interpretation rules

### A branch can be older and still contain salvage value

`team7/privacy-retention-2026-08-26` is far behind current prep, but its unique retention/privacy implementation is substantial. This is exactly why branch age is not a discard rule.

### A branch can be open and still be superseded

The open `f-x07/canonical-terminal-truth` lineage is not automatically the latest terminal authority. PR history identifies another exact proven terminal-truth lineage that was deliberately consumed into integration.

### A branch can be merged and still need current proof

Integration provenance proves where behavior came from, not that later composition preserved it perfectly. Shared seams still require current-candidate regression testing.

### A branch can contain only proof, not the feature

TLS proof and validation branches may contain tests/workflows without the corresponding implementation. T00 must trace the implementation separately before classifying the capability as missing or complete.

## Next ledger expansion

Prioritize classification of:

1. all open PR heads;
2. Teams 1–11 historical specialist branches and their integration carriers;
3. Conversation UI and F01–F11 lineages;
4. media/normal-media/expression branches;
5. account/continuity/credential-revocation branches;
6. release authority / production hardening branches;
7. current Python/AI packet lineage including backup/pre-rebase branches;
8. diagnostics that contain unique tests worth preserving;
9. any branch after 2026-08-30 not represented in current PR history;
10. production deployment SHA lineage.

## Evolution clause

Classifications are evidence-backed but revisable. When stronger evidence changes a classification, update the row and preserve the previous reason in commit history or an ADR/handoff rather than silently pretending the earlier classification never existed.
