# Team 4C — Isolated Release Matrix, Staging Isolation and Deployment Recovery

**Date:** 2026-10-08 (Asia/Kolkata). **Global-access beta target:** 2026-10-18.  
**Verdict:** **NO-GO**. The three isolated release reproductions passed; this does **not** authorize or prove a Render staging deployment.

## A. Verified baseline and inheritance

- Current `main`: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e` (checked via GitHub branches/main API).
- Team 4 audit: `a2433a56adfd64656937ff987b739b4012e9a77d`; Team 4B audit: `b02c79767fe8866b6eafee667e726b12404a235c`. Neither documentation branch was assumed merged.
- Team 4C base: canonical main above. Engineering branch: `audit/team4c-isolated-release-2026-10-08`.
- Team 4C executable workflow commit: `d77f57dd6863699e8ec7e5eb23f3fc7177d0b3b9`.
- Render production service `srv-da4qm0e417fc73c2ejp0`: configured branch `release/prep-2026-08-22`, last recorded live deployment `dep-dakf06rm8hqs73ecjio0` at `6f43cddab8812be9e0baaf80b2a6779410849948`; later `dep-dapt5s0473hc73c65om0` for `fb73a1faec28393624af09da50845d84a3e5c128` ended `update_failed`.
- Render staging service `srv-dah8v8jl550s73e3lfbg`: configured branch `staging/candidate-2026-09-10`; three failed September 10 attempts for `777439b3c28c0554ac438a348620f46e0cd27b24`; no confirmed live staging release.
- Both Render web services: free plan, one instance, auto-deploy off, no HTTP health-check path configured; migration wrapper runs before OTP application startup.
- Open unmerged work observed: PR #295 responsive remediation, #294 Team 1B partial recovery, #293 Team 2B safety/privacy decisions, #292 compact Voice sheet, #291 session-cache hardening, and #269/#270 experimental H-01. Do not imply any shipped behavior from these branches.
- Historical Render exit code 1 with successful builds was inherited and remains unexplained; earlier log queries did not reveal the exception.

## B. Executed isolated CI — actual results

**Workflow file:** `.github/workflows/team4c-isolated-release-reproduction.yml`.  
**Executed push workflow:** https://github.com/manvith244-oss/StrangerTalks/actions/runs/37709716121  
**Workflow head SHA:** `d77f57dd6863699e8ec7e5eb23f3fc7177d0b3b9` (contains the workflow), **distinct from tested source SHA**.  
**Execution:** 2026-10-08T00:48:56Z–00:51:01Z; workflow conclusion **success**, three matrix jobs **success**.

| Job | Exact checkout SHA | Dependencies/build | PostgreSQL 17 migration 1 / 2 | OTP startup / HTTP / live / ready / version / shutdown | First failing stage |
| --- | --- | --- | --- | --- | --- |
| Historical staging | `777439b3c28c0554ac438a348620f46e0cd27b24` | PASS | PASS / PASS | PASS / PASS / PASS / PASS / PASS / PASS | None |
| Historical production | `fb73a1faec28393624af09da50845d84a3e5c128` | PASS | PASS / PASS | PASS / PASS / PASS / PASS / PASS / PASS | None |
| Canonical main | `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e` | PASS | PASS / PASS | PASS / PASS / PASS / PASS / PASS / PASS | None |

Each matrix job uses Ubuntu 24.04, Elixir 1.18.4, Erlang/OTP 27.3.4, Node 22, `postgres:17` sidecar, temporary self-signed test CA and leaf certificate for localhost/127.0.0.1, certificate-verified local PostgreSQL TLS, explicit synthetic `DATABASE_URL`, `DB_CA_CERT_FILE`, `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER`, `RENDER_GIT_COMMIT`, and `PHASE1_REHEARSAL=0`. Connection verification checks actual PostgreSQL SSL status. No real provider secrets are referenced, and no external database is involved.

The 21 numbered stages are separate, independently visible GitHub Actions steps: exact checkout and clean-tree check; BEAM/Node installation; PostgreSQL 17 verified TLS setup; Hex/Rebar; lockfile dependency resolution and compilation; application compilation; production assets; OTP release; executable/rehearsal-guard inspection; release runtime evaluation; first and second release migration; application process start; HTTP port; each of the three health endpoints; clean shutdown. A failing stage fails the job and prints sanitized OTP startup logs when available.

**Not tested by this workflow:** full `mix precommit`, JS suite, `mix hex.audit`, application-level WSS match/reconnect, real capacity, staging/production TLS destinations, Render native runtime, intentional DB-outage readiness behavior, external ingress, provider alerts, live secrets presence, or selected integrated release candidate. Do not treat the successful isolated result as a complete release gate.

## C. Root-cause classification

- `LOCAL/CI FAILURE REPRODUCED`: **NO**. All three candidate commits successfully built, migrated twice, started and answered health checks using the synthetic PG17/TLS configuration.
- `RENDER HISTORICAL FAILURE ROOT CAUSE VERIFIED`: **NO**.
- `RENDER HISTORICAL FAILURE ROOT CAUSE STILL UNKNOWN`: **YES**.
- Causal conclusion: the reported Render exit-code-1 is **not reproduced under CI conditions**. The differing Render environment, database hostname/TLS trust and auth, deployment/runtime configuration, and Render-native release environment are hypotheses requiring incident-specific evidence. Do not label any as verified.
- Migration wrapper inspection: optional `PHASE1_REHEARSAL=1` path exists in all three snapshots; the CI explicitly fixes it to `0`. No evidence that the historical Render services activated it. No code defect or regression-covered application patch was justified by this successful reproduction.

## D. Staging isolation (independent gate)

**Verdict: UNKNOWN — staging deploy/restart/migration forbidden.**  
**Method and timestamp:** read-only Render service records and Supabase project metadata retrieved 2026-10-08; operator-held staging `DATABASE_URL` identity was not available from the accessible Render API.

Current accessible Supabase account shows one active Singapore project `vgfnrcqrnryauhzfgseh` (PG17.6) and one inactive Tokyo project `nlrpogfkcfewvsctlmvn`. This inventory **does not** establish which database either Render service currently targets, or whether a separate staging database exists elsewhere. Neither database isolation nor permission separation can be inferred. No read/write staging DB test was performed.

**Founder/authorized operator manual procedure, before ANY staging runtime action:**

1. Open both Render Environment pages with authorized operator access. Without copying credentials, record PRESENT/ABSENT/INVALID/UNKNOWN for `DATABASE_URL`, `DB_CA_CERT_FILE`, `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER`, `PORT`, `POOL_SIZE`, `ECTO_IPV6`, experimental toggles, OAuth, AI and TURN integrations.
2. Compare the actual DB **host/project, database name and role identity** for production versus staging in a private privileged session. Do not publish connection strings, passwords, tokens or environment screenshots with values.
3. If an independently controlled staging DB exists, validate server/project identity using a directly authorized **read-only** connection and inspect schema, migration ledger, role privileges, absence of production data, and whether any production database is reachable from staging. Inspect independent credentials and external integration destinations/scheduled jobs.
4. Record evidence timestamp, verifier role, non-secret identity evidence, and PASS/FAIL/UNKNOWN for each dimension. Complete `PASS` only if production cannot be reached or affected and staging is fully separated.
5. If staging points to production, mark FAIL and stop. If unknown, mark UNKNOWN and stop. Propose separation for founder approval; do not connect, restart, deploy, migrate, restore, create resources or alter config as a workaround.

The current API's inability to display environment-variable values is a hard **verification-access** blocker, not proof of database isolation.

## E. Engineering changes and tests

- Branch: `audit/team4c-isolated-release-2026-10-08`
- Base: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e`.
- Tested workflow commit: `d77f57dd6863699e8ec7e5eb23f3fc7177d0b3b9`.
- Modified/added engineering file: `.github/workflows/team4c-isolated-release-reproduction.yml` (isolated CI only). No application code, runtime config, Render/Supabase infrastructure, existing release workflows or production data changed.
- CI regression evidence: exact-SHA, full release packaging, synthetic runtime, PG17 TLS, idempotent release migrations, process survival, HTTP readiness/version and shutdown. All 3 jobs pass.
- The diagnostic workflow reuses the Team 8/9 tested BEAM and release commands but does not replace either production release workflow. It is restricted to the Team 4C branch / manual dispatch.

