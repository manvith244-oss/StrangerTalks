# SEED-SAFETY-03 Witness Operational Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove or falsify browser durability, restart semantics, degradation states, and operational unlinkability assumptions for the frozen client-attested witness design.

**Architecture:** Keep all executable work under `seed/safety_03/` and a seed-only GitHub Actions workflow. Browser tests use Playwright 1.63.0 against Chrome for Testing, Firefox, WebKit, plus mobile WebKit emulation. Operational tests use a small in-memory witness state model whose only purpose is to expose restart/receipt/finalization trade-offs; it is not production server code.

**Tech Stack:** Node 22, `@playwright/test` 1.63.0, browser WebCrypto, IndexedDB, Node built-in test runner.

**Spec:** `docs/seeds/SEED-SAFETY-03-SPEC.md`

## Global Constraints

- Canonical `main` is read-only.
- Do not merge.
- Do not mutate production or production Supabase.
- Do not modify SEED-SAFETY-02.
- Do not integrate with current production message flows.
- Mode A is the privacy-leading reference, not final architecture.
- Mode B must not retain `finalized_at` unless this seed proves it necessary.
- No cloud backup.
- Cryptographic authenticity must remain separate from Safety adjudication.
- Native Safari/iOS claims require native evidence; Linux WebKit/emulation must be labeled accordingly.

---

### Task 1: Seed-only hostile operational tests

**Files:**
- Create: `seed/safety_03/package.json`
- Create: `seed/safety_03/test/operational_failures.test.mjs`
- Create: `seed/safety_03/test/browser_persistence.spec.mjs`
- Create: `seed/safety_03/playwright.config.mjs`
- Create: `seed/safety_03/src/test_server.mjs`
- Create: `.github/workflows/seed-safety-03.yml`

**Interfaces:**
- Consumes: no seed implementation.
- Produces: failing tests that import `src/operational_model.mjs` and exercise browser IndexedDB/CryptoKey behavior.

- [ ] Write Node hostile tests for receipt loss, delayed/duplicate receipts, key-history loss, restart, incomplete Mode B finalization, and explicit evidence classifications.
- [ ] Write browser tests that store non-extractable Ed25519 and AES-GCM CryptoKeys directly in IndexedDB, reload/restart the browser profile, then use the retrieved keys.
- [ ] Test isolated-context destruction, site-data deletion, and profile separation.
- [ ] Add Playwright projects for Chromium, Firefox, WebKit and WebKit mobile emulation with browser identities printed into test output.
- [ ] Add seed-only Actions workflow using Node 22 and Playwright 1.63.0.
- [ ] Run the workflow and confirm RED because the operational model is intentionally missing.

### Task 2: Minimal operational witness model

**Files:**
- Create: `seed/safety_03/src/operational_model.mjs`

**Interfaces:**
- Produces: `WitnessOperationalAuthority`, `HistoricalVerificationKeyRegistry`, `EvidenceClass`, `classifyEvidence`, `modeBFinalState`, and `restartAuthority`.

- [ ] Implement an in-memory session authority that can issue acceptance receipts and idempotently re-return a receipt only while live acceptance state exists.
- [ ] Make restart explicitly destroy active ephemeral session state while preserving only the supplied durable state.
- [ ] Model Mode A with no final commitment.
- [ ] Model Mode B final-only persistence and prove restart-before-finalization cannot establish complete final state.
- [ ] Model optional durable evolving Mode B accumulator metadata separately so its privacy cost is visible rather than hidden.
- [ ] Implement evidence classifications for: local evidence absent; malformed/invalid; endpoint-authentic but receipt missing; accepted excerpt; historical key unavailable; finalization incomplete; trailing omission; accepted complete.
- [ ] Every classification returns `safetyAdjudication: "NOT_DETERMINED"`.
- [ ] Run Node tests GREEN.

### Task 3: Real browser-engine execution

**Files:**
- Modify only seed workflow/config if execution fixes are required.

**Interfaces:** Browser output becomes evidence for the final persistence matrix.

- [ ] Install Playwright browser binaries and OS dependencies in GitHub Actions.
- [ ] Run Chromium/Chrome for Testing browser persistence tests.
- [ ] Run Firefox persistence tests.
- [ ] Run WebKit persistence tests.
- [ ] Run mobile WebKit emulation and label it non-native.
- [ ] Record exact browser versions and any key algorithms that fail structured-clone/persistence.
- [ ] Do not alter tests to hide engine-specific failures; classify them as seed evidence.

### Task 4: Operational linkability audit

**Files:**
- Create: `docs/seeds/SEED-SAFETY-03-LINKABILITY-AUDIT.md`

**Interfaces:** Produces a repository-grounded risk matrix; no production code changes.

- [ ] Record current logger metadata and whether it includes participant/conversation IDs.
- [ ] Record Phoenix channel logging behavior and telemetry ID prohibitions.
- [ ] Record durable Conversation participant linkage and Report participant/conversation linkage.
- [ ] Record request/trace identifiers as correlation surfaces.
- [ ] Check for Redis/Redix integration on canonical base and state the result.
- [ ] Classify backups, crash dumps, analytics/error monitoring and provider logs as potential join surfaces where identifiers are exported or retained.
- [ ] State whether a fresh `witness_session_id` remains unlinkable under each join surface.

### Task 5: Council report and final verification

**Files:**
- Create: `docs/seeds/SEED-SAFETY-03-REPORT.md`

**Interfaces:** Final evidence package for Evolution Council.

- [ ] Summarize exact branch/base/head and CI run IDs.
- [ ] Provide browser/persistence/key matrices and distinguish real engine evidence from native-platform gaps.
- [ ] Document server restart, receipt loss, finalization and historical-key behavior.
- [ ] Document Mode A/B operational comparison and whether `finalized_at` was necessary.
- [ ] Name all falsified assumptions explicitly.
- [ ] Verify branch diff is seed-only and canonical `main` is unchanged.
- [ ] Run the exact final head through the seed workflow and require a clean-tree proof.
- [ ] Keep branch unmerged.
