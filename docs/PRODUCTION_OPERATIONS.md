# StrangerTalks Production Operations

Status: Team 9 working truth as of 2026-08-24. Update this file when the production topology or release contract changes. Do not treat a historical SHA below as permission to deploy it again.

## Production topology

Current public product path:

```text
Browser
  -> HTTPS / WSS
  -> Render web service: strangertalks-phoenix
  -> Phoenix / Bandit
  -> Render Postgres: strangertalks-db
```

A legacy Render Node service named `StrangerTalks` remains online only as an HTTP redirect bridge to the Phoenix service. It is not an authoritative product engine.

Observed Render resources on 2026-08-24:

- Phoenix service: `srv-da4qm0e417fc73c2ejp0`
- Phoenix URL: `https://strangertalks-phoenix.onrender.com`
- Phoenix branch: `release/prep-2026-08-22`
- Phoenix auto deploy: disabled
- Observed live Phoenix SHA: `1f9888b9518b1a1bf642c3ae84b1c6dd8eea39f8`
- Legacy redirect service: `srv-d8ivl6l8nd3s73e1iccg`
- Legacy redirect SHA: `82ed9df067f2bbf89a65561a5f1916865a539730`
- Postgres: `dpg-da4qk8rtqb8s738kla4g-a`
- Postgres region/version: Singapore / PostgreSQL 17
- Postgres plan: Free
- Observed Free Postgres expiry: `2026-09-21T13:54:43Z`

The Free database is not a durable long-term production plan. Promotion beyond a short controlled preview requires an explicit Command decision on durable database hosting and backup/recovery.

## Release-candidate contract

Production promotion requires all of the following for one exact SHA:

1. Command-approved release SHA.
2. All upstream release-critical Team gates green for that exact integrated candidate.
3. Full maintained Elixir test/precommit proof.
4. Maintained JavaScript regressions green.
5. Required browser/responsive proof green.
6. Security/dependency audit with no unaccepted applicable blocker.
7. Production build and release packaging green.
8. Migration chain green from a clean database.
9. Backup/restore drill green in an isolated database.
10. Clean-tree and `git diff --check` proof.
11. Known limitations explicitly recorded.

Never substitute `latest`, a branch name, or a green Render build for the exact SHA contract.

## Production build

Current Render-native Elixir build command observed on the Phoenix service:

```bash
mix local.hex --force && \
mix local.rebar --force && \
MIX_ENV=prod mix deps.get --only prod && \
MIX_ENV=prod mix deps.compile && \
MIX_ENV=prod mix compile && \
MIX_ENV=prod mix assets.deploy && \
MIX_ENV=prod mix release
```

For deterministic CI/release verification, prefer `mix release --overwrite` after a clean build directory so an existing release artifact cannot produce an interactive overwrite prompt.

Current Render start command:

```bash
_build/prod/rel/strangertalks_new/bin/migrate && \
exec _build/prod/rel/strangertalks_new/bin/strangertalks_new start
```

The migration wrapper uses `set -eu` and then calls `StrangertalksNew.Release.migrate`. Application startup does not proceed if that command fails.

## Environment inventory

Never put secret values in this document, source control, screenshots, logs, or CI output.

| Variable | Required | Secret | Failure behavior / note |
| --- | --- | --- | --- |
| `DATABASE_URL` | Production core | Yes | Runtime raises when missing. |
| `SECRET_KEY_BASE` | Production core | Yes | Runtime raises when missing. |
| `PHX_HOST` | Production core | No | Runtime raises when missing. |
| `PORT` | Host supplied / optional override | No | Defaults to 4000 in app; Render normally supplies 10000. |
| `POOL_SIZE` | Optional | No | Defaults to 10. |
| `LOG_LEVEL` | Optional | No | Defaults to `info`; unsupported value raises. |
| `ECTO_IPV6` | Optional | No | Enables IPv6 socket option when true/1. |
| `DNS_CLUSTER_QUERY` | Optional for single node | No | Leave unset unless clustering is intentionally configured. |
| `GOOGLE_CONTINUITY_ENABLED` | Optional feature flag | No | Defaults false. |
| `GOOGLE_OAUTH_CLIENT_ID` | Required only when Google continuity is enabled | No | Missing while enabled raises. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Required only when Google continuity is enabled | Yes | Missing while enabled raises. |
| `GOOGLE_OAUTH_REDIRECT_URI` | Required only when Google continuity is enabled | No | Missing while enabled raises. |
| `GOOGLE_SUBJECT_HMAC_KEY` | Required only when Google continuity is enabled | Yes | Must decode to exactly 32 bytes. |
| `GOOGLE_REFRESH_TOKEN_ENCRYPTION_KEY` | Required only when Google continuity is enabled | Yes | Must decode to exactly 32 bytes. |
| `COMPANION_ENABLED` | Optional feature flag | No | Keep disabled unless approved/configured. |
| `AGENT_SYSTEMS_ENABLED` | Optional feature flag | No | Keep disabled unless approved/configured. |
| `AGENT_SYSTEMS_PROVIDER_PROBE` | Release verification only | No | Disabled by default; do not leave enabled casually. |
| `OPENAI_API_KEY` | Required only for enabled provider-backed Agent functionality | Yes | Never log the value. |