## F. Approval-ready staging **plan**, not approval to deploy

**Candidate for diagnostic staging only:** `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e` (isolated CI green). This is **not** a globally integrated launch candidate; Teams 1B/2B/3B and security choices remain outstanding. **STAGING DEPLOYMENT: NOT READY FOR APPROVAL** while database isolation is UNKNOWN.

Upon a separate explicit founder approval *after* complete isolation proof:

1. Record candidate full SHA, source branch and unmerged PR exclusions; verify prior/target DB migration ledger and schema compatibility; obtain fresh accessible backup/restore proof for the isolated target and a manual recovery path.
2. Confirm required environment settings by presence/validity (never print secrets), correct target hostname and CA chain, `PHASE1_REHEARSAL` disabled, experiment flags disabled, and nonproduction integrations.
3. Plan Render staging branch/SHA selection, and the existing startup command `bin/migrate && exec bin/strangertalks_new start`, but **do not execute** without separate approval. Capture process/migration logs without message contents, IDs, tokens or secrets.
4. After an approved deploy, prove migration and repeat migration, exact `/health/version` SHA, `/health/live`, database-backed `/health/ready`, TLS/HTTP ingress, two real browsers matching and ending a conversation, reconnect, safety/report controls and database-down readiness behavior.
5. Propose Render HTTP health-check path `/health/ready` only after that behavior is validated. Do not invent endpoints or change live config automatically.
6. Abort on ambiguous DB target, any production write path, incompatible migration, unexpected third-party traffic, startup loop, incorrect SHA, health failure, sensitive diagnostic output, or security/privacy veto. Preserve previous deployment reference. Favor forward recovery for incompatible schema changes; no automated downgrade/restore of production.
7. Record owner, exact start/end times, abort evidence, rollback-compatible binary, complete two-browser smoke and central release acceptance. Separate founder approval still required for production.
8. **Spend:** none incurred by Team 4C; staging database creation or paid hosting may entail charges and requires separate quoted budget and founder authorization.

