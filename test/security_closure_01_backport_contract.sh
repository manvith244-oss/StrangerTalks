#!/usr/bin/env bash
set -euo pipefail

# Red phase: this contract must fail until the three approved migrations are present.
approved=(
  priv/repo/migrations/20260909183500_secure_supabase_public_schema_c1.exs
  priv/repo/migrations/20260910110008_harden_public_rpc_defaults_rpr.exs
  priv/repo/migrations/20260910192317_close_public_schema_data_api_boundary_rpr.exs
)

blocked=(
  priv/repo/migrations/20260826142000_create_source_rate_limits.exs
  priv/repo/migrations/20260826143000_add_participant_credential_version.exs
  priv/repo/migrations/20260830044500_create_participant_pairing_reservations.exs
  priv/repo/migrations/20260909181500_add_report_media_origin_truth.exs
  priv/repo/migrations/20260909182500_enforce_distinct_match_conversation_participants_c3.exs
  priv/repo/migrations/20260909183000_enforce_distinct_relationship_participants_c3.exs
  priv/repo/migrations/20260910002000_create_hangouts_v1.exs
  priv/repo/migrations/20260910003000_secure_hangouts_v1.exs
  priv/repo/migrations/20260910004000_add_hangout_current_content_id.exs
)

for path in "${approved[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "SECURITY_CLOSURE_RED: missing approved migration: $path" >&2
    exit 1
  fi
done

for path in "${blocked[@]}"; do
  if [[ -e "$path" ]]; then
    echo "SECURITY_CLOSURE_SCOPE_BREACH: blocked migration present: $path" >&2
    exit 1
  fi
done

echo "SECURITY_CLOSURE_BACKPORT_CONTRACT=PASS"
