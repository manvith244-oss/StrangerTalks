#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"

backport_dir=${1:-backport}
canonical_dir=${2:-canonical}
state_a_version=20260821191324
security_versions=(20260909183500 20260910110008 20260910192317)
omitted_lower_versions=(
  20260826142000
  20260826143000
  20260830044500
  20260909181500
  20260909182500
  20260909183000
)

psqlq() {
  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -q "$@"
}

scalar() {
  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq -c "$1"
}

collect_versions() {
  local dir=$1
  find "$dir/priv/repo/migrations" -maxdepth 1 -type f -name '*.exs' -printf '%f\n' \
    | sed -nE 's/^([0-9]{14})_.*/\1/p' \
    | sort
}

assert_zero() {
  local label=$1
  local query=$2
  local value
  value=$(scalar "$query")
  echo "$label=$value"
  if [[ "$value" != "0" ]]; then
    echo "SECURITY_CLOSURE_ASSERTION_FAILED: $label expected 0, got $value" >&2
    return 1
  fi
}

record_db_versions() {
  psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq \
    -c 'SELECT version::text FROM public.schema_migrations ORDER BY version' > "$1"
}

release_ecto_write_probe() {
  local dir=$1
  local label=$2
  local bin="$dir/_build/prod/rel/strangertalks_new/bin/strangertalks_new"
  "$bin" eval 'Application.load(:strangertalks_new); {:ok, _, _} = Ecto.Migrator.with_repo(StrangertalksNew.Repo, fn repo -> result = Ecto.Adapters.SQL.query!(repo, "INSERT INTO public.participants DEFAULT VALUES RETURNING participant_id", []); [[participant_id]] = result.rows; Ecto.Adapters.SQL.query!(repo, "DELETE FROM public.participants WHERE participant_id = $1", [participant_id]); IO.puts("SECURITY_CLOSURE_ECTO_WRITE_PROBE=PASS") end)'
  echo "$label=PASS"
}

echo '=== SECURITY-CLOSURE-01 disposable Supabase-like fixture ==='
psqlq <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT CREATE, USAGE ON SCHEMA public TO supabase_admin;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES
  TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES
  TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO PUBLIC, anon, authenticated, service_role;
SQL

echo '=== STATE A: current production migration head ==='
(
  cd "$backport_dir"
  MIX_ENV=prod mix ecto.migrate --to "$state_a_version" 2>&1 | tee ../state-a-migrate.log
)
actual_state_a=$(scalar 'SELECT max(version)::text FROM public.schema_migrations')
echo "STATE_A_HEAD=$actual_state_a"
[[ "$actual_state_a" == "$state_a_version" ]]

collect_versions "$backport_dir" | awk -v max="$state_a_version" '$1 <= max' > expected-state-a.txt
record_db_versions actual-state-a.txt
diff -u expected-state-a.txt actual-state-a.txt

state_a_table_count=$(scalar "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relname <> 'schema_migrations'")
echo "STATE_A_APPLICATION_TABLES=$state_a_table_count"

 echo '=== Build deployed-SHA security-backport release ==='
(
  cd "$backport_dir"
  MIX_ENV=prod mix release --overwrite
)

echo '=== STATE B: approved three-migration security backport via release bin/migrate ==='
(
  cd "$backport_dir"
  _build/prod/rel/strangertalks_new/bin/migrate 2>&1 | tee ../state-b-release.log
)
collect_versions "$backport_dir" > expected-state-b.txt
record_db_versions actual-state-b.txt
diff -u expected-state-b.txt actual-state-b.txt

for version in "${security_versions[@]}"; do
  grep -qx "$version" actual-state-b.txt
 done

assert_zero STATE_B_RLS_DISABLED "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relname <> 'schema_migrations' AND NOT c.relrowsecurity"
assert_zero STATE_B_API_TABLE_PRIVILEGES "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), tables(table_name) AS (SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p')), privs(privilege_name) AS (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) SELECT count(*) FROM roles CROSS JOIN tables CROSS JOIN privs WHERE has_table_privilege(role_name, format('public.%I', table_name), privilege_name)"
assert_zero STATE_B_API_SCHEMA_PRIVILEGES "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), privs(privilege_name) AS (VALUES ('USAGE'),('CREATE')) SELECT count(*) FROM roles CROSS JOIN privs WHERE has_schema_privilege(role_name, 'public', privilege_name)"
assert_zero STATE_B_API_SEQUENCE_PRIVILEGES "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), seqs(seq_name) AS (SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'), privs(privilege_name) AS (VALUES ('USAGE'),('SELECT'),('UPDATE')) SELECT count(*) FROM roles CROSS JOIN seqs CROSS JOIN privs WHERE has_sequence_privilege(role_name, format('public.%I', seq_name), privilege_name)"
assert_zero STATE_B_API_FUNCTION_EXECUTE "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), funcs(fn_oid) AS (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public') SELECT count(*) FROM roles CROSS JOIN funcs WHERE has_function_privilege(role_name, fn_oid, 'EXECUTE')"

release_ecto_write_probe "$backport_dir" STATE_B_ECTO_PERSISTENCE

psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq \
  -c "SELECT version::text || '|' || inserted_at::text FROM public.schema_migrations WHERE version IN (20260909183500,20260910110008,20260910192317) ORDER BY version" \
  > security-inserted-before.txt

