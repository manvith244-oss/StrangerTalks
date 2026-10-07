# Team 4B — Staging Recovery and Release Engineering: Evidence Checkpoint
Date: 2026-10-08 (Asia/Kolkata) · Target: 2026-10-18 · Verdict: **NO-GO / PARTIAL**

> Read-only infrastructure and source investigation, plus this documentation. **No Render deploy/restart, Supabase mutation, staging/prod migration, paid plan, secret change, or main merge was executed.** This is not a claim of deployment repair.

## Inherited and current source state
- Canonical `main`: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e` (still newest indexed main commit at audit time).
- Team 4 original audit: `a2433a56adfd64656937ff987b739b4012e9a77d`, on `audit/team4-infra-launch-2026-10-08`.
- Team 4 canonical source: `docs/TEAM4_INFRA_GLOBAL_LAUNCH_AUDIT_2026-10-08.md` at that audit commit.
- This checkpoint branch is constructed from canonical `main`; Team 4's audit is inherited evidence, not implicitly merged application code.
- PR #291 (Team 2 account credential-cache hardening) remains a draft; PRs #269 and #270 remain experimental drafts. No H-01 activation or PR merge.
- GitHub compare: production live SHA `6f43cddab8812be9e0baaf80b2a6779410849948` is **11 commits behind main**; staging failed SHA `777439b3c28c0554ac438a348620f46e0cd27b24` is **44 commits behind main**. Compare counts are source history, not deployed-feature proof.

## Current Render inventory and release history
| Service | ID | Branch configured | Deployment / outcome | Plan | Auto deploy | HTTP health path |
|---|---|---|---|---|---|---|
| Production | `srv-da4qm0e417fc73c2ejp0` | `release/prep-2026-08-22` | `dep-dakf06rm8hqs73ecjio0` live at `6f43cdda...`; `dep-dapt5s0473hc73c65om0` at `fb73a1fa...` failed 2026-09-23 | Free / one instance | Off | empty |
| Staging | `srv-dah8v8jl550s73e3lfbg` | `staging/candidate-2026-09-10` | `dep-dah914lbedkc739lb5ng` at `777439b3...` failed 2026-09-10; preceding two attempts failed | Free / one instance | Off | empty |
| Legacy Node | `srv-d8ivl6l8nd3s73e1iccg` | `master` | redirect behavior not exercised in this pass | Free / one instance | On | empty |

Provider links:
- Production: https://dashboard.render.com/web/srv-da4qm0e417fc73c2ejp0
- Staging: https://dashboard.render.com/web/srv-dah8v8jl550s73e3lfbg

## P0: staging database isolation — **UNVERIFIED; EXECUTION BLOCKED**
Render `get_service` exposes deploy/start commands but **does not expose deployed environment-variable values or even a redacted per-variable presence inventory**. Neither `DATABASE_URL` hostname nor target database identity can be established from the available read surface. Therefore one cannot prove separate secrets, roles, dataset, integrations, migration permissions, feature flags, or absence of production connectivity.

The available Supabase account lists (a) active healthy `vgfnrcqrnryauhzfgseh` in Singapore and (b) inactive `nlrpogfkcfewvsctlmvn` in Tokyo; there are zero development branches under the active project. Neither fact proves which URL the Render staging service uses, and an external/other-account staging database remains possible. **No inference of isolation should be made.**

Staging and production both use this start command:
```bash
_build/prod/rel/strangertalks_new/bin/migrate && exec _build/prod/rel/strangertalks_new/bin/strangertalks_new start
```
A stage restart/deploy could execute migrations against an unknown DB. **Do not deploy/restart staging or run migrations.**

### Authorized operator gate (do not publish values)
1. In Render dashboard, inspect production and staging environment *without pasting secrets into chat, issues, screenshots, or logs*. Record only `PRESENT/ABSENT/INVALID/UNKNOWN` for `DATABASE_URL`, `DB_CA_CERT_FILE`, `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER`, `PORT`, `ECTO_IPV6`, `POOL_SIZE`, experiment flags, external integrations and scheduled jobs.
2. Verify **database target identity via a safe authorized read-only connection**, not by printing the URL: compare project IDs/host identity, database name, server identity, database owner/role, and schema/migration ledger. Do not run a staging command until its URL has been certified independent of production.
3. Confirm staging has no production data, cannot connect to production, has separate credentials and integrations, and permits only approved migrations. Record non-secret evidence.
4. If any dimension is unknown, maintain **STAGING ISOLATION: UNVERIFIED — EXECUTION BLOCKED**. A new isolated database, Render config change or stage deploy requires explicit founder authorization.

## P1: deployment exit 1 — still unverified
Render historical events prove:
- Staging on 2026-09-10: three builds succeeded and all deployments ended `nonZeroExit:1`.
- Production attempt on 2026-09-23: build `bld-dapt5s0473hc73c65oog` succeeded; the deployment ended `nonZeroExit:1`; multiple `server_failed` code-1 events were seen around 2026-09-22/23, including around the older live build.
- Separate staging (2026-09-10 11:07–11:16 UTC) and production (2026-09-23 13:22–13:30 UTC) log API queries yielded **zero retained app/build log records**.

Code inspection:
- `config/runtime.exs` requires `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, validates DB URL hostname and TLS CA settings, and may raise on invalid feature settings.
- `lib/strangertalks_new/release.ex` uses `Ecto.Migrator.with_repo` and runs all pending migrations; the shell `rel/overlays/bin/migrate` uses `set -eu` then an application `eval`.
- The migration command executes before Phoenix start. An exit code alone **cannot distinguish config evaluation, DB DNS/TLS/auth, schema migration, or OTP startup failure**.
- Older CA/TLS branches and the subsequently merged `73c8097e92df4faf41c2a1a330f7885b50ff1d77` contain a bundled Supabase trust anchor and tests, but **do not establish historical root cause**. Stage failed SHA predates that merged CA work. Production failure happened later; avoid assuming the same cause.
- Render-native Elixir build/start are used; no unapproved switch to Docker or broad dependency upgrade.

