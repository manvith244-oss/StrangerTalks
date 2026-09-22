#!/usr/bin/env bash
set -euo pipefail

# ops/postgres_rehydrate_authority.sh
# WT-04 Team 5-B: Reassert and verify StrangerTalks-owned authority on a recovered target.

MODE=${1:-"post-migration"}

case "$MODE" in
  pre-migration|post-migration) ;;
  *)
    echo "usage: postgres_rehydrate_authority.sh [pre-migration|post-migration]" >&2
    exit 1
    ;;
esac

TARGET_URL=${TARGET_DATABASE_URL:-${DATABASE_URL:-}}
if [[ -z "$TARGET_URL" ]]; then
  echo "error: DATABASE_URL or TARGET_DATABASE_URL must be set" >&2
  exit 1
fi

CONFIRM_TOKEN=${CONFIRM_AUTHORITY_REHYDRATION:-}
if [[ "$CONFIRM_TOKEN" != "REHYDRATE_STRANGERTALKS_AUTHORITY" ]]; then
  echo "error: CONFIRM_AUTHORITY_REHYDRATION=REHYDRATE_STRANGERTALKS_AUTHORITY is required" >&2
  exit 2
fi

command -v psql >/dev/null 2>&1 || {
  echo "error: psql is required" >&2
  exit 127
}

run_psql_cmd() {
  PGSSLMODE=${PGSSLMODE:-prefer} psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 "$@"
}

run_psql_val() {
  PGSSLMODE=${PGSSLMODE:-prefer} psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 -At -c "$1" | tr -d '\r'
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$REPO_ROOT/priv/repo/migrations}"