echo '=== STATE C preflight: expose same DB to complete canonical main migration directory ==='
collect_versions "$canonical_dir" > expected-state-c.txt
record_db_versions before-state-c.txt
comm -23 expected-state-c.txt before-state-c.txt > pending-state-c.txt

echo 'STATE_C_PENDING_BEGIN'
cat pending-state-c.txt
echo 'STATE_C_PENDING_END'

for version in "${omitted_lower_versions[@]}"; do
  grep -qx "$version" pending-state-c.txt || {
    echo "RECONCILIATION_PENDING_MISSING=$version" >&2
    exit 31
  }
done
for version in "${security_versions[@]}"; do
  if grep -qx "$version" pending-state-c.txt; then
    echo "SECURITY_MIGRATION_WOULD_RERUN=$version" >&2
    exit 32
  fi
done

echo '=== Build canonical-main release ==='
(
  cd "$canonical_dir"
  MIX_ENV=prod mix release --overwrite
)

echo '=== STATE C: normal canonical-main release bin/migrate ==='
set +e
(
  cd "$canonical_dir"
  _build/prod/rel/strangertalks_new/bin/migrate
) 2>&1 | tee state-c-release.log
state_c_rc=${PIPESTATUS[0]}
set -e

echo "STATE_C_MIGRATE_EXIT=$state_c_rc"
if [[ "$state_c_rc" -ne 0 ]]; then
  echo 'FUTURE_MAIN_RECONCILIATION=FAIL_MIGRATION' >&2
  exit 40
fi

echo 'STATE_C_MIGRATION_WARNING_EVIDENCE_BEGIN'
grep -Ei 'warn|migration|order|version' state-c-release.log || true
echo 'STATE_C_MIGRATION_WARNING_EVIDENCE_END'

record_db_versions actual-state-c.txt
diff -u expected-state-c.txt actual-state-c.txt

total_versions=$(scalar 'SELECT count(*) FROM public.schema_migrations')
distinct_versions=$(scalar 'SELECT count(DISTINCT version) FROM public.schema_migrations')
echo "STATE_C_VERSION_COUNT=$total_versions"
echo "STATE_C_DISTINCT_VERSION_COUNT=$distinct_versions"
[[ "$total_versions" == "$distinct_versions" ]]

psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq \
  -c "SELECT version::text || '|' || inserted_at::text FROM public.schema_migrations WHERE version IN (20260909183500,20260910110008,20260910192317) ORDER BY version" \
  > security-inserted-after.txt
diff -u security-inserted-before.txt security-inserted-after.txt

for table_name in source_rate_limits participant_pairing_reservations hangout_rooms hangout_memberships hangout_messages hangout_reports; do
  exists=$(scalar "SELECT to_regclass('public.${table_name}') IS NOT NULL")
  echo "STATE_C_TABLE_${table_name}_EXISTS=$exists"
  [[ "$exists" == "t" ]]
  for role in anon authenticated; do
    any_priv=$(scalar "SELECT has_table_privilege('${role}', 'public.${table_name}', 'SELECT') OR has_table_privilege('${role}', 'public.${table_name}', 'INSERT') OR has_table_privilege('${role}', 'public.${table_name}', 'UPDATE') OR has_table_privilege('${role}', 'public.${table_name}', 'DELETE')")
    echo "STATE_C_${role}_${table_name}_CRUD=$any_priv"
    [[ "$any_priv" == "f" ]]
  done
done

assert_zero STATE_C_API_TABLE_PRIVILEGES "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), tables(table_name) AS (SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p')), privs(privilege_name) AS (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) SELECT count(*) FROM roles CROSS JOIN tables CROSS JOIN privs WHERE has_table_privilege(role_name, format('public.%I', table_name), privilege_name)"
assert_zero STATE_C_API_SCHEMA_PRIVILEGES "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), privs(privilege_name) AS (VALUES ('USAGE'),('CREATE')) SELECT count(*) FROM roles CROSS JOIN privs WHERE has_schema_privilege(role_name, 'public', privilege_name)"
assert_zero STATE_C_API_SEQUENCE_PRIVILEGES "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), seqs(seq_name) AS (SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'), privs(privilege_name) AS (VALUES ('USAGE'),('SELECT'),('UPDATE')) SELECT count(*) FROM roles CROSS JOIN seqs CROSS JOIN privs WHERE has_sequence_privilege(role_name, format('public.%I', seq_name), privilege_name)"
assert_zero STATE_C_API_FUNCTION_EXECUTE "WITH roles(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')), funcs(fn_oid) AS (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public') SELECT count(*) FROM roles CROSS JOIN funcs WHERE has_function_privilege(role_name, fn_oid, 'EXECUTE')"

release_ecto_write_probe "$canonical_dir" STATE_C_ECTO_PERSISTENCE

rls_disabled=$(scalar "SELECT COALESCE(string_agg(c.relname, ',' ORDER BY c.relname), '') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relname <> 'schema_migrations' AND NOT c.relrowsecurity")
echo "STATE_C_RLS_DISABLED_TABLES=$rls_disabled"
if [[ -n "$rls_disabled" ]]; then
  echo "FUTURE_MAIN_RECONCILIATION_RLS_GAP=$rls_disabled" >&2
  exit 42
fi

echo 'FUTURE_MAIN_RECONCILIATION=PASS'
