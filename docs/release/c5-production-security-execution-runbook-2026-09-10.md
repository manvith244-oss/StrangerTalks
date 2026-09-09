# C5 Production Security Execution Runbook — OWNER REVIEW ONLY

Status: **NOT AUTHORIZED FOR EXECUTION**

This packet prepares the production Supabase migration/security change. It does not authorize or perform any production mutation.

## Scope

Expected current production migration head before execution:

`20260821191324`

Exact pending migration order:

1. `20260826142000_create_source_rate_limits`
2. `20260826143000_add_participant_credential_version`
3. `20260830044500_create_participant_pairing_reservations`
4. `20260909181500_add_report_media_origin_truth`
5. `20260909182500_enforce_distinct_match_conversation_participants_c3`
6. `20260909183000_enforce_distinct_relationship_participants_c3`
7. `20260909183500_secure_supabase_public_schema_c1`

The last migration enables RLS on protected application tables and revokes API-role table/default privileges. Its repository `down/0` intentionally refuses to reopen access.

## Required inputs

- `DATABASE_URL`: owner/migration-capable production PostgreSQL URL. Never print it.
- `C5_PROD_CA_CERT`: filesystem path to the approved CA bundle used for the production database hostname. Never substitute `sslmode=require`, `verify-ca`, or an unverified connection for `verify-full`.
- `BACKUP_DIR`: encrypted/restricted backup destination with sufficient free space.
- exact approved release SHA/tree.

Do not place credentials in shell history, logs, CI output, issue comments, or this document.

## PRECHECK — READ ONLY

Abort unless all of the following are true:

- the release SHA/tree are the exact Owner-approved canonical `main`;
- no database/deploy operation is already in flight;
- production application health is understood before change;
- production migration head is exactly `20260821191324`;
- the seven versions above are the only expected repository gap;
- every integrity gate below returns `0`.

Read-only SQL:

```sql
select max(version) as migration_head from public.schema_migrations;

select count(*) as self_matches
from public.matches
where participant_a_id = participant_b_id;

select count(*) as self_conversations
from public.conversations
where participant_a_id = participant_b_id;

select count(*) as mismatched_match_conversation_tuples
from public.conversations c
join public.matches m on m.match_id = c.match_id
where c.participant_a_id is distinct from m.participant_a_id
   or c.participant_b_id is distinct from m.participant_b_id;

select count(*) as self_relationships
from public.relationships
where participant_a_id = participant_b_id;
```

**ABORT** on a nonzero integrity count, unexpected migration head, unexpected schema drift, unavailable health signal, or inability to establish verified TLS.

## FRESH VERIFIED BACKUP — IMMEDIATELY BEFORE MUTATION

This backup is a mandatory gate, not optional ceremony.

Use a trusted workstation/runner with the approved CA bundle and PostgreSQL client tools. Set a UTC timestamp without printing secrets:

```bash
set -euo pipefail
umask 077
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$BACKUP_DIR/strangertalks-prod-pre-security-$stamp.dump"
checksum="$backup.sha256"

PGSSLMODE=verify-full \
PGSSLROOTCERT="$C5_PROD_CA_CERT" \
pg_dump "$DATABASE_URL" \
  --format=custom \
  --no-owner \
  --no-acl \
  --file="$backup"

test -s "$backup"
sha256sum "$backup" | tee "$checksum"
sha256sum --check "$checksum"
pg_restore --list "$backup" >/dev/null
```

Record, in the private release record only:

- UTC timestamp;
- backup filename/location identifier;
- backup byte size;
- SHA-256;
- `pg_restore --list` success;
- operator identity and approved release SHA.

Do not publish the backup or checksum path if it reveals private infrastructure.

Immediately after backup verification, rerun the migration-head query and all four integrity gates. **ABORT on any drift.**

## MIGRATION EXECUTION

Use the release's repository-owned migrator from the exact approved image/release; do not paste individual migration SQL manually and do not toggle RLS/grants manually.

Expected invocation shape from the approved release environment:

```bash
bin/migrate
```

The release environment must use the same verified database TLS policy as the approved application candidate.

The migrator must apply the seven versions above in repository order. **ABORT and preserve logs** on any migration exception. Do not force-insert `schema_migrations` rows and do not bypass an integrity exception.

## POST-MIGRATION DATABASE CHECKS — READ ONLY

Migration head:

```sql
select max(version) from public.schema_migrations;
```

Expected: `20260909183500`.

All seven exact versions must be present:

```sql
select version
from public.schema_migrations
where version in (
  20260826142000,
  20260826143000,
  20260830044500,
  20260909181500,
  20260909182500,
  20260909183000,
  20260909183500
)
order by version;
```

RLS state for protected application tables:

```sql
select n.nspname as schema_name, c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
order by c.relname;
```

Expected: RLS enabled on every application table named by `SecureSupabasePublicSchemaC1`; `schema_migrations` is protected by privilege revocation rather than application RLS policy authority.

API-role table authority check:

