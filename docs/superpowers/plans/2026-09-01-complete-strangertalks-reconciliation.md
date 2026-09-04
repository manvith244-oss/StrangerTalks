# Complete StrangerTalks Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce one locally committed StrangerTalks candidate containing every compatible, validated, non-superseded product delta identified in the approved reconciliation specification.

**Architecture:** Start at the exact prep authority, establish its baseline, then create a real two-parent merge with integration. Port specialist deltas in authority-bounded waves, testing and committing each wave independently so regressions and policy blockers remain attributable.

**Tech Stack:** Elixir 1.15+, Phoenix 1.8, Ecto/PostgreSQL, JavaScript ES modules, Playwright, optional Python 3.13/FastAPI boundary.

**Spec:** `docs/superpowers/specs/2026-09-01-complete-strangertalks-reconciliation-design.md`

## Global Constraints

- Prep must remain `2724d655a1ab7502c0caa39c91644cd6559a5f96` and integration must remain `f781a0796e68db26409c1744d7633a22cc6b11d0` when composition starts.
- Use a real merge for prep plus integration; do not replace it with cherry-picks.
- Never resolve a shared file wholesale with `ours` or `theirs`.
- Preserve all validated prep and integration behaviors listed in the specification.
- Stop rather than invent product policy or weaken a safety invariant.
- Do not push, open a PR, modify existing release branches, modify `main`, deploy, or use production databases.
- Keep TLS deferred unless operational proof is conclusive.

---

### Task 1: Record the prep baseline

**Files:**
- Modify: `docs/superpowers/plans/2026-09-01-complete-strangertalks-reconciliation.md`

**Interfaces:**
- Consumes: exact prep checkout and local PostgreSQL test configuration.
- Produces: reproducible baseline command/results recorded in Git history and the session report.

- [x] Verify `git rev-parse HEAD`, both remote refs, branch name, origin URL, and clean status.
- [x] Install only repository-declared dependencies with `mix deps.get` and `npm install` when missing.
- [x] Run `mix compile --warnings-as-errors`.
- [x] Run `mix test` and record pass/fail counts.
- [x] Enumerate maintained `test/js/*_test.mjs` files and run them with Node.
- [x] Run available maintained Playwright/browser commands from repository workflows.
- [x] Run `mix precommit` and `git diff --check`.
- [x] Classify failures as baseline product, harness/environment, or flaky evidence before continuing.

**Recorded prep baseline — product SHA `2724d655a1ab7502c0caa39c91644cd6559a5f96`:**

- Environment: Windows, Elixir 1.17.3, OTP 27.3.4, Node 24.17.0, PostgreSQL 17; local test database only.
- `mix compile --warnings-as-errors`: PASS.
- `mix test`: 762 tests, 0 failures.
- `mix precommit`: PASS; 762 tests, 0 failures. The formatter exposed Windows line-ending churn, so the worktree was safely recreated from committed state with worktree-local `core.autocrlf=false`; no product delta was retained.
- Maintained K2 JS contract subset: product failures in expression entry/loader wiring and Node-unsafe `session_reconciliation_guard.mjs` import. CRLF-sensitive source-regex failures disappeared after the LF worktree correction and are classified as environment/harness failures.
- Maintained real-browser matrix against isolated `http://localhost:4010`: 152 tests, 97 pass, 55 fail. Direct failures include F04 stale-runtime listener cleanup, delivery-gap/disconnect behavior, desktop keyboard flow, and multiple UI visibility/interaction contracts; many remaining failures share uniform 30–35 second timeouts and require isolated per-suite comparison rather than being treated as independent regressions.
- `git diff --check`: PASS. Candidate was clean before composition.

### Task 2: Compose prep and integration

**Files:**
- Modify only files reported by `git merge --no-ff --no-commit origin/release/integration-2026-08-28`.
- Test: corresponding ExUnit, Node, and browser regressions for every conflicted subsystem.

**Interfaces:**
- Consumes: clean verified prep baseline.
- Produces: a two-parent merge preserving prep presentation/reliability and integration shell/reconciliation contracts.

