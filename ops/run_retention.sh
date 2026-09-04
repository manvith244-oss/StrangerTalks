#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL must point at the authoritative database for retention}"

export MIX_ENV="${MIX_ENV:-prod}"
export PHX_HOST="${PHX_HOST:-retention.invalid}"
export POOL_SIZE="${POOL_SIZE:-2}"

if [ -z "${SECRET_KEY_BASE:-}" ]; then
  command -v openssl >/dev/null 2>&1 || {
    echo "openssl is required to generate an ephemeral retention task secret" >&2
    exit 127
  }
  export SECRET_KEY_BASE="$(openssl rand -hex 64)"
fi

echo "RETENTION_RUNNER=ops/run_retention.sh"
echo "RETENTION_MIX_ENV=$MIX_ENV"
mix strangertalks.retention
echo "RETENTION_RESULT=PASS"