**Next diagnosis in a disposable, separate environment:** reproduce the exact failed SHA with pinned Elixir/OTP; test dependency compilation, `mix release`, runtime config validation (synthetic values), `bin/migrate` on disposable PG17, second idempotent migration, start/endpoint, `/health/ready`, WSS. Capture first failing stage, exception and exact source/config line; only then write minimal regression-covered code fixes. Request redacted historical logs from provider if available. Treat lack of historical logs as missing evidence, not proof of a candidate cause.

## Readiness and capacity
Existing routes `/health/live`, `/health/ready` (DB `SELECT 1`), `/health/version` exist in source. No stage health check, two-browser lifecycle or WSS was executed. Recommending `/health/ready` in Render **is a proposal requiring approval**, not a completed config change.

`test/load/phase_6f.exs` exists, is explicitly gated to `MIX_ENV=test`, and ramps 5, 10, 25, 50 fixture/conversation state; it is not a browser/socket workload and cannot alone certify concurrent anonymous users. Render production CPU, memory, instances and request metric queries for 2026-10-06 through 2026-10-08 returned empty arrays.

| Anonymous participants | Status | Measured capacity |
|---|---|---|
| 20 | NOT RUN | UNVERIFIED |
| 50 | NOT RUN | UNVERIFIED |
| 100 | NOT RUN | UNVERIFIED |
| 200 | NOT RUN | UNVERIFIED |

**SAFE TESTED CAPACITY: NONE VERIFIED.** Capacity recommendation awaits isolated socket+match+chat+reconnect benchmarks at fixed SHA, with CPU/RSS/DB pool, match rate, queue wait, latencies, disconnects, and rate-limit responses.

## Recovery, telemetry, and operating risk
Inherit Team 4's October 6/7 successful GitHub R2/isolated PostgreSQL17 public-schema backup+restore proof. Do not repeat without a gap. R2 retention, separate operator credentials, private/schema-external recovery, alert delivery, verified RPO/RTO and full replacement-environment restoration remain unverified.

No new alerts, health paths, config, backups, costs, or production resources were changed. Runbooks still need operator ownership. Preserve content-blind monitoring: never log chat bodies, tokens, participant IDs, sensitive reports or raw private payloads. Coordinate telemetry approval with Team 2.

