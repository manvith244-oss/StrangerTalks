# StrangerTalks Team 4 — Infrastructure / SRE Global Launch Audit
Date: 2026-10-08 (Asia/Kolkata)
Baseline main: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e`
Target launch: 2026-10-18
Status: PARTIAL — evidence gathered; launch gate NOT cleared
Scope: Read-only production/staging/database inspection; this file is the only intended repo modification. No deployment or infrastructure mutations authorized.

## Sources and evidence
- Render production: https://dashboard.render.com/web/srv-da4qm0e417fc73c2ejp0
- Render staging: https://dashboard.render.com/web/srv-dah8v8jl550s73e3lfbg
- Latest main: https://github.com/manvith244-oss/StrangerTalks/commit/5058fc5c27045c008e1f1f8d66eb3d58aba2b00e
- Successful isolated backup+restore: https://github.com/manvith244-oss/StrangerTalks/actions/runs/37596050409 (2026-10-07), https://github.com/manvith244-oss/StrangerTalks/actions/runs/37440397535 (2026-10-06)
- Canonical application file references: `config/runtime.exs`, `config/prod.exs`, `lib/strangertalks_new_web/controllers/health_controller.ex`, `docs/PRODUCTION_OPERATIONS.md`, `.github/workflows/postgres-r2-backup.yml`, `test/load/phase_6f.exs`.
- Provider pricing references checked 2026-10-08: https://render.com/pricing ; https://render.com/docs/free ; https://supabase.com/pricing ; https://developers.cloudflare.com/r2/pricing/
- Source of exchange estimate: USD/INR 96.7571 (retrieved for 2026-10-08); not a locked billing rate.

## Current architecture (verified vs conceptual)
Browser HTTPS/WSS -> Render Phoenix/Bandit service (Singapore, free plan, one instance) -> PostgreSQL 17.6 on Supabase (Singapore, Free organization), using Ecto/Phoenix. A legacy Node Render service remains separately configured on `master` with auto-deploy enabled; its historical role as redirect bridge is documented but its current redirect behavior has not been exercised. An application-level local/ephemeral runtime owns realtime queue/ConversationServer state. No Render PostgreSQL or Key Value instance was returned by the live Render account inventory. A GitHub scheduled backup pipeline uses `pg_dump` of `public`, Cloudflare R2 round-trip, and a disposable PostgreSQL 17 restore proof.

**Documentation drift:** `docs/PRODUCTION_OPERATIONS.md` (dated 2026-08-24) still depicts Render Postgres with expired Free instance. Live infrastructure now shows Supabase Singapore and no Render Postgres. Treat old topology as history, not current operations.

## Exact deployment inventory
| Service | Render id | Selected branch | Latest deployed attempt | Verified running release | Auto deploy | Health check |
|---|---|---|---|---|---|---|
| Production | srv-da4qm0e417fc73c2ejp0 | release/prep-2026-08-22 | fb73a1faec28393624af09da50845d84a3e5c128 (2026-09-23, update_failed) | 6f43cddab8812be9e0baaf80b2a6779410849948 (2026-09-15, live) | off | empty |
| Staging | srv-dah8v8jl550s73e3lfbg | staging/candidate-2026-09-10 | 777439b3c28c0554ac438a348620f46e0cd27b24 (2026-09-10, three update_failed) | NONE observed | off | empty |
| Legacy Node | srv-d8ivl6l8nd3s73e1iccg | master | not reconciled | not reconciled | on | empty |

Production selected git ref currently resolves to 6f43..., staging selected git ref currently resolves to 7774.... Main is 11 commits ahead of production live SHA and 0 behind, by GitHub commit comparison; among changed areas are matchmaking, participant channel, conversation runtime, JS UI, backup workflow and a database migration. Do not describe main features as shipped.

## Deployment incident diagnosis
Render events show `buildStatus=succeeded` on 2026-09-23 production (build bld-dapt5s0473hc73c65oog) and 2026-09-10 staging, followed by deployment process `nonZeroExit:1` and `update_failed`. On production, repeated `server_failed` exit-code-1 events also occurred around 2026-09-22 and 2026-09-23. The historical Render log API returned zero app/build logs for those windows. **Exact underlying exception/root cause is NOT VERIFIED.** Investigate in isolated staging, using redacted full startup logs:
1. Compare *presence and shape only* (never disclose values) of DATABASE_URL, DB_CA_CERT_FILE, SECRET_KEY_BASE, PHX_HOST, PHX_SERVER, PORT, ECTO_IPV6.
2. Confirm DNS/TLS peer verification from service to Supabase database.
3. Separate `bin/migrate` exit status from `bin/strangertalks_new start` exit status, and inspect migration ledger/schema compatibility.
4. Check immutable release packaging/runtime versions; Render-native Elixir build differs from Dockerfile-pinned Elixir 1.18.4/OTP 27.3.4.16. Do not silently migrate deployment mode.
5. **Before staging restart/deploy:** prove its `DATABASE_URL` points to an isolated, disposable database; current stage database isolation is unknown and startup invokes migrations.

The app implements `/health/live`, `/health/ready` (SQL SELECT 1), and `/health/version` (RENDER_GIT_COMMIT). Render uses an empty configured HTTP health path for both services. No successful external ingress proof was obtained in this audit; the external probes were inaccessible from the audit environment and Render historical metrics query returned empty arrays.

## Database posture (read-only snapshot)
Supabase project `vgfnrcqrnryauhzfgseh`: ACTIVE_HEALTHY, Singapore, PG 17.6; Free organization. Read-only SQL: total database size 13 MB, max_connections=60, sampled pg_stat_activity state active=1 idle=4 null=1 (not a capacity benchmark). Public schema has 33 tables, 32 with RLS enabled, no FORCE RLS. App migration ledger: 38 migrations, latest `20260915120000`. Estimated rows show a handful of test/early records; table stats are estimates, not exact counts. `public` role grant query did not expose direct anon/authenticated table grants in information_schema, but requires independent security verification.
Supabase advisor: 20 unindexed foreign-key notices, 1 public.source_rate_limits table without PK, 61 unused-index notices. These are advisories, NOT evidence of query slowness or authorization vulnerability. Do not add/drop indexes or policies until actual query plans, query patterns, RLS/grant contracts and Team 2 review.
Security linter returns 32 RLS-with-no-policy INFO notices. That can be intentional deny-by-default when Phoenix is the sole data gateway; do not create blanket policies or call this a proven breach.

## Backup / disaster recovery
Scheduled `postgres-r2-backup.yml` job runs daily; 2026-10-06 and 2026-10-07 scheduled runs succeeded. The 2026-10-07 run's 16 essential stages passed: credentials guard, TLS/CA validation, read-only pg_dump (public), upload to R2, download, checksum comparison, restore to disposable PG17, table/row matching and semantic schema comparison. Sanitized audit log indicators:
- `phase2_backup_size_bytes=157126`
- `phase2_r2_roundtrip_integrity=true`
- `phase2_restore_from_r2_completed=true`
- `phase2_table_sets_match=true`
- `phase2_row_counts_match=true`
- `phase2_semantic_schema_match=true`
- `PHASE2_RESTORE_PROOF=PASS`
- `PHASE2_RESULT=PASS`
This establishes a real automated restore drill for the included `public` schema. It does not prove restoration of any non-public Supabase services/settings/secrets, Supabase Auth/storage resources, or an independently reconstructed replacement infrastructure. Cloudflare R2 bucket retention/lifecycle policies, access recovery, storage encryption setup and independent restoration from disaster are unverified; do not claim verified RTO. Effective logical-snapshot RPO is bounded by time since last successful backup plus execution drift for covered data; a 24-hour recovery target is aspirational, not an SLA. Supabase Free does not include provider-managed automatic backups.

## Realtime / availability / global latency
One Render instance is a single process/node availability dependency. `DNSCluster` is present but query is optional; no Redis/Render Key Value service exists in the inspected workspace. Production currently uses Render Free runtime: provider documentation states that it can spin down after 15 minutes idle (including websocket message idle), cold start ~1 minute, can restart, and loses local filesystem across restarts. Confirm exact per-feature continuity and media/queue behavior after process failure with Team 1/2; no guarantee of zero disruption or seamless failover.
Render web service and Supabase database are both Singapore. That avoids an obvious cross-region app-to-DB hop, but Europe/North America user RTT, packet loss, WS reconnect, and media TURN paths need measured tests. Do not prescribe multi-region before collecting real region measurements.

## Performance and capacity gate
A local `test/load/phase_6f.exs` harness exists and ramps conversation fixtures through 5,10,25,50, but the required realistic user/socket scenarios (20,50,100,200) were **not executed here**. No evidence was collected for end-user concurrency ceilings or global p95 at these levels. Render metrics for 2026-10-06 had empty time series. Required isolated tests: 20, 50, 100 and 200 authenticated/anonymous websocket participants, with mix of queue/pair/chat/end/reconnect; record CPU/RSS, DB pools, 429s, match success, WebSocket disconnects, queue wait, per-route p50/p95/p99 and traffic/outbound usage. Never run load against production without permission.

## Costs (provider listed prices, USD; INR estimates at 96.7571/USD; pre-tax, excluding metered overruns)
| Scenario | Compute assumptions | Monthly USD | Approx INR |
|---|---|---:|---:|
| Current preview resources | Production Render Free + staging Render Free + Supabase Free + R2 inside free tier | 0 | 0 |
| Minimal paid live launch | 1 Render starter 0.5c/512MB ($7) + Supabase Pro ($25), R2 free tier | 32 | 3,096 |
| Minimal live + paid staging | 2 Render starters ($14) + 1 Supabase Pro ($25); isolated staging DB NOT included | 39 | 3,774 |
| Higher headroom illustration | 2 Render 1c/2GB services ($50) + one Supabase Pro ($25), R2 free tier | 75 | 7,257 |
Note: Independent paid staging Supabase project may increase charges (Pro additional project starts ~$10 per month); budget that separately. Provider prices are not measured actual billing, and taxes/currency spread, TURN/AI, bandwidth, domains, alerts are excluded. Higher plans do not establish capacity without tests.

## Observability and incident operations
- Before RC: configure Render HTTP readiness probe to `/health/ready` and prove intentional DB-down behavior. Observe `/health/version` on running service (no private data), and pin release SHA in deploy record.
- Keep aggregate low-cardinality telemetry; preserve ban on message content, tokens, participant identifiers, free-form user text and private payloads. Alert on startup exit, readiness degradation, process memory, high rate of socket disconnect/reconnect, matchmaking no-match/error, database pool saturation, safety/report delivery failures, and backup job failure.
- Severity: SEV1 for unavailable service, safety boundary broken or confirmed data loss; SEV2 for degraded matchmaking/latency or backup freshness beyond policy. Record UTC timestamps, deployed SHA, safe bounded error codes, affected paths (not user content).
- Incident sequence: freeze deploys; confirm current SHA and incident start; check Render events/health and DB availability; compare to last known good; rollback **only** after migration-compatibility review and founder authorization; verify real two-browser match; document recovery and cause.
- Avoid spraying detailed request paths with user IDs into logs; keep operational data content-blind.

## Exact SHA release / rollback runbook (approval gates, no action authorized by this report)
1. Central Command records accepted upstream contracts and selects a clean integrated commit SHA; protect branch and record `git rev-parse HEAD`, clean working tree and `git diff --check`.
2. Check Elixir/OTP images and lockfile; `mix deps.get --only prod`, `mix deps.compile`, `mix compile --warnings-as-errors`, `mix test`, `mix precommit` and `mix hex.audit`; confirm CI on the candidate SHA. Run JS, Python, browser suites; classify pre-existing/introduced failures.
3. Run build and release against pinned runtime. Verify `bin/migrate` idempotently against **isolated staging database**, then test code rollback against migration compatibility.
4. Require successful fresh GitHub R2 backup+restore proof and separately inspect emergency access/retention.
5. Verify stage database isolation before changing stage settings or deploying; deploy exact candidate SHA to stage after founder approval. Prove `/health/live`, `/health/ready`, `/health/version`, HTTPS/WSS, 2-browser matching, reconnect and safety veto.
6. Execute only isolated 20/50/100/200-user load profiles; record real measurements and bottlenecks. Validate observability and alert route with no message contents.
7. Rehearse a reversible staging rollback: capture old release SHA, deploy previous compatible release, confirm DB schema backward compatibility and smoke checks; store RTO and steps.
8. Produce release gate summary; request separate explicit founder approval for paid services, production env changes, production schema migrations and production deploy. No production deployment until these gates are green.
9. Production deployment when explicitly approved: select exact SHA, record old deploy ID, take preflight backup proof, monitor health/telemetry, smoke two-browser matchmaking, and rollback if thresholds breach; never run destructive DB restore on production automatically.

## Launch blockers and owners
**P0** — staging never live; no known safe isolated staging DB. Owner Team 4 + Command.  
**P0** — latest deployment fails at runtime; need captured non-sensitive crash/root-cause and isolated green deploy. Owner Team 4.  
**P0** — no exact candidate SHA has completed full release proof and promotion gate. Owner Command + all teams.  
**P0** — real 20/50/100/200 socket load not proved. Owner Team 4 + Team 1.  
**P1** — Render HTTP readiness checks unset; live ingress/version/WS not verified. Owner Team 4.  
**P1** — Free Render spin-down/restart behavior unsuitable for reliable global always-on experience. Founder decision for paid production service.  
**P1** — independent disaster access, R2 lifecycle/retention and full disaster RTO not verified, despite daily successful backup restore drills. Owner Team 4 + founder.  
**P1** — observability lacks verified live metrics and alert delivery proof. Owner Team 4 + Team 2.  
**P2** — database FK/index advisories and dated `PRODUCTION_OPERATIONS.md` topology need planned review, not blind edits. Owner Team 4 + Team 2.

## Cross-team handoff
- Team 1: supply real reconnect/matchmaking/single-node crash correctness contract and workload profiles; define hard correctness thresholds.
- Team 2: verify logging privacy, RLS intent, backup confidentiality and safe emergency credential recovery.
- Team 3: supply exact browser journeys/responsive smoke suite for staging and post-rollback.
- Team 5 / Central Command: coordinate legal/global operational readiness, approve paid infrastructure and production promotion.
- Follow-on Team 4 must start with stage database isolation, full redacted startup trace for exit code 1, repair on dedicated branch, build/health checks, measured isolated websocket load, and complete stage rehearsal. Do **not** redo documented backup restoration from scratch unless later run fails.

## Verification and limits
Verified: connector snapshots of repo, Render services/deploys/events, Supabase read-only SQL and advisories, GitHub 2026-10-06/07 successful backup jobs plus filtered non-secret proof log, official provider pricing. No runtime source code changed; no Elixir tests, WSS test, production endpoint test, load test or independent DR restore run was possible within the audit environment. Render historical log queries and metrics returned empty. This report documents that missing evidence rather than assuming success.

TEAM 4 STATUS: PARTIAL
FINAL SHA: docs-only audit-branch commit (see GitHub)
PRODUCTION RELEASE STATUS: NO DEPLOYMENT AUTHORIZED; prod last live SHA 6f43cddab8812be9e0baaf80b2a6779410849948
OPEN INFRASTRUCTURE P0/P1 ISSUES: See launch blockers
NEXT TEAM MUST START FROM: staging isolated DB proof + Render nonzeroExit:1 diagnosis, then exact-SHA release, isolated load, rollback/alerts evidence.