- [ ] Reverify both remote SHAs immediately before `git merge --no-ff --no-commit origin/release/integration-2026-08-28`.
- [ ] Inventory conflicts with `git status --short` and inspect stage 1/2/3 blobs for each file.
- [ ] Resolve non-overlapping changes additively.
- [ ] Resolve high-risk shared surfaces by retaining their relevant tests and combining compatible behavior.
- [ ] Run focused tests for every conflicted subsystem.
- [ ] Run the full post-merge gate: `mix compile --warnings-as-errors`, `mix test`, maintained JS/browser suites, `mix precommit`, and `git diff --check`.
- [ ] Commit the merge only after the composed baseline is understood; stop on an owner-decision conflict.

### Task 3: Add atomic participant pairing reservations

**Files:**
- Modify: `lib/strangertalks_new/conversation_lifecycle/conversation_server.ex`
- Modify: `lib/strangertalks_new/matchmaking/queue_engine/matchmaking_engine.ex`
- Create: `priv/repo/migrations/20260830044500_create_participant_pairing_reservations.exs`
- Add focused tests from `origin/feat/participant-pairing-reservation-2026-08-30`.

**Interfaces:**
- Consumes: existing matchmaking and terminal lifecycle authority.
- Produces: atomic acquisition and terminal release of participant-pairing reservations.

- [ ] Diff implementation commits `4667ca5` and `ca69e52` plus their PostgreSQL tests against the composed tree.
- [ ] Run the imported acquisition/release tests before implementation and confirm the missing invariant fails.
- [ ] Port the additive migration and minimal engine/lifecycle delta.
- [ ] Run pairing, matchmaking, terminal, migration, and full ExUnit tests.
- [ ] Commit the verified pairing wave.

### Task 4: Add abuse, credential, and retention authority

**Files:**
- Port compatible deltas from `origin/newteam/core-authority`, `origin/team5/continuity-authority-2026-08-26`, and `origin/team7/privacy-retention-2026-08-26`.
- Test: their focused controller, channel, privacy, and retention suites.

**Interfaces:**
- Consumes: participant issuance, account/session continuity, lifecycle terminal records, and current schemas.
- Produces: pre-identity source limits, revocable participant credentials, and centralized retention cleanup.

- [ ] Audit each migration for additive, non-destructive behavior and timestamp collisions.
- [ ] Import focused regressions first and verify each missing invariant.
- [ ] Port source-rate-limit issuance controls without logging raw identity data.
- [ ] Port credential-version rotation and per-session revocation without broad logout side effects.
- [ ] Port retention policy/task/cleanup using the branch-established policy values unchanged.
- [ ] Run focused tests, all migrations, all ExUnit, `mix precommit`, and `git diff --check`.
- [ ] Commit the verified authority/privacy wave.

### Task 5: Reconcile terminal and Block truth

**Files:**
- Port compatible deltas from `origin/team2/terminal-truth-2026-08-26` and `origin/f-x07/canonical-terminal-truth`.
- Test: terminal mutation, idempotency, persistence, broadcast, browser, and observability suites.

**Interfaces:**
- Consumes: composed prep/integration terminal law.
- Produces: stale-transition rejection, privacy-safe observability, and Block broadcasts gated by durable terminal truth.

- [ ] Compare every source transition and broadcast change to current lifecycle code and tests.
- [ ] Add regressions that remain absent, then prove their failure.
- [ ] Port only compatible guards, observation points, and durable broadcast ordering.
- [ ] Stop if branch policies disagree about which persisted terminal state is canonical.
- [ ] Run all lifecycle/terminal/channel/browser tests and broad gates.
- [ ] Commit the verified terminal wave.

### Task 6: Reconcile call and normal-media hardening

**Files:**
- Port compatible deltas from `origin/team4/media-authority-2026-08-26` and `origin/team9/normal-media-hostile-2026-08-26`.
- Preserve prep call ABA and integration queued-SDP/TURN/import-isolation behavior.