## G. Real WebSocket capacity and Team 1B handoff

Team 1B's separate partial candidate `67d3604a9fc2f43f4f75ef0e32dbf05e82cec517` reported its focused tests and synthetic pairing proof: https://github.com/manvith244-oss/StrangerTalks/actions/runs/37704424301. This is **not** evidence of real concurrent WebSockets or of integration into main.

Actual authenticated/anonymous WebSocket participant tiers: **20 NOT RUN; 50 NOT RUN; 100 NOT RUN; 200 NOT RUN**. The `test/load/phase_6f.exs` harness is a local/test-mode synthetic workload, not a substitute.

For Team 1B's isolated runtime, provide CPU/RSS sampled over startup/steady/drain, BEAM schedulers/process mailbox pressure, Ecto pool checkout wait and active connections, socket connect and disconnect counts, match wait p50/p95/p99, failures/429s, successful block/report and terminal semantics, window duration, saturation and recovery-after-crash. Keep one authoritative Phoenix node; don't enable extra replicas. Publish no beta admission ceiling until a real WSS proof passes on an identified SHA.

## H. Recovery and monitoring

Preserve existing successful R2 public-schema backup/download/checksum/PG17 restore proof: https://github.com/manvith244-oss/StrangerTalks/actions/runs/37596050409 and https://github.com/manvith244-oss/StrangerTalks/actions/runs/37440397535. Do not repeat them merely for optics.

Still missing: independent disaster access, documented bucket object retention/lifecycle, proof that non-public settings/integrations can be restored, operator-owned emergency procedure, alert delivery to a named human, start-failure notifications, monitored health/version, a stage-tested schema-compatible rollback, a real measured RTO/RPO, and explicit founder acceptance of free-instance spin-down/restart limitations. No production recovery rehearsal was performed.

## I. Inherited INF-01 through INF-09 register

