#!/usr/bin/env bash
set -euo pipefail

# Test Harness for ops/postgres_rehydrate_authority.sh
# Covers Tests A through P for WT-04 Team 5-B Authority Rehydration

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
REHYDRATE_CMD="$REPO_ROOT/ops/postgres_rehydrate_authority.sh"

export PATH="/c/Program Files/PostgreSQL/17/bin:$PATH"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql (PostgreSQL 17) is required" >&2
  exit 127
fi

TEST_PG_PORT=${TEST_PG_PORT:-54329}
TEST_RUNNER_TMP=${RUNNER_TEMP:-${TEMP:-/tmp}}
TEST_RUNNER_TMP=$(echo "$TEST_RUNNER_TMP" | tr '\\' '/')
TEST_DATA_DIR="$TEST_RUNNER_TMP/pg17_wt04_test_cluster_$$"
SERVER_STARTED_BY_TEST=0

cleanup() {
  if (( SERVER_STARTED_BY_TEST == 1 )); then
    echo "Stopping test PostgreSQL 17 cluster..."
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

CANONICAL_30_TABLES=(
  account_sessions
  account_sync_states
  analytics_records
  boundary_blocks
  composer_grants
  conversations
  google_account_links
  google_oauth_attempts
  hangout_memberships
  hangout_messages
  hangout_reports
  hangout_rooms
  learning_records
  matches
  memories
  message_reactions
  messages
  participant_pairing_reservations
  participants
  private_accounts
  queue_states
  reflections
  relationship_consents
  relationship_reconnection_intents
  relationships
  report_safety_media
  reports
  safety_events
  safety_reviews
  source_rate_limits
)

PRE_HANGOUTS_26_TABLES=(
  account_sessions
  account_sync_states
  analytics_records
  boundary_blocks
  composer_grants
  conversations
  google_account_links
  google_oauth_attempts
  learning_records
  matches
  memories
  message_reactions
  messages
  participant_pairing_reservations
  participants
  private_accounts
  queue_states
  reflections
  relationship_consents
  relationship_reconnection_intents
  relationships
  report_safety_media
  reports
  safety_events
  safety_reviews
  source_rate_limits
)

setup_db() {
  local db=$1
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d postgres -c "DROP DATABASE IF EXISTS $db;" >/dev/null 2>&1
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d postgres -c "CREATE DATABASE $db OWNER postgres;" >/dev/null 2>&1

  # Create platform roles if missing
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "$db" <<'SQL' >/dev/null 2>&1
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
}

create_tables() {
  local db=$1
  local mode=${2:-30}
  local table_list=()
  if [[ "$mode" == "26" ]]; then
    table_list=("${PRE_HANGOUTS_26_TABLES[@]}")
  else
    table_list=("${CANONICAL_30_TABLES[@]}")
  fi

  local sql="CREATE TABLE IF NOT EXISTS public.schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp without time zone);"
  for tbl in "${table_list[@]}"; do
    sql+="CREATE TABLE IF NOT EXISTS public.$tbl (id bigint);"
    sql+="ALTER TABLE public.$tbl OWNER TO postgres;"
  done
  sql+="ALTER TABLE public.schema_migrations OWNER TO postgres;"

  if [[ "$mode" == "26" ]]; then
    sql+="INSERT INTO public.schema_migrations (version, inserted_at) VALUES (20260909183500, now()) ON CONFLICT DO NOTHING;"
  else
    sql+="INSERT INTO public.schema_migrations (version, inserted_at) VALUES (20260914175320, now()) ON CONFLICT DO NOTHING;"
  fi

  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "$db" -c "$sql" >/dev/null 2>&1
}

run_rehydration() {
  local db=$1
  local mode=${2:-post-migration}
  local conf=${3:-REHYDRATE_STRANGERTALKS_AUTHORITY}
  local url="postgresql://postgres@127.0.0.1:$TEST_PG_PORT/$db"
  if [[ ! -f "$REHYDRATE_CMD" ]]; then
    echo "rehydration script missing: $REHYDRATE_CMD" >&2
    return 127
  fi
  CONFIRM_AUTHORITY_REHYDRATION="$conf" DATABASE_URL="$url" bash "$REHYDRATE_CMD" "$mode"
}

# --- TEST SUITE ---

test_a_happy_path() {
  echo "Running TEST A — HAPPY-PATH REHYDRATION..."
  setup_db "wt04_test_a"
  create_tables "wt04_test_a" 30
  if ! run_rehydration "wt04_test_a" "post-migration"; then
    echo "TEST A FAILED: command failed or missing" >&2
    return 1
  fi

  # Verify 30 tables have RLS enabled and FORCE is false
  local rls_count
  rls_count=$(query_val "wt04_test_a" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relname != 'schema_migrations' AND c.relrowsecurity = true AND c.relforcerowsecurity = false;")
  if [[ "$rls_count" -ne 30 ]]; then
    echo "TEST A FAILED: expected 30 tables with RLS enabled and FORCE false, got $rls_count" >&2
    return 1
  fi

  # Verify API roles have 0 privileges on application tables
  local api_priv_count
  api_priv_count=$(query_val "wt04_test_a" \
    "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')),
          pub_tables AS (SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p'))
     SELECT count(*) FROM api a CROSS JOIN pub_tables t CROSS JOIN (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) p(priv)
     WHERE has_table_privilege(a.role_name, t.oid, p.priv);")
  if [[ "$api_priv_count" -ne 0 ]]; then
    echo "TEST A FAILED: API roles still have $api_priv_count table privileges" >&2
    return 1
  fi

  # Verify public schema closure for API roles and PUBLIC
  local schema_priv_count public_schema_priv
  schema_priv_count=$(query_val "wt04_test_a" \
    "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
     SELECT count(*) FROM api a CROSS JOIN (VALUES ('USAGE'),('CREATE')) p(priv)
     WHERE has_schema_privilege(a.role_name, 'public', p.priv);")
  public_schema_priv=$(query_val "wt04_test_a" \
    "SELECT count(*) FROM pg_namespace n, LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type IN ('USAGE', 'CREATE');")
  if [[ "$schema_priv_count" -ne 0 || "$public_schema_priv" -ne 0 ]]; then
    echo "TEST A FAILED: public schema privilege closure violated (api=$schema_priv_count, public=$public_schema_priv)" >&2
    return 1
  fi

  echo "TEST A PASSED"
  return 0
}

test_b_idempotency() {
  echo "Running TEST B — SECOND RUN IDEMPOTENCY..."
  setup_db "wt04_test_b"
  create_tables "wt04_test_b" 30
  if ! run_rehydration "wt04_test_b" "post-migration"; then
    echo "TEST B FAILED: first run failed or missing" >&2
    return 1
  fi

  local snap1
  snap1=$(query_val "wt04_test_b" \
    "SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity, array_to_string(c.relacl, ',') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY c.relname;")

  # Second run
  if ! run_rehydration "wt04_test_b" "post-migration"; then
    echo "TEST B FAILED: second run failed" >&2
    return 1
  fi

  local snap2
  snap2=$(query_val "wt04_test_b" \
    "SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity, array_to_string(c.relacl, ',') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY c.relname;")

  if [[ "$snap1" != "$snap2" ]]; then
    echo "TEST B FAILED: catalog state changed after second rehydration run" >&2
    return 1
  fi

  echo "TEST B PASSED"
  return 0
}

test_c_partial_replay() {
  echo "Running TEST C — PARTIAL PREVIOUS REPLAY..."
  setup_db "wt04_test_c"
  create_tables "wt04_test_c" 30
  # Partially configure: enable RLS on 1 table only, revoke anon from schema only
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_c" -c \
    "ALTER TABLE public.account_sessions ENABLE ROW LEVEL SECURITY; REVOKE ALL ON SCHEMA public FROM anon;" >/dev/null 2>&1

  if ! run_rehydration "wt04_test_c" "post-migration"; then
    echo "TEST C FAILED: command failed or missing" >&2
    return 1
  fi

  # Must converge fully to all 30 RLS enabled
  local rls_count
  rls_count=$(query_val "wt04_test_c" \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relname != 'schema_migrations' AND c.relrowsecurity = true;")
  if [[ "$rls_count" -ne 30 ]]; then
    echo "TEST C FAILED: partial replay did not converge all 30 tables to RLS enabled" >&2
    return 1
  fi

  echo "TEST C PASSED"
  return 0
}

test_d_unknown_public_object() {
  echo "Running TEST D — UNKNOWN PUBLIC APPLICATION OBJECT..."
  setup_db "wt04_test_d"
  create_tables "wt04_test_d" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_d" -c \
    "CREATE TABLE public.unexpected_custom_table (id bigint); ALTER TABLE public.unexpected_custom_table DISABLE ROW LEVEL SECURITY;" >/dev/null 2>&1

  set +e
  run_rehydration "wt04_test_d" "post-migration"
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 127 ]]; then
    echo "TEST D FAILED: command missing" >&2
    return 1
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo "TEST D FAILED: expected rehydration to fail on unexpected table, but it exited 0" >&2
    return 1
  fi

  # Verify unexpected object was NOT mutated
  local rls_status
  rls_status=$(query_val "wt04_test_d" \
    "SELECT relrowsecurity FROM pg_class WHERE relname = 'unexpected_custom_table';")
  if [[ "$rls_status" != "f" ]]; then
    echo "TEST D FAILED: unexpected object was mutated by rehydration" >&2
    return 1
  fi

  echo "TEST D PASSED"
  return 0
}

test_e_missing_required_table() {
  echo "Running TEST E — MISSING REQUIRED TABLE..."
  setup_db "wt04_test_e"
  create_tables "wt04_test_e" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_e" -c "DROP TABLE public.reports;" >/dev/null 2>&1

  set +e
  run_rehydration "wt04_test_e" "post-migration"
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 127 ]]; then
    echo "TEST E FAILED: command missing" >&2
    return 1
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo "TEST E FAILED: expected post-migration to fail on missing table 'reports', but it succeeded" >&2
    return 1
  fi

  # Pre-migration mode with 26 tables (pre-hangouts) must succeed
  setup_db "wt04_test_e_pre"
  create_tables "wt04_test_e_pre" 26
  if ! run_rehydration "wt04_test_e_pre" "pre-migration"; then
    echo "TEST E FAILED: pre-migration mode failed on 26 pre-hangouts tables" >&2
    return 1
  fi

  echo "TEST E PASSED"
  return 0
}

test_f_wrong_table_owner() {
  echo "Running TEST F — WRONG TABLE OWNER..."
  setup_db "wt04_test_f"
  create_tables "wt04_test_f" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_f" -c \
    "ALTER TABLE public.reports OWNER TO anon;" >/dev/null 2>&1

  if ! run_rehydration "wt04_test_f" "post-migration"; then
    echo "TEST F FAILED: command failed or missing" >&2
    return 1
  fi

  local final_owner
  final_owner=$(query_val "wt04_test_f" \
    "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname = 'reports';")
  if [[ "$final_owner" != "postgres" ]]; then
    echo "TEST F FAILED: table 'reports' owner was not normalized to postgres (got $final_owner)" >&2
    return 1
  fi

  echo "TEST F PASSED"
  return 0
}

test_g_forbidden_api_privilege() {
  echo "Running TEST G — FORBIDDEN API PRIVILEGE..."
  setup_db "wt04_test_g"
  create_tables "wt04_test_g" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_g" -c \
    "GRANT SELECT, INSERT ON public.participants TO anon; GRANT ALL ON public.messages TO authenticated;" >/dev/null 2>&1

  if ! run_rehydration "wt04_test_g" "post-migration"; then
    echo "TEST G FAILED: command failed or missing" >&2
    return 1
  fi

  local priv_count
  priv_count=$(query_val "wt04_test_g" \
    "SELECT count(*) FROM (VALUES ('anon','participants','SELECT'),('anon','participants','INSERT'),('authenticated','messages','SELECT')) v(r,t,p)
     WHERE has_table_privilege(v.r, 'public.' || v.t, v.p);")
  if [[ "$priv_count" -ne 0 ]]; then
    echo "TEST G FAILED: API privileges were not revoked" >&2
    return 1
  fi

  echo "TEST G PASSED"
  return 0
}

test_h_service_role_access() {
  echo "Running TEST H — SERVICE ROLE ACCESS..."
  setup_db "wt04_test_h"
  create_tables "wt04_test_h" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_h" -c \
    "GRANT ALL ON public.participants TO service_role; GRANT USAGE, CREATE ON SCHEMA public TO service_role;" >/dev/null 2>&1

  if ! run_rehydration "wt04_test_h" "post-migration"; then
    echo "TEST H FAILED: command failed or missing" >&2
    return 1
  fi

  local sr_table_priv sr_schema_priv
  sr_table_priv=$(query_val "wt04_test_h" \
    "SELECT has_table_privilege('service_role', 'public.participants', 'SELECT');")
  sr_schema_priv=$(query_val "wt04_test_h" \
    "SELECT has_schema_privilege('service_role', 'public', 'USAGE');")
  if [[ "$sr_table_priv" != "f" || "$sr_schema_priv" != "f" ]]; then
    echo "TEST H FAILED: service_role retained authority (table=$sr_table_priv, schema=$sr_schema_priv)" >&2
    return 1
  fi

  echo "TEST H PASSED"
  return 0
}

test_i_public_schema_access() {
  echo "Running TEST I — PUBLIC SCHEMA ACCESS..."
  setup_db "wt04_test_i"
  create_tables "wt04_test_i" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_i" -c \
    "GRANT ALL ON SCHEMA public TO PUBLIC; GRANT ALL ON SCHEMA public TO anon;" >/dev/null 2>&1

  if ! run_rehydration "wt04_test_i" "post-migration"; then
    echo "TEST I FAILED: command failed or missing" >&2
    return 1
  fi

  local public_schema_priv
  public_schema_priv=$(query_val "wt04_test_i" \
    "SELECT count(*) FROM pg_namespace n, LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type IN ('USAGE', 'CREATE');")
  if [[ "$public_schema_priv" -ne 0 ]]; then
    echo "TEST I FAILED: PUBLIC schema privileges not revoked" >&2
    return 1
  fi

  echo "TEST I PASSED"
  return 0
}

test_j_rls_disabled() {
  echo "Running TEST J — RLS DISABLED..."
  setup_db "wt04_test_j"
  create_tables "wt04_test_j" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_j" -c \
    "ALTER TABLE public.participants DISABLE ROW LEVEL SECURITY;" >/dev/null 2>&1

  if ! run_rehydration "wt04_test_j" "post-migration"; then
    echo "TEST J FAILED: command failed or missing" >&2
    return 1
  fi

  local rls_val
  rls_val=$(query_val "wt04_test_j" \
    "SELECT relrowsecurity FROM pg_class WHERE relname = 'participants';")
  if [[ "$rls_val" != "t" ]]; then
    echo "TEST J FAILED: RLS was not re-enabled on participants" >&2
    return 1
  fi

  echo "TEST J PASSED"
  return 0
}

test_k_force_rls_drift() {
  echo "Running TEST K — FORCE RLS DRIFT..."
  setup_db "wt04_test_k"
  create_tables "wt04_test_k" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_k" -c \
    "ALTER TABLE public.participants FORCE ROW LEVEL SECURITY;" >/dev/null 2>&1

  set +e
  run_rehydration "wt04_test_k" "post-migration"
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 127 ]]; then
    echo "TEST K FAILED: command missing" >&2
    return 1
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo "TEST K FAILED: expected rehydration to fail on unexpected FORCE RLS, but it succeeded" >&2
    return 1
  fi

  echo "TEST K PASSED"
  return 0
}

test_l_policy_drift() {
  echo "Running TEST L — POLICY DRIFT..."
  setup_db "wt04_test_l"
  create_tables "wt04_test_l" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_l" -c \
    "CREATE POLICY rogue_policy ON public.participants FOR SELECT USING (true);" >/dev/null 2>&1

  set +e
  run_rehydration "wt04_test_l" "post-migration"
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 127 ]]; then
    echo "TEST L FAILED: command missing" >&2
    return 1
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo "TEST L FAILED: expected rehydration to fail on unexpected policy, but it succeeded" >&2
    return 1
  fi

  echo "TEST L PASSED"
  return 0
}

