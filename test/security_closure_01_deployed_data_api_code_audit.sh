#!/usr/bin/env bash
set -euo pipefail

patterns='service_role|/rest/v1|postgrest|SUPABASE_(URL|ANON|SERVICE_ROLE)|supabase\.co/rest|/rpc/'

if git grep -nE "$patterns" -- lib config assets priv/static rel > security-closure-01-data-api-runtime-hits.txt; then
  echo 'DEPLOYED_DATA_API_RUNTIME_HITS_BEGIN'
  cat security-closure-01-data-api-runtime-hits.txt
  echo 'DEPLOYED_DATA_API_RUNTIME_HITS_END'
  exit 1
fi

echo 'DEPLOYED_DATA_API_RUNTIME_CODE_AUDIT=PASS'