| ID | Inherited | New Team 4C evidence | Current | Owner / precise closure |
| --- | --- | --- | --- | --- |
| INF-01 (P0) | BLOCKED | Supabase project inventory is not Render staging DB target proof | **BLOCKED** | Founder/operator: read-only host/project/role/data/integration isolation certificate |
| INF-02 (P1) | OPEN | All three CI releases pass; historic Render crash unreplicated | **OPEN** | Release/SRE: obtain incident-specific sanitized Render trace and verified cause or a separately documented Render-specific resolution |
| INF-03 (P1) | BLOCKED | Main's isolated release smoke passes; no staging deploy | **BLOCKED** | Founder/Release: certified isolated DB, approved exact staging deployment and health/migration evidence |
| INF-04 (P1) | OPEN | CI tests HTTP health only, not WSS or two-browser flows | **OPEN** | Teams 1B/2B/3B: exact SHA real WSS, safety, privacy and UX lifecycle proof |
| INF-05 (P1) | OPEN | No real load; synthetic Team 1B test isn't a capacity proof | **OPEN** | Team 1B/SRE: isolated 20/50/100/200 real sockets and tested safe limit |
| INF-06 (P1) | OPEN | Prior backups retained; alerts, independent recovery and owner not proved | **OPEN** | Founder/SRE: independent access, retention, alert drill, rollback and operator |
| INF-07 (P1) | OPEN | Reproduction covers current main, not integrated accepted PR state | **OPEN** | Central Command: freeze integrated candidate, satisfy security/reliability/UX/operational gates, authorize |
| INF-08 (P2) | OPEN | `/health/ready` works on isolated DB; no Render health path modified | **OPEN** | SRE/founder: approved stage health path and DB-down behavior verification |
| INF-09 (P2) | OPEN | Render Free single-node risk remains | **OPEN** | Founder/SRE: explicit availability/budget decision with verified cost/limits |

## J. Launch verdict

**NO-GO.** Team 4C **closes the previously missing executable, disposable PG17 release-reproduction evidence** for three exact source SHAs; it does **not** clear staging DB isolation, explain historic Render exit 1, prove real WSS capacity or authorize a deploy. No paid resource or live environment was created or changed.

## K. Successor handoff — only unfinished work

1. Authorized founder/operator establishes staging DB and integration separation using the manual procedure in section D. If UNKNOWN, keep stage stopped.
2. Obtain incident-specific sanitized Render startup exceptions and compare runner/release and real DB hostname/TLS/config to the now-green isolated job; do not repeat the same three broad CI runs without new evidence.
3. When isolation is PASS and founder explicitly approves, run a controlled exact-SHA staging diagnostic release and capture migration/start/HTTP/WSS evidence. Do not describe proposal as deployment.
4. Team 1B supplies real WSS scenarios and capacity limits; Teams 2B/3B supply security/UX gate approval; Central Command resolves integrated launch candidate and release authority.
5. Close only outstanding INF gates, followed by separately authorized rollback/alerts drill and, much later, production promotion.

**TEAM 4C STATUS: PARTIAL**  
**INHERITED TEAM 4B SHA:** `b02c79767fe8866b6eafee667e726b12404a235c`  
**CURRENT MAIN SHA:** `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e`  
**EXECUTION BRANCH:** `audit/team4c-isolated-release-2026-10-08`  
**EXECUTED WORKFLOW COMMIT SHA:** `d77f57dd6863699e8ec7e5eb23f3fc7177d0b3b9`  
**ISOLATED RELEASE CI:** PASS — three exact-SHA jobs  
**POSTGRESQL 17 MIGRATION PROOF:** PASS — first/repeat for all three  
**APPLICATION STARTUP PROOF:** PASS — all three exact SHAs  
**HISTORICAL RENDER ROOT CAUSE:** UNKNOWN  
**STAGING DATABASE ISOLATION:** UNKNOWN  
**STAGING DEPLOYMENT:** NOT AUTHORIZED  
**REAL WEBSOCKET CAPACITY:** NOT RUN for 20/50/100/200  
**OPEN INFRASTRUCTURE P0/P1 GATES:** INF-01 through INF-07  
**TEST EVIDENCE:** https://github.com/manvith244-oss/StrangerTalks/actions/runs/37709716121  
**FOUNDER ACTION REQUIRED:** staging env/DB authorized read-only identity verification; later explicit isolated deployment/budget approval and incident ownership  
**NEXT TEAM MUST START FROM:** staging isolation read-only operator verification, then Render-specific incident diagnostics with green CI comparison  
**TEAM 4C DISSOLVED**
