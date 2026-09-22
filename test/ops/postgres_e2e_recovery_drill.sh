#!/usr/bin/env bash
set -euo pipefail

# test/ops/postgres_e2e_recovery_drill.sh
# Phase 6: End-to-End Disposable Recovery Drill for WT-04 Team 5-B

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
export PATH="/c/Program Files/PostgreSQL/17/bin:$PATH"

TEST_PG_PORT=${TEST_PG_PORT:-54329}
TEST_RUNNER_TMP=${RUNNER_TEMP:-${TEMP:-/tmp}}
TEST_RUNNER_TMP=$(echo "$TEST_RUNNER_TMP" | tr '\\' '/')
TEST_DATA_DIR="$TEST_RUNNER_TMP/pg17_wt04_drill_cluster_$$"
SERVER_STARTED_BY_TEST=0

cleanup() {
  if (( SERVER_STARTED_BY_TEST == 1 )); then
    echo "Stopping drill PostgreSQL 17 cluster..."
    pg_ctl -D "$TEST_DATA_DIR" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$TEST_DATA_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ensure_cluster() {
  if psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    echo "Using existing PostgreSQL cluster on port $TEST_PG_PORT"
  else
    echo "Starting disposable PostgreSQL 17 cluster on port $TEST_PG_PORT in $TEST_DATA_DIR..."
    rm -rf "$TEST_DATA_DIR"
    initdb -D "$TEST_DATA_DIR" -U postgres -A trust --locale=C >/dev/null 2>&1
    pg_ctl -D "$TEST_DATA_DIR" -l "$TEST_DATA_DIR/server.log" -o "-p $TEST_PG_PORT" start >/dev/null 2>&1
    SERVER_STARTED_BY_TEST=1
    sleep 2
    psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1
  fi
}

query_val() {
  local db=$1
  local sql=$2
  psql -At -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "$db" -c "$sql" | tr -d '\r'
}

run_psql() {
  local db=$1
  local sql=$2
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "$db" -c "$sql" >/dev/null
}

ensure_cluster

SOURCE_DB="wt04_drill_src"
TARGET_DB="wt04_drill_tgt"
DUMP_FILE="$TEST_RUNNER_TMP/wt04_e2e_drill_$$.dump"

echo "=== STEP 1: Creating production-like source database ($SOURCE_DB) ==="
run_psql "postgres" "DROP DATABASE IF EXISTS $SOURCE_DB;"
run_psql "postgres" "CREATE DATABASE $SOURCE_DB OWNER postgres;"

# Platform roles
psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "$SOURCE_DB" <<'SQL' >/dev/null 2>&1
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_database_owner') THEN
    CREATE ROLE pg_database_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;
ALTER SCHEMA public OWNER TO pg_database_owner;
SQL

# Create 26 pre-hangout tables + schema_migrations
PRE_HANGOUTS_26_TABLES=(
  account_sessions account_sync_states analytics_records boundary_blocks composer_grants
  conversations google_account_links google_oauth_attempts learning_records matches
  memories message_reactions messages participant_pairing_reservations participants
  private_accounts queue_states reflections relationship_consents
  relationship_reconnection_intents relationships report_safety_media reports
  safety_events safety_reviews source_rate_limits
)

create_tables_sql="CREATE TABLE public.schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp without time zone);"
for tbl in "${PRE_HANGOUTS_26_TABLES[@]}"; do
  create_tables_sql+="CREATE TABLE public.$tbl (id bigint PRIMARY KEY, payload text, inserted_at timestamp without time zone DEFAULT now());"
  create_tables_sql+="ALTER TABLE public.$tbl OWNER TO postgres;"
done
create_tables_sql+="ALTER TABLE public.schema_migrations OWNER TO postgres;"
create_tables_sql+="INSERT INTO public.schema_migrations (version, inserted_at) VALUES (20260909183500, now());"
run_psql "$SOURCE_DB" "$create_tables_sql"

echo "=== STEP 2: Seeding representative data ==="
run_psql "$SOURCE_DB" "INSERT INTO public.participants (id, payload) VALUES (1, 'p1'), (2, 'p2'), (3, 'p3');"
run_psql "$SOURCE_DB" "INSERT INTO public.conversations (id, payload) VALUES (101, 'conv_alpha'), (102, 'conv_beta');"
run_psql "$SOURCE_DB" "INSERT INTO public.messages (id, payload) VALUES (1001, 'hello world'), (1002, 'secret message');"
run_psql "$SOURCE_DB" "INSERT INTO public.reports (id, payload) VALUES (501, 'flagged incident');"

src_p_count=$(query_val "$SOURCE_DB" "SELECT count(*) FROM public.participants;")
src_m_count=$(query_val "$SOURCE_DB" "SELECT count(*) FROM public.messages;")
src_r_count=$(query_val "$SOURCE_DB" "SELECT count(*) FROM public.reports;")
echo "seeded_participants=$src_p_count seeded_messages=$src_m_count seeded_reports=$src_r_count"

echo "=== STEP 3: Executing canonical backup (ops/postgres_backup.sh) ==="
export DATABASE_URL="postgresql://postgres@127.0.0.1:$TEST_PG_PORT/$SOURCE_DB"
bash "$REPO_ROOT/ops/postgres_backup.sh" "$DUMP_FILE"
test -s "$DUMP_FILE"
echo "backup_verified_nonempty=true"

echo "=== STEP 4: Executing canonical restore (ops/postgres_restore.sh) ==="
run_psql "postgres" "DROP DATABASE IF EXISTS $TARGET_DB;"
run_psql "postgres" "CREATE DATABASE $TARGET_DB OWNER postgres;"

# Target platform roles
psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "$TARGET_DB" <<'SQL' >/dev/null 2>&1
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_database_owner') THEN
    CREATE ROLE pg_database_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;
ALTER SCHEMA public OWNER TO pg_database_owner;
SQL

export RESTORE_DATABASE_URL="postgresql://postgres@127.0.0.1:$TEST_PG_PORT/$TARGET_DB"
export CONFIRM_RESTORE="RESTORE_STRANGERTALKS"
bash "$REPO_ROOT/ops/postgres_restore.sh" "$DUMP_FILE"
echo "restore_completed=true"

echo "=== STEP 5: Capturing PRE-REHYDRATION authority state ==="
pre_rls=$(query_val "$TARGET_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = true;")
echo "pre_rehydration_rls_enabled_tables=$pre_rls (expected 0 after --no-acl)"

# Snapshot initial provider default ACLs
provider_defaults_before=$(query_val "$TARGET_DB" "SELECT COALESCE(array_to_string(d.defaclacl, ','), 'none') FROM pg_default_acl d JOIN pg_roles r ON r.oid = d.defaclrole WHERE r.rolname IN ('anon','authenticated','service_role','authenticator') ORDER BY r.rolname;")

# Prove 1: Non-postgres execution identity hard-rejected
set +e
wrong_exec_out=$(CONFIRM_AUTHORITY_REHYDRATION="REHYDRATE_STRANGERTALKS_AUTHORITY" DATABASE_URL="postgresql://authenticator@127.0.0.1:$TEST_PG_PORT/$TARGET_DB" bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "pre-migration" 2>&1)
wrong_exec_rc=$?
set -e
test "$wrong_exec_rc" -ne 0
echo "drill_non_postgres_execution_hard_rejected=true"

# Prove 2: Missing schema_migrations ledger hard-rejected
run_psql "$TARGET_DB" "ALTER TABLE public.schema_migrations RENAME TO schema_migrations_hidden;"
set +e
missing_ledger_out=$(CONFIRM_AUTHORITY_REHYDRATION="REHYDRATE_STRANGERTALKS_AUTHORITY" DATABASE_URL="$RESTORE_DATABASE_URL" bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "pre-migration" 2>&1)
missing_ledger_rc=$?
set -e
test "$missing_ledger_rc" -ne 0
run_psql "$TARGET_DB" "ALTER TABLE public.schema_migrations_hidden RENAME TO schema_migrations;"
echo "drill_missing_migration_ledger_hard_rejected=true"

# Prove 3: Unknown migration ledger version hard-rejected
run_psql "$TARGET_DB" "INSERT INTO public.schema_migrations (version, inserted_at) VALUES (19990101000000, now());"
set +e
unknown_ver_out=$(CONFIRM_AUTHORITY_REHYDRATION="REHYDRATE_STRANGERTALKS_AUTHORITY" DATABASE_URL="$RESTORE_DATABASE_URL" bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "pre-migration" 2>&1)
unknown_ver_rc=$?
set -e
test "$unknown_ver_rc" -ne 0
run_psql "$TARGET_DB" "DELETE FROM public.schema_migrations WHERE version = 19990101000000;"
echo "drill_unknown_ledger_version_hard_rejected=true"

# Prove 5: Missing historically-required object fails in pre-migration
run_psql "$TARGET_DB" "DROP TABLE public.reports;"
set +e
missing_tbl_out=$(CONFIRM_AUTHORITY_REHYDRATION="REHYDRATE_STRANGERTALKS_AUTHORITY" DATABASE_URL="$RESTORE_DATABASE_URL" bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "pre-migration" 2>&1)
missing_tbl_rc=$?
set -e
test "$missing_tbl_rc" -ne 0
run_psql "$TARGET_DB" "CREATE TABLE public.reports (id bigint PRIMARY KEY, payload text, inserted_at timestamp without time zone DEFAULT now()); ALTER TABLE public.reports OWNER TO postgres; INSERT INTO public.reports (id, payload) VALUES (501, 'flagged incident');"
echo "drill_missing_historically_required_object_fails=true"

echo "=== STEP 6: Running Team 5-B command in pre-migration mode ==="
# Prove 4 & 6: Generation-aware pre-manifest derived from head; genuinely future objects legitimately absent
export DATABASE_URL="$RESTORE_DATABASE_URL"
export CONFIRM_AUTHORITY_REHYDRATION="REHYDRATE_STRANGERTALKS_AUTHORITY"
bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "pre-migration"
pre_rls_count=$(query_val "$TARGET_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname != 'schema_migrations' AND c.relrowsecurity = true AND c.relforcerowsecurity = false;")
test "$pre_rls_count" -eq 26
# Verify future objects (hangout tables) are absent
future_tbl_count=$(query_val "$TARGET_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname IN ('hangout_rooms','hangout_memberships','hangout_messages','hangout_reports');")
test "$future_tbl_count" -eq 0
# Verify ledger count unchanged by pre-migration rehydration
pre_mig_ledger_count=$(query_val "$TARGET_DB" "SELECT count(*) FROM public.schema_migrations;")
test "$pre_mig_ledger_count" -eq 1
echo "pre_migration_rehydration_success=true"

echo "=== STEP 7: Applying genuine forward migrations ==="
# Forward migrations add hangout tables and advance schema_migrations head
forward_sql="
CREATE TABLE public.hangout_memberships (id bigint PRIMARY KEY, payload text, inserted_at timestamp without time zone DEFAULT now());
CREATE TABLE public.hangout_messages (id bigint PRIMARY KEY, payload text, inserted_at timestamp without time zone DEFAULT now());
CREATE TABLE public.hangout_reports (id bigint PRIMARY KEY, payload text, inserted_at timestamp without time zone DEFAULT now());
CREATE TABLE public.hangout_rooms (id bigint PRIMARY KEY, payload text, inserted_at timestamp without time zone DEFAULT now());
ALTER TABLE public.hangout_memberships OWNER TO postgres;
ALTER TABLE public.hangout_messages OWNER TO postgres;
ALTER TABLE public.hangout_reports OWNER TO postgres;
ALTER TABLE public.hangout_rooms OWNER TO postgres;
INSERT INTO public.schema_migrations (version, inserted_at) VALUES (20260910002000, now());
INSERT INTO public.schema_migrations (version, inserted_at) VALUES (20260914175320, now());
"
run_psql "$TARGET_DB" "$forward_sql"
echo "forward_migrations_applied=true"

echo "=== STEP 8: Running Team 5-B command in post-migration mode ==="
bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "post-migration"
echo "post_migration_rehydration_success=true"

echo "=== STEP 9: Running post-migration mode again (Idempotency) ==="
snap_before=$(query_val "$TARGET_DB" "SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity, array_to_string(c.relacl, ',') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY c.relname;")
bash "$REPO_ROOT/ops/postgres_rehydrate_authority.sh" "post-migration"
snap_after=$(query_val "$TARGET_DB" "SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity, array_to_string(c.relacl, ',') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY c.relname;")
if [[ "$snap_before" != "$snap_after" ]]; then
  echo "ERROR: idempotency check failed: catalog changed on second post-migration run" >&2
  exit 1
fi
echo "idempotency_verified=true"

echo "=== STEP 10: Capturing final authority state ==="
final_rls=$(query_val "$TARGET_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname != 'schema_migrations' AND c.relrowsecurity = true AND c.relforcerowsecurity = false;")
test "$final_rls" -eq 30
echo "final_rls_verified_30_tables=true"

echo "=== STEP 11 & 12: Future table, sequence, and function probes ==="
run_psql "$TARGET_DB" "CREATE TABLE public.drill_future_table (id bigint, note text);"
run_psql "$TARGET_DB" "CREATE SEQUENCE public.drill_future_seq;"
run_psql "$TARGET_DB" "CREATE FUNCTION public.drill_future_fn() RETURNS int LANGUAGE sql AS 'SELECT 99';"

# Verify API roles & PUBLIC lack all privileges
table_leaks=$(query_val "$TARGET_DB" "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
  SELECT count(*) FROM api a CROSS JOIN (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'),('MAINTAIN')) p(priv)
  WHERE has_table_privilege(a.role_name, 'public.drill_future_table', p.priv);")
seq_leaks=$(query_val "$TARGET_DB" "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
  SELECT count(*) FROM api a CROSS JOIN (VALUES ('USAGE'),('SELECT'),('UPDATE')) p(priv)
  WHERE has_sequence_privilege(a.role_name, 'public.drill_future_seq', p.priv);")
fn_leaks=$(query_val "$TARGET_DB" "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
  SELECT count(*) FROM roles r WHERE has_function_privilege(r.role_name, 'public.drill_future_fn()', 'EXECUTE');")
public_fn_leaks=$(query_val "$TARGET_DB" "SELECT count(*) FROM pg_proc p, LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
  WHERE p.oid = 'public.drill_future_fn()'::regprocedure AND a.grantee = 0 AND a.privilege_type = 'EXECUTE';")

test "$table_leaks" -eq 0
test "$seq_leaks" -eq 0
test "$fn_leaks" -eq 0
test "$public_fn_leaks" -eq 0
echo "future_probes_closed=true"

echo "=== STEP 13: App owner functionality check ==="
run_psql "$TARGET_DB" "INSERT INTO public.drill_future_table (id, note) VALUES (42, 'owner write succeeds');"
drill_owner_read=$(query_val "$TARGET_DB" "SELECT note FROM public.drill_future_table WHERE id = 42;")
test "$drill_owner_read" = "owner write succeeds"
drill_seq_next=$(query_val "$TARGET_DB" "SELECT nextval('public.drill_future_seq');")
test "$drill_seq_next" = "1"
drill_fn_res=$(query_val "$TARGET_DB" "SELECT public.drill_future_fn();")
test "$drill_fn_res" = "99"
echo "app_owner_functionality_verified=true"

# Clean up future probes
run_psql "$TARGET_DB" "DROP FUNCTION public.drill_future_fn(); DROP SEQUENCE public.drill_future_seq; DROP TABLE public.drill_future_table;"

echo "=== STEP 14: Verifying data preservation ==="
tgt_p_count=$(query_val "$TARGET_DB" "SELECT count(*) FROM public.participants;")
tgt_m_count=$(query_val "$TARGET_DB" "SELECT count(*) FROM public.messages;")
tgt_r_count=$(query_val "$TARGET_DB" "SELECT count(*) FROM public.reports;")
test "$tgt_p_count" -eq "$src_p_count"
test "$tgt_m_count" -eq "$src_m_count"
test "$tgt_r_count" -eq "$src_r_count"
echo "data_preservation_verified=true"

echo "=== STEP 15: Migration ledger truth ==="
ledger_versions=$(query_val "$TARGET_DB" "SELECT count(*) FROM public.schema_migrations;")
test "$ledger_versions" -eq 3
echo "migration_ledger_truth_verified=true"

echo "=== STEP 16: Provider object safety ==="
# Verify platform roles remain intact
test "$(query_val "$TARGET_DB" "SELECT count(*) FROM pg_roles WHERE rolname IN ('postgres','anon','authenticated','service_role','authenticator','pg_database_owner');")" -eq 6
echo "provider_roles_intact=true"
provider_defaults_after=$(query_val "$TARGET_DB" "SELECT COALESCE(array_to_string(d.defaclacl, ','), 'none') FROM pg_default_acl d JOIN pg_roles r ON r.oid = d.defaclrole WHERE r.rolname IN ('anon','authenticated','service_role','authenticator') ORDER BY r.rolname;")
test "$provider_defaults_before" = "$provider_defaults_after"
echo "provider_defaults_unmodified=true"

rm -f "$DUMP_FILE"
echo "DRILL_COMPLETED_SUCCESSFULLY=true"
exit 0