test_m_future_table_defaults() {
  echo "Running TEST M — FUTURE TABLE DEFAULTS..."
  setup_db "wt04_test_m"
  create_tables "wt04_test_m" 30
  if ! run_rehydration "wt04_test_m" "post-migration"; then
    echo "TEST M FAILED: command failed or missing" >&2
    return 1
  fi

  # Create future table as postgres
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_m" -c \
    "CREATE TABLE public.wt04_future_table_probe (id bigint);" >/dev/null 2>&1

  local forbidden_count
  forbidden_count=$(query_val "wt04_test_m" \
    "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
     SELECT count(*) FROM api a CROSS JOIN (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'),('MAINTAIN')) p(priv)
     WHERE has_table_privilege(a.role_name, 'public.wt04_future_table_probe', p.priv);")
  if [[ "$forbidden_count" -ne 0 ]]; then
    echo "TEST M FAILED: future table inherited $forbidden_count API privileges" >&2
    return 1
  fi

  echo "TEST M PASSED"
  return 0
}

test_n_future_sequence_defaults() {
  echo "Running TEST N — FUTURE SEQUENCE DEFAULTS..."
  setup_db "wt04_test_n"
  create_tables "wt04_test_n" 30
  if ! run_rehydration "wt04_test_n" "post-migration"; then
    echo "TEST N FAILED: command failed or missing" >&2
    return 1
  fi

  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_n" -c \
    "CREATE SEQUENCE public.wt04_future_seq_probe;" >/dev/null 2>&1

  local forbidden_count
  forbidden_count=$(query_val "wt04_test_n" \
    "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
     SELECT count(*) FROM api a CROSS JOIN (VALUES ('USAGE'),('SELECT'),('UPDATE')) p(priv)
     WHERE has_sequence_privilege(a.role_name, 'public.wt04_future_seq_probe', p.priv);")
  if [[ "$forbidden_count" -ne 0 ]]; then
    echo "TEST N FAILED: future sequence inherited $forbidden_count API privileges" >&2
    return 1
  fi

  echo "TEST N PASSED"
  return 0
}

test_o_future_function_defaults() {
  echo "Running TEST O — FUTURE FUNCTION DEFAULTS..."
  setup_db "wt04_test_o"
  create_tables "wt04_test_o" 30
  if ! run_rehydration "wt04_test_o" "post-migration"; then
    echo "TEST O FAILED: command failed or missing" >&2
    return 1
  fi

  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_o" -c \
    "CREATE FUNCTION public.wt04_future_fn_probe() RETURNS int LANGUAGE sql AS 'SELECT 1';" >/dev/null 2>&1

  local api_forbidden public_forbidden
  api_forbidden=$(query_val "wt04_test_o" \
    "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
     SELECT count(*) FROM roles r
     WHERE has_function_privilege(r.role_name, 'public.wt04_future_fn_probe()', 'EXECUTE');")
  public_forbidden=$(query_val "wt04_test_o" \
    "SELECT count(*) FROM pg_proc p, LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE p.oid = 'public.wt04_future_fn_probe()'::regprocedure AND a.grantee = 0 AND a.privilege_type = 'EXECUTE';")
  if [[ "$api_forbidden" -ne 0 || "$public_forbidden" -ne 0 ]]; then
    echo "TEST O FAILED: future function inherited EXECUTE grants (api=$api_forbidden, public=$public_forbidden)" >&2
    return 1
  fi

  echo "TEST O PASSED"
  return 0
}

test_p_provider_object_safety() {
  echo "Running TEST P — PROVIDER OBJECT SAFETY..."
  setup_db "wt04_test_p"
  create_tables "wt04_test_p" 30
  psql -h 127.0.0.1 -p "$TEST_PG_PORT" -U postgres -d "wt04_test_p" -c \
    "CREATE TABLE public.provider_control_audit (id int); GRANT SELECT ON public.provider_control_audit TO service_role;" >/dev/null 2>&1

  set +e
  run_rehydration "wt04_test_p" "post-migration"
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 127 ]]; then
    echo "TEST P FAILED: command missing" >&2
    return 1
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo "TEST P FAILED: expected rehydration to fail on unexpected provider object in public, but succeeded" >&2
    return 1
  fi

  # Verify provider object exists and was not altered
  local sr_priv
  sr_priv=$(query_val "wt04_test_p" \
    "SELECT has_table_privilege('service_role', 'public.provider_control_audit', 'SELECT');")
  if [[ "$sr_priv" != "t" ]]; then
    echo "TEST P FAILED: provider object was mutated by rehydration attempt" >&2
    return 1
  fi

  echo "TEST P PASSED"
  return 0
}

# --- MAIN ---
ensure_cluster

target_test=${1:-all}
status=0

run_case() {
  local fn=$1
  if ! "$fn"; then
    status=1
  fi
}

case "$target_test" in
  all)
    run_case test_a_happy_path
    run_case test_b_idempotency
    run_case test_c_partial_replay
    run_case test_d_unknown_public_object
    run_case test_e_missing_required_table
    run_case test_f_wrong_table_owner
    run_case test_g_forbidden_api_privilege
    run_case test_h_service_role_access
    run_case test_i_public_schema_access
    run_case test_j_rls_disabled
    run_case test_k_force_rls_drift
    run_case test_l_policy_drift
    run_case test_m_future_table_defaults
    run_case test_n_future_sequence_defaults
    run_case test_o_future_function_defaults
    run_case test_p_provider_object_safety
    ;;
  test_a) run_case test_a_happy_path ;;
  test_b) run_case test_b_idempotency ;;
  test_c) run_case test_c_partial_replay ;;
  test_d) run_case test_d_unknown_public_object ;;
  test_e) run_case test_e_missing_required_table ;;
  test_f) run_case test_f_wrong_table_owner ;;
  test_g) run_case test_g_forbidden_api_privilege ;;
  test_h) run_case test_h_service_role_access ;;
  test_i) run_case test_i_public_schema_access ;;
  test_j) run_case test_j_rls_disabled ;;
  test_k) run_case test_k_force_rls_drift ;;
  test_l) run_case test_l_policy_drift ;;
  test_m) run_case test_m_future_table_defaults ;;
  test_n) run_case test_n_future_sequence_defaults ;;
  test_o) run_case test_o_future_function_defaults ;;
  test_p) run_case test_p_provider_object_safety ;;
  *) echo "Unknown test target: $target_test" >&2; exit 1 ;;
esac

if (( status == 0 )); then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$status"