```sql
select role_name, table_name,
       has_table_privilege(role_name, format('public.%I', table_name), 'SELECT') as can_select,
       has_table_privilege(role_name, format('public.%I', table_name), 'INSERT') as can_insert,
       has_table_privilege(role_name, format('public.%I', table_name), 'UPDATE') as can_update,
       has_table_privilege(role_name, format('public.%I', table_name), 'DELETE') as can_delete,
       has_table_privilege(role_name, format('public.%I', table_name), 'TRUNCATE') as can_truncate,
       has_table_privilege(role_name, format('public.%I', table_name), 'REFERENCES') as can_references,
       has_table_privilege(role_name, format('public.%I', table_name), 'TRIGGER') as can_trigger
from (values ('anon'), ('authenticated'), ('service_role')) r(role_name)
cross join (values
 ('account_sessions'),('account_sync_states'),('analytics_records'),('boundary_blocks'),
 ('composer_grants'),('conversations'),('google_account_links'),('google_oauth_attempts'),
 ('learning_records'),('matches'),('memories'),('message_reactions'),('messages'),
 ('participant_pairing_reservations'),('participants'),('private_accounts'),('queue_states'),
 ('reflections'),('relationship_consents'),('relationship_reconnection_intents'),('relationships'),
 ('report_safety_media'),('reports'),('safety_events'),('safety_reviews'),('source_rate_limits'),
 ('schema_migrations')
) t(table_name)
order by role_name, table_name;
```

Expected for the protected application tables and `schema_migrations`: all listed table privileges are false for the API roles after the security migration. `service_role` retaining the PostgreSQL `BYPASSRLS` role attribute is not itself the vulnerability; repository migration intent is nevertheless to revoke direct table grants from the listed API roles.

Re-run the four participant-integrity queries. Expected: all zero.

Verify intended backfills and constraints using non-secret aggregate/read-only checks appropriate to live rows. Do not dump user content into release logs.

## APPLICATION POSTCHECKS

Before opening traffic/deploy progression, verify using the trusted application owner path:

- database connection establishes with verified TLS;
- application boot succeeds;
- `/health/live` succeeds;
- readiness/dependency health succeeds where available;
- Phoenix owner persistence can read and perform a controlled application-owned transaction in an approved non-user-data health path;
- Matchmaking/Conversation critical read paths do not fail with permission errors;
- no elevated rate of DB authorization/TLS/migration errors appears.

Do not test by granting API roles access again.

## SUPABASE SECURITY ADVISOR

After the migration, run the Supabase Security Advisor read-only check.

Required result: no remaining `rls_disabled_in_public` ERROR for protected application tables and no new security ERROR introduced by this change.

## DEFAULT-PRIVILEGE REGRESSION CHECK

Inspect default ACLs for the table owner/current migration role:

```sql
select pg_get_userbyid(d.defaclrole) as owner,
       n.nspname as schema_name,
       d.defaclobjtype,
       d.defaclacl
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
where n.nspname = 'public'
order by owner, d.defaclobjtype;
```

Confirm future table/sequence creation by the migration owner will not automatically grant the revoked API-role authority.

## ABORT CONDITIONS

Abort before mutation if:

- verified TLS cannot be established;
- fresh backup, checksum verification, or archive listing fails;
- production head is not exactly `20260821191324`;
- any integrity precondition count is nonzero;
- canonical release SHA/tree changed after approval;
- an unexpected migration exists in the gap.

Stop after mutation and enter incident/recovery handling if:

- a migration fails;
- application owner connectivity/persistence breaks;
- critical application health fails;
- RLS/grant state differs from the intended migration result;
- Security Advisor still reports the protected-table exposure;
- unexpected destructive schema/data behavior is observed.

## RECOVERY / FORWARD FIX

`20260909183500_secure_supabase_public_schema_c1` is intentionally irreversible through its Ecto `down/0`. Do **not** treat broad `GRANT` restoration or disabling RLS as the default rollback.

For a correctable post-migration application defect, prefer a reviewed forward fix that preserves the closed security boundary.

For a severe unrecoverable migration incident:

1. stop further writes/rollout under the incident procedure;
2. preserve migration/application/database logs and exact release identity;
3. retain the failed database for diagnosis where feasible;
4. restore the verified pre-migration dump to a fresh isolated recovery database using verified TLS;
5. verify checksum, schema/data counts, participant-integrity queries, and application-owner read capability on the restored target;
6. perform any production cutover only under a separate explicit Owner incident authorization.

Example restore shape for a fresh recovery target, not the live database:

```bash
PGSSLMODE=verify-full \
PGSSLROOTCERT="$C5_PROD_CA_CERT" \
pg_restore \
  --exit-on-error \
  --no-owner \
  --no-acl \
  --dbname="$RECOVERY_DATABASE_URL" \
  "$backup"
```

Never overwrite the live database with an unverified restore.

## OWNER AUTHORIZATION STRING

Execution authority, if granted, should be narrowly worded:

> Authorize execution of the reviewed C5 production backup + seven-migration runbook against the StrangerTalks production Supabase database, only if the production migration head is exactly `20260821191324`, a fresh verified `pg_dump` backup succeeds immediately before mutation over `verify-full` TLS, the backup checksum/archive verification passes, the approved canonical release SHA/tree are unchanged, and all four participant-integrity precondition queries return zero. Abort on any deviation.

No deployment, secret rotation, unrelated schema change, policy redesign, or manual privilege workaround is implied by that authorization.
