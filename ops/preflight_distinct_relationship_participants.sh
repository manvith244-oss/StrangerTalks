#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL must point at the authoritative production database}"

command -v psql >/dev/null 2>&1 || {
  echo "psql is required for the relationship preflight" >&2
  exit 127
}

export PGOPTIONS='-c default_transaction_read_only=on'

readonly_state=$(psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c "SHOW default_transaction_read_only")
readonly_state=$(printf '%s' "$readonly_state" | tail -n 1 | tr -d '[:space:]')

if [ "$readonly_state" != "on" ]; then
  echo "AUTHORITATIVE_DB_VERIFIED=false"
  echo "PREFLIGHT_RESULT=BLOCKED_READ_ONLY_GUARD_NOT_ACTIVE"
  exit 2
fi

query='SELECT count(*)::bigint FROM public.relationships WHERE participant_a_id = participant_b_id;'
count=$(psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c "$query")
count=$(printf '%s' "$count" | tail -n 1 | tr -d '[:space:]')

case "$count" in
  ''|*[!0-9]*)
    echo "AUTHORITATIVE_DB_VERIFIED=false"
    echo "PREFLIGHT_RESULT=BLOCKED_INVALID_COUNT_RESULT"
    exit 2
    ;;
esac

echo "AUTHORITATIVE_DB_VERIFIED=supabase"
echo "QUERY_USED=$query"
echo "SELF_RELATIONSHIP_COUNT=$count"

if [ "$count" = "0" ]; then
  echo "MIGRATION_OPERATIONAL_ELIGIBILITY=ELIGIBLE"
  echo "PREFLIGHT_RESULT=PASS"
  exit 0
fi

echo "MIGRATION_OPERATIONAL_ELIGIBILITY=BLOCKED"
echo "OWNER_CONSTRUCTION_COMMAND_DATA_REMEDIATION_DECISION_REQUIRED"
echo "PREFLIGHT_RESULT=OWNER_DECISION_REQUIRED"
exit 3
