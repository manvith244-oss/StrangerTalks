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

# Pre-hangout 26 Application Tables
PRE_HANGOUT_APP_TABLES=(
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

echo "=== STRANGERTALKS AUTHORITY REHYDRATION ==="
echo "mode=$MODE"
echo "url_provided=true (value redacted)"

# 1. PLATFORM PRECONDITIONS
echo "--- Checking Platform Preconditions ---"
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

# 2. CATALOG DRIFT GUARDS (Pre-check)
echo "--- Evaluating Catalog State and Drift Guards ---"

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

# Check migration ledger if schema_migrations exists
has_schema_migrations=$(run_psql_val "SELECT to_regclass('public.schema_migrations') IS NOT NULL;")
migration_head=0
if [[ "$has_schema_migrations" == "t" ]]; then
  migration_head=$(run_psql_val "SELECT COALESCE(max(version), 0) FROM public.schema_migrations;")
fi
echo "migration_head=$migration_head"

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
  # pre-migration mode: expect tables according to migration head or existing subset
  if (( migration_head < 20260910002000 && migration_head > 0 )); then
    # Pre-hangout generation
    for canon in "${PRE_HANGOUT_APP_TABLES[@]}"; do
      exists=$(run_psql_val "SELECT to_regclass('public.$canon') IS NOT NULL;")
      if [[ "$exists" == "t" ]]; then
        EXPECTED_TABLES+=("$canon")
      fi
    done
  else
    for canon in "${CANONICAL_APP_TABLES[@]}"; do
      exists=$(run_psql_val "SELECT to_regclass('public.$canon') IS NOT NULL;")
      if [[ "$exists" == "t" ]]; then
        EXPECTED_TABLES+=("$canon")
      fi
    done
  fi
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
if [[ "$has_schema_migrations" == "t" ]]; then
  run_psql_cmd -c "ALTER TABLE public.schema_migrations OWNER TO postgres;" >/dev/null
fi
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
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC', current_user);
  IF current_user <> 'postgres' THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC';
  END IF;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE EXECUTE ON FUNCTIONS FROM %I', current_user, r);
      IF current_user <> 'postgres' THEN
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM %I', r);
      END IF;
    END IF;
  END LOOP;
END $$;

-- 3. Schema public function defaults closure
DO $$
DECLARE r text;
BEGIN
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC', current_user);
  IF current_user <> 'postgres' THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC';
  END IF;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM %I', current_user, r);
      IF current_user <> 'postgres' THEN
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM %I', r);
      END IF;
    END IF;
  END LOOP;
END $$;

-- 4. Default table and sequence privileges for creator
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM %I', current_user, r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM %I', current_user, r);
      IF current_user <> 'postgres' THEN
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM %I', r);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM %I', r);
      END IF;
    END IF;
  END LOOP;
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM PUBLIC', current_user);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM PUBLIC', current_user);
  IF current_user <> 'postgres' THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM PUBLIC';
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE USAGE, SELECT, UPDATE ON SEQUENCES FROM PUBLIC';
  END IF;
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

if [[ "$has_schema_migrations" == "t" ]]; then
  run_psql_cmd <<SQL >/dev/null
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM service_role;
REVOKE ALL PRIVILEGES ON TABLE public.schema_migrations FROM PUBLIC;
SQL
fi
echo "authority_boundaries_reasserted=true"

# 5. POST-RECONCILIATION VERIFICATION
echo "--- Verifying Final Authority State ---"

# Verify RLS on all expected manifest tables
for tbl in "${EXPECTED_TABLES[@]}"; do
  rls_state=$(run_psql_val "SELECT relrowsecurity FROM pg_class WHERE oid = 'public.\"$tbl\"'::regclass;")
  force_state=$(run_psql_val "SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.\"$tbl\"'::regclass;")
  tbl_owner=$(run_psql_val "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.\"$tbl\"'::regclass;")
  if [[ "$rls_state" != "t" || "$force_state" != "f" || "$tbl_owner" != "postgres" ]]; then
    echo "error: verification failed for table '$tbl' (rls=$rls_state, force=$force_state, owner=$tbl_owner)" >&2
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