**Interfaces:**
- Consumes: current call operation generations, signaling queue, TURN configuration, and volatile media store.
- Produces: stale-operation rejection, truthful screen-share authority, hostile metadata isolation, limits, and cleanup convergence.

- [ ] Compare `live_call.mjs` and normal-media implementations at source branches and candidate.
- [ ] Import still-applicable hostile regressions and demonstrate missing behavior.
- [ ] Port minimal call/media runtime deltas without replacing queued SDP, TURN, or import-safe boundaries.
- [ ] Run call, WebRTC, media, terminal-race, Node, and available real-browser tests.
- [ ] Run broad gates and commit the verified communications wave.

### Task 7: Reconcile expression, Settings, and focus

**Files:**
- Modify: `priv/static/assets/app.js`, Settings modules, and relevant browser tests.
- Port from Team 10, F06, and `fix/64-focus-race-heading-2026-08-30`.

**Interfaces:**
- Consumes: composed shell, route/history, expression continuity, risk-gradient Settings, and Conversation motion.
- Produces: inert reaction DOM, ordered preference reconciliation, and stable focus during arrival churn.

- [ ] Add hostile floating-reaction regression and replace only the network-derived `innerHTML` sink with inert DOM construction.
- [ ] Reconcile ordered preference saves with risk-gradient UI and current routes.
- [ ] Apply the focused arrival-churn correction without reverting current shell or message-focus behavior.
- [ ] Run expression, Settings, route/history, mobile, desktop, accessibility/focus, and browser suites.
- [ ] Run broad gates and commit the verified client wave.

### Task 8: Evaluate bounded Python and release authority

**Files:**
- Port compatible Python boundary and Elixir transport files from `origin/feature/first-safe-python-packet-2026-08-30`.
- Port compatible health/version files from `origin/team8/release-authority-2026-08-26`.

**Interfaces:**
- Consumes: existing Elixir Companion/provider and Req HTTP boundary.
- Produces: optional authenticated FastAPI reasoning boundary and safe runtime health/version metadata.

- [ ] Prove the Python service has no database, matchmaking, lifecycle, or safety-mutation authority.
- [ ] Confirm exact Python/dependency availability before changing the candidate.
- [ ] Port the boundary without replacing the Elixir Companion/provider.
- [ ] Run all Python tests and real Elixir-to-FastAPI boundary tests without requiring a live OpenAI call.
- [ ] Port health/version behavior only if compatible with current router and deployment configuration.
- [ ] Run focused and broad gates; commit compatible work or document a precise defer/block reason.

### Task 9: Evaluate and defer TLS

**Files:**
- Inspect only: `origin/phase3/prep-a-tls-proof-2026-08-29` and PR #123 deltas.

**Interfaces:**
- Consumes: current runtime database configuration and available operational proof.
- Produces: either evidence-backed compatible configuration or a documented deferral.

- [ ] Inspect the prior revert, CA pinning, local fallback, and proof scope.
- [ ] Do not integrate if production CA/runtime proof is incomplete or would require secrets/infrastructure changes.
- [ ] Record `DEFERRED — OPERATIONAL PROOF REQUIRED` unless all environments are conclusively supported.

### Task 10: Final capability and regression gate

**Files:**
- Modify only the reconciliation plan/report documentation needed to record exact evidence.

**Interfaces:**
- Consumes: all committed waves.
- Produces: exact candidate SHA, capability inventory, remaining-work ledger, and owner-review report.

- [ ] Reverify branch, ancestry, merge parents, status, migrations, and `git diff --check`.
- [ ] Run `mix compile --warnings-as-errors`, all ExUnit, maintained JS tests, available Playwright suites, and `mix precommit`.
- [ ] Run focused PostgreSQL pairing, terminal, retention, Bonds/Memory, and credential suites.
- [ ] Run Python boundary matrix if integrated.
- [ ] Audit the actual tree against every capability in the approved request.
- [ ] Report every skipped, superseded, deferred, blocked, and unresolved item without pushing or deploying.