Elixir/Erlang/Docker/PostgreSQL client executables are unavailable in the current working container, so no local release, database, migration, full test, WebSocket or load proof was attempted. Static code reading is not runtime verification.

## Release blocker registry
| ID | Severity | Owner | Status | Exact closure gate |
|---|---|---|---|---|
| INF-01 | P0 | Founder + Team 4B successor | BLOCKED | Certified DB/secret/integration separation for staging before any restart |
| INF-02 | P1 | Release engineering | OPEN | Exact nonzeroExit:1 reproduction/root cause, minimal fix if needed, regression proof |
| INF-03 | P1 | Release engineering + Founder | BLOCKED | Authorized deployed isolated staging SHA, migrations/idempotence, readiness |
| INF-04 | P1 | Team 1/2/3 + Release engineering | OPEN | Real WSS/two-browser lifecycle, report/block and privacy gates on exact SHA |
| INF-05 | P1 | Performance/SRE | OPEN | Isolated 20/50/100/200 socket workload evidence and tested admission cap |
| INF-06 | P1 | Founder + SRE | OPEN | Proven backup access/retention, verified alert delivery, safe rollback, named operator |
| INF-07 | P1 | Central Command | OPEN | Integrated candidate SHA, security/team gates, CI and launch scope approval |
| INF-08 | P2 | SRE | OPEN | Actual runtime health check path configured after authorization; verified DB-down semantics |
| INF-09 | P2 | Founder + SRE | OPEN | Paid hosting budget and single-node availability risk explicitly accepted or mitigated |

## Release gates: evidence vs not run
- PASS (inherited): successful 2026-10-06/07 scoped backup/restore jobs from Team 4's cited GitHub Actions evidence.
- VERIFIED SOURCE ONLY: health endpoints and migrations entrypoint exist; runtime config validates essential env/TLS.
- NOT RUN: `mix test`, `mix precommit`, `mix hex.audit`, maintained JS tests, full release build, migration rehearsal, stage deployment, readiness behavior, WSS, browser smoke, capacity, alert/fire drills and rollback simulation.
- NO production release or staging deploy authorized; no exact integrated candidate selected.

## Decision and next handoff
**Team 4B recommendation: NO-GO.** Do not approve a global beta or invent a concurrency cap. Work can continue safely on staging isolation verification and disposable release reproduction, but live staging work waits for founder permission.

**What not to repeat:** Team 4's full read-only topology audit or already passing R2 public-schema restore proof; do not rewrite health endpoints, activate H-01, merge PR #291, rework Teams 1–3's domain ownership, or touch main.

**Next team starts from:** obtaining redacted read-only Render env access and proving staging database identity. In parallel, replay historical SHA on disposable PG17 and secure readable sanitized startup output. After finding the first failure, make one targeted code/config patch with a test, then request authorization before any live stage change.

TEAM 4B STATUS: PARTIAL  
INHERITED BASE SHA: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e`  
FINAL BRANCH: `audit/team4b-staging-recovery-2026-10-08`  
FINAL COMMIT SHA: see GitHub branch tip  
STAGING ISOLATION: BLOCKED  
DEPLOYMENT ROOT CAUSE: UNVERIFIED  
STAGING STATUS: BLOCKED  
SAFE TESTED CAPACITY: NONE VERIFIED  
BACKUP AND RECOVERY STATUS: scoped R2 restore proof inherited; full recovery unverified  
PRODUCTION RELEASE: NOT AUTHORIZED  
OPEN P0/P1 BLOCKERS: INF-01 through INF-07  
TESTS PASSED: none newly executed  
TESTS FAILED OR NOT RUN: runtime, Elixir, JS, WSS, capacity, recovery, rollback all not run  
CROSS-TEAM DEPENDENCIES: Teams 1, 2, 3, 5B and Central Command  
FOUNDER DECISIONS REQUIRED: isolation access/creation, isolated staging deployment, health path, eventual hosting upgrade, on-call ownership  
NEXT TEAM MUST START FROM: staging DB isolation identity proof and isolated release exit-1 reproduction  
TEAM 4B DISSOLVED