# Explicit Canonical Manifest of 30 Application Tables
CANONICAL_APP_TABLES=(
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

# Canonical introduction map for 30 application tables (table:introduced_at_version)
TABLE_INTRO_MAP=(
  "account_sessions:20260806034042"
  "account_sync_states:20260806034848"
  "analytics_records:20260703234500"
  "boundary_blocks:20260704000001"
  "composer_grants:20260820145713"
  "conversations:20260702163000"
  "google_account_links:20260806034042"
  "google_oauth_attempts:20260806034042"
  "hangout_memberships:20260910002000"
  "hangout_messages:20260910002000"
  "hangout_reports:20260910002000"
  "hangout_rooms:20260910002000"
  "learning_records:20260704000100"
  "matches:20260701113000"
  "memories:20260702172100"
  "message_reactions:20260703014500"
  "messages:20260702164300"
  "participant_pairing_reservations:20260830044500"
  "participants:20260701111335"
  "private_accounts:20260806034042"
  "queue_states:20260704000001"
  "reflections:20260820145713"
  "relationship_consents:20260805091809"
  "relationship_reconnection_intents:20260806021959"
  "relationships:20260703000000"
  "report_safety_media:20260814075417"
  "reports:20260703144144"
  "safety_events:20260703192500"
  "safety_reviews:20260805091809"
  "source_rate_limits:20260826142000"
)

echo "=== STRANGERTALKS AUTHORITY REHYDRATION ==="
echo "mode=$MODE"
echo "url_provided=true (value redacted)"

# 1. PLATFORM PRECONDITIONS
echo "--- Checking Platform Preconditions ---"

# Execution principal must strictly be postgres
current_user=$(run_psql_val "SELECT current_user;")
if [[ "$current_user" != "postgres" ]]; then
  echo "error: execution user must be 'postgres' (found '$current_user')" >&2
  exit 1
fi
echo "execution_user_verified=postgres"

REQUIRED_ROLES=(postgres anon authenticated service_role authenticator pg_database_owner)
for role in "${REQUIRED_ROLES[@]}"; do
  exists=$(run_psql_val "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role');")
  if [[ "$exists" != "t" ]]; then
    echo "error: required platform role '$role' is missing" >&2
    exit 1
  fi
done
echo "platform_roles_verified=true"

db_owner=$(run_psql_val "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database();")
if [[ "$db_owner" != "postgres" ]]; then
  echo "error: database owner must be 'postgres' (found '$db_owner')" >&2
  exit 1
fi
echo "database_owner_verified=postgres"

# 2. MIGRATION LEDGER VALIDATION & CATALOG DRIFT GUARDS
echo "--- Evaluating Migration Ledger and Catalog Drift Guards ---"

# Migration ledger public.schema_migrations is mandatory recovery truth
has_schema_migrations=$(run_psql_val "SELECT to_regclass('public.schema_migrations') IS NOT NULL;")
if [[ "$has_schema_migrations" != "t" ]]; then
  echo "error: migration ledger 'public.schema_migrations' is missing" >&2
  exit 1
fi

ledger_count=$(run_psql_val "SELECT count(*) FROM public.schema_migrations;")
if [[ "$ledger_count" -eq 0 ]]; then
  echo "error: migration ledger 'public.schema_migrations' is empty" >&2
  exit 1
fi

db_versions_raw=$(run_psql_val "SELECT version FROM public.schema_migrations ORDER BY version ASC;")

# Derive known migration versions from checked-out repository
if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "error: repository migrations directory not found: $MIGRATIONS_DIR" >&2
  exit 1
fi

KNOWN_MIGRATIONS=()
for f in "$MIGRATIONS_DIR"/*.exs; do
  [[ -f "$f" ]] || continue
  fname=$(basename "$f")
  if [[ "$fname" =~ ^([0-9]+)_ ]]; then
    KNOWN_MIGRATIONS+=("${BASH_REMATCH[1]}")
  fi
done

if (( ${#KNOWN_MIGRATIONS[@]} == 0 )); then
  echo "error: no repository migrations found in $MIGRATIONS_DIR" >&2
  exit 1
fi

# Compare every DB ledger version against repository-known migrations
IFS=$'\n' read -rd '' -a db_versions <<<"$db_versions_raw" || true
for v in "${db_versions[@]}"; do
  v=$(echo "$v" | tr -d '\r' | xargs)
  [[ -n "$v" ]] || continue
  found=0
  for kv in "${KNOWN_MIGRATIONS[@]}"; do
    if [[ "$v" == "$kv" ]]; then
      found=1
      break
    fi
  done
  if (( found == 0 )); then
    echo "error: unknown migration version in public.schema_migrations: '$v'" >&2
    exit 1
  fi
done

migration_head=$(run_psql_val "SELECT max(version) FROM public.schema_migrations;")
echo "migration_head=$migration_head"

# Detect unexpected public sequences
unexpected_seq_count=$(run_psql_val "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'S';")
if [[ "$unexpected_seq_count" -ne 0 ]]; then
  echo "error: unexpected public sequence detected (count=$unexpected_seq_count)" >&2
  exit 1
fi

# Detect unexpected public views / matviews
unexpected_view_count=$(run_psql_val "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm');")
if [[ "$unexpected_view_count" -ne 0 ]]; then
  echo "error: unexpected public view/materialized view detected (count=$unexpected_view_count)" >&2
  exit 1
fi

# Detect unexpected public functions/RPCs
unexpected_fn_count=$(run_psql_val "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public';")
if [[ "$unexpected_fn_count" -ne 0 ]]; then
  echo "error: unexpected public function/RPC detected (count=$unexpected_fn_count)" >&2
  exit 1
fi

# Detect unexpected public tables
public_tables_raw=$(run_psql_val "SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY relname;")
IFS=$'\n' read -rd '' -a current_public_tables <<<"$public_tables_raw" || true

# Check that every existing public table is either in CANONICAL_APP_TABLES or schema_migrations
for tbl in "${current_public_tables[@]}"; do
  tbl=$(echo "$tbl" | tr -d '\r' | xargs)
  [[ -n "$tbl" ]] || continue
  if [[ "$tbl" == "schema_migrations" ]]; then
    continue
  fi
  match=0
  for canon in "${CANONICAL_APP_TABLES[@]}"; do
    if [[ "$tbl" == "$canon" ]]; then
      match=1
      break
    fi
  done
  if (( match == 0 )); then
    echo "error: unexpected public table detected: '$tbl'" >&2
    exit 1
  fi
done

# Determine expected table manifest based on mode and migration head
EXPECTED_TABLES=()
if [[ "$MODE" == "post-migration" ]]; then
  EXPECTED_TABLES=("${CANONICAL_APP_TABLES[@]}")
  # All 30 tables MUST exist in post-migration
  for canon in "${CANONICAL_APP_TABLES[@]}"; do
    exists=$(run_psql_val "SELECT to_regclass('public.$canon') IS NOT NULL;")
    if [[ "$exists" != "t" ]]; then
      echo "error: missing required application table in post-migration: '$canon'" >&2
      exit 1
    fi
  done
else
  # pre-migration mode: generation-aware deterministic manifest
  # Every table whose introduction version <= migration_head MUST exist
  # Tables introduced later (intro > migration_head) may legitimately be absent
  for entry in "${TABLE_INTRO_MAP[@]}"; do
    tbl="${entry%%:*}"
    intro_ver="${entry##*:}"
    exists=$(run_psql_val "SELECT to_regclass('public.$tbl') IS NOT NULL;")
    if (( intro_ver <= migration_head )); then
      if [[ "$exists" != "t" ]]; then
        echo "error: missing historically-required application table in pre-migration: '$tbl' (introduced at $intro_ver, head is $migration_head)" >&2
        exit 1
      fi
      EXPECTED_TABLES+=("$tbl")
    fi
  done
fi
echo "expected_manifest_tables_count=${#EXPECTED_TABLES[@]}"

# Drift Guard: Unexpected FORCE RLS
forced_count=$(run_psql_val "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relforcerowsecurity = true;")
if [[ "$forced_count" -ne 0 ]]; then
  echo "error: unexpected FORCE RLS detected on public table (count=$forced_count)" >&2
  exit 1
fi
echo "forced_rls_verified=none"

# Drift Guard: Unexpected Policies
policy_count=$(run_psql_val "SELECT count(*) FROM pg_policies WHERE schemaname = 'public';")
if [[ "$policy_count" -ne 0 ]]; then
  echo "error: unexpected policy detected in public schema (count=$policy_count)" >&2
  exit 1
fi
echo "public_policies_verified=none"

# 3. OWNERSHIP NORMALIZATION
echo "--- Normalizing Manifest Ownership ---"
# Reassert public schema owner as pg_database_owner
run_psql_cmd -c "ALTER SCHEMA public OWNER TO pg_database_owner;" >/dev/null

# Only normalize explicitly manifested StrangerTalks application tables and schema_migrations
for tbl in "${EXPECTED_TABLES[@]}"; do
  run_psql_cmd -c "ALTER TABLE public.\"$tbl\" OWNER TO postgres;" >/dev/null
done
run_psql_cmd -c "ALTER TABLE public.schema_migrations OWNER TO postgres;" >/dev/null
echo "manifest_ownership_normalized=postgres"

# 4. REASSERT AUTHORITY CONVERGENCE
echo "--- Reasserting Authority Boundaries ---"

rehydration_sql=$(cat <<'SQL'
-- 1. Schema boundary closure
REVOKE ALL PRIVILEGES ON SCHEMA public FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA public FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- 2. Global function defaults closure
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- 3. Schema public function defaults closure
DO $$
DECLARE r text;
BEGIN
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- 4. Default table and sequence privileges for creator postgres
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM %I', r);
    END IF;
  END LOOP;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM PUBLIC;
END $$;
SQL
)

run_psql_cmd -c "$rehydration_sql" >/dev/null

# Reassert RLS and revoke API/PUBLIC privileges on every manifest table
for tbl in "${EXPECTED_TABLES[@]}"; do
  run_psql_cmd <<SQL >/dev/null
ALTER TABLE public."$tbl" ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON TABLE public."$tbl" FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public."$tbl" FROM authenticated;
REVOKE ALL PRIVILEGES ON TABLE public."$tbl" FROM service_role;
REVOKE ALL PRIVILEGES ON TABLE public."$tbl" FROM PUBLIC;
SQL
done

run_psql_cmd <<SQL >/dev/null
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM service_role;
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM PUBLIC;
SQL
echo "authority_boundaries_reasserted=true"

# 5. POST-RECONCILIATION VERIFICATION
echo "--- Verifying Final Authority State ---"

# Verify RLS on all expected manifest tables
for tbl in "${EXPECTED_TABLES[@]}"; do
  row_check=$(run_psql_val "SELECT relrowsecurity || ':' || relforcerowsecurity || ':' || pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.\"$tbl\"'::regclass;")
  if [[ "$row_check" != "t:f:postgres" && "$row_check" != "true:false:postgres" ]]; then
    echo "error: verification failed for table '$tbl' (expected true:false:postgres, got $row_check)" >&2
    exit 1
  fi
done

# Verify schema closure
api_schema_privs=$(run_psql_val "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role'))
  SELECT count(*) FROM api a CROSS JOIN (VALUES ('USAGE'),('CREATE')) p(priv)
  WHERE has_schema_privilege(a.role_name, 'public', p.priv);")
if [[ "$api_schema_privs" -ne 0 ]]; then
  echo "error: verification failed: API roles retain public schema privileges ($api_schema_privs)" >&2
  exit 1
fi

# Verify schema owner
schema_owner=$(run_psql_val "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public';")
if [[ "$schema_owner" != "pg_database_owner" ]]; then
  echo "error: verification failed: public schema owner must be 'pg_database_owner' (found '$schema_owner')" >&2
  exit 1
fi
echo "final_schema_owner_verified=pg_database_owner"

public_schema_privs=$(run_psql_val "SELECT count(*) FROM pg_namespace n, LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type IN ('USAGE', 'CREATE');")
if [[ "$public_schema_privs" -ne 0 ]]; then
  echo "error: verification failed: PUBLIC retains public schema privileges ($public_schema_privs)" >&2
  exit 1
fi

# Verify table privilege closure on all expected tables
api_table_privs=$(run_psql_val "WITH api(role_name) AS (VALUES ('anon'),('authenticated'),('service_role')),
      pub_tables AS (SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p'))
 SELECT count(*) FROM api a CROSS JOIN pub_tables t CROSS JOIN (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) p(priv)
 WHERE has_table_privilege(a.role_name, t.oid, p.priv);")
if [[ "$api_table_privs" -ne 0 ]]; then
  echo "error: verification failed: API roles retain table privileges ($api_table_privs)" >&2
  exit 1
fi

echo "final_rls_verified=true"
echo "final_table_privileges_closed=true"
echo "final_schema_privileges_closed=true"
echo "final_policies_count=0"
echo "final_sequences_count=0"
echo "final_functions_count=0"
echo "AUTHORITY_REHYDRATION_COMPLETED=SUCCESS"
exit 0
