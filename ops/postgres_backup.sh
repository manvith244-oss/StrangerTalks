#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL must point at the database to back up}"

output=${1:-"strangertalks-$(date -u +%Y%m%dT%H%M%SZ).dump"}
output_dir=$(dirname -- "$output")
mkdir -p -- "$output_dir"
umask 077

command -v pg_dump >/dev/null 2>&1 || {
  echo "pg_dump is required" >&2
  exit 127
}

pg_dump \
  --format=custom \
  --no-owner \
  --no-acl \
  --file="$output" \
  "$DATABASE_URL"

test -s "$output" || {
  echo "backup artifact is empty" >&2
  exit 1
}

printf 'backup_created=%s\n' "$output"
