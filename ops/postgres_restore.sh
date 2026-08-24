#!/usr/bin/env bash
set -euo pipefail

: "${RESTORE_DATABASE_URL:?RESTORE_DATABASE_URL must point at the restore target}"
: "${CONFIRM_RESTORE:?Set CONFIRM_RESTORE=RESTORE_STRANGERTALKS to acknowledge destructive restore semantics}"

if [[ "$CONFIRM_RESTORE" != "RESTORE_STRANGERTALKS" ]]; then
  echo "restore confirmation token is invalid" >&2
  exit 2
fi

backup=${1:?usage: postgres_restore.sh BACKUP.dump}

test -s "$backup" || {
  echo "backup artifact is missing or empty" >&2
  exit 1
}

command -v pg_restore >/dev/null 2>&1 || {
  echo "pg_restore is required" >&2
  exit 127
}

pg_restore \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl \
  --exit-on-error \
  --dbname="$RESTORE_DATABASE_URL" \
  "$backup"

printf 'restore_completed=%s\n' "$backup"