Media/TURN variables must be re-inventoried from the final approved Team 6 head before production promotion. Do not invent or retain historical TURN settings.

Render automatically exposes `RENDER_GIT_COMMIT`; deployment metadata can therefore prove the exact running commit without introducing a custom public version endpoint.

## Health

The application exposes:

- `/health/live`: process liveness.
- `/health/ready`: readiness backed by `SELECT 1` through the application Repo.

The Render service was observed with no HTTP `healthCheckPath` configured, meaning Render currently falls back to a TCP-level probe. Before final promotion, configure the web-service HTTP health check to `/health/ready` and verify that DB unavailability produces an unhealthy deployment without causing an uncontrolled restart loop.

## HTTPS, origin and realtime

Production config forces SSL behind the proxy and restricts Phoenix origin checking to `https://$PHX_HOST`. The final candidate still requires real-ingress proof for:

- HTTPS certificate and redirect behavior;
- `wss://` socket connection;
- idle socket behavior;
- reconnect after network loss;
- reconnect/recovery after a service restart or deploy.

A root HTTP 200 is not realtime proof.

## Database and migrations

The release startup runs migrations before the application starts. Before each production promotion:

1. Run the full migration chain against a clean isolated database.
2. Run the same migration command again and prove it is idempotent (`Migrations already up`).
3. Inspect schema compatibility with the previous deploy before relying on code rollback.
4. Never run `ecto.drop`, `ecto.reset`, destructive seeds, or test database commands against production.

## Backup

Free Render Postgres does not provide managed backup/recovery. Team 9 therefore includes `ops/postgres_backup.sh` for a logical custom-format `pg_dump` without printing credentials.

Example from a trusted operator environment with PostgreSQL client tools installed:

```bash
DATABASE_URL='postgresql://...' \
  bash ops/postgres_backup.sh /secure/path/strangertalks.dump
```

The backup file contains user data. Store it in an access-controlled, encrypted location outside the ephemeral Render web-service filesystem. Do not upload production dumps to GitHub Actions artifacts or source control merely for convenience.

## Restore

Restore is deliberately guarded and destructive to the chosen target:

```bash
RESTORE_DATABASE_URL='postgresql://...' \
CONFIRM_RESTORE=RESTORE_STRANGERTALKS \
  bash ops/postgres_restore.sh /secure/path/strangertalks.dump
```

Run drills only against an isolated target database unless an actual incident has been declared.

## Rollback

Before deployment, record:

```text
new SHA: <N>
previous known-good SHA: <N-1>
migrations introduced by N: <list>
old-code/new-schema compatibility: <proven yes/no>
```

Rollback sequence:

1. Stop promotion if any required smoke gate is red.
2. Determine whether schema changes allow the previous code to run safely.
3. Redeploy the exact previous known-good SHA using the provider rollback/redeploy mechanism.
4. Verify migration/schema state; Git rollback does not undo a database migration.
5. Verify `/health/ready`, assets, HTTPS, WebSocket connection, two-browser Conversation, Block/Report, and reconnect.
6. Preserve logs and the failed deployment identifier for diagnosis.

Immediate rollback triggers include participant bootstrap failure, matchmaking failure, Conversation join/send failure, Block bypass, database corruption, secret exposure, or persistent crash loop.

## Incident quick path

- **Site unavailable:** inspect Render deploy/service state, application logs, `/health/live`, then `/health/ready`.
- **Database unavailable:** prevent destructive retries, verify database state/connectivity, keep readiness red, restore only from a proven backup when required.
- **Deployment failed:** do not retry a different SHA blindly; inspect the failed exact deploy and rollback if the previous schema/code pairing remains safe.
- **WebSocket broken:** verify HTTPS first, then origin/host, `/socket`, proxy behavior, and browser reconnect evidence.
- **High error rate:** correlate safe request IDs/metadata; never enable raw Conversation-content logging.
- **Security incident:** stop exposure, rotate/revoke affected credentials, preserve evidence without reproducing secrets, and do not treat deleting a leaked file as remediation.
- **Bad migration:** stop incompatible application promotion; use the documented schema-compatible rollback/recovery path.
- **TURN/OAuth outage:** keep optional features truthfully unavailable without breaking anonymous core chat.

## Known infrastructure limitations on 2026-08-24

- Single free Phoenix instance; no high availability.
- Free web service can spin down after inactivity and cold-start on the next request/connection.
- Free web-service filesystem is ephemeral.
- Free Postgres expires after 30 days and has no managed backups.
- Current observed service memory ceiling is about 512 MiB and CPU limit about 0.15 CPU; measured idle memory was roughly 184–191 MiB, but no production-scale capacity claim has been proven.
- The existing live base has known dependency advisories; upstream Team 4 carries the narrow Bandit/Postgrex upgrades and must clear its gate before integration.
- Render currently builds with provider-default BEAM versions while the main GitHub gate pins specific versions; final release should make the tested/deployed runtime versions intentionally consistent.
- The legacy Node redirect service still has auto-deploy enabled on `master`; it must remain a redirect-only compatibility bridge or be retired deliberately.

These limitations are launch inputs, not things to hide. The final Command decision determines which are accepted for V1 versus release blockers.
