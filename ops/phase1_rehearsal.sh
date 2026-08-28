#!/usr/bin/env bash
set -u -o pipefail

: "${DATABASE_URL:?DATABASE_URL must remain the production/source database URL}"
: "${SUPABASE_DATABASE_URL:?SUPABASE_DATABASE_URL must point at the Supabase rehearsal target}"

repo_root=${1:?usage: phase1_rehearsal.sh REPO_ROOT RELEASE_BIN}
release_bin=${2:?usage: phase1_rehearsal.sh REPO_ROOT RELEASE_BIN}

if [[ "$DATABASE_URL" == "$SUPABASE_DATABASE_URL" ]]; then
  echo "phase1_safety_error=source_and_target_urls_are_identical" >&2
  exit 2
fi

source_url_at_start=$DATABASE_URL
workdir="/tmp/strangertalks-phase1-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p -- "$workdir"
chmod 700 "$workdir"
dump="$workdir/source.dump"

status=0

require_command() {
  local command_name=$1
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "phase1_missing_command=$command_name" >&2
    status=1
  fi
}

for command_name in bash psql pg_dump pg_restore sha256sum stat sort diff join awk; do
  require_command "$command_name"
done

if (( status != 0 )); then
  echo "PHASE1_RESULT=FAIL_PRECHECK"
  exit "$status"
fi

echo "PHASE1_REHEARSAL_BEGIN"
echo "phase1_utc_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "phase1_source_target_distinct=true"
echo "phase1_database_url_source_env=DATABASE_URL"
echo "phase1_database_url_target_env=SUPABASE_DATABASE_URL"
echo "phase1_production_database_url_value_printed=false"
echo "phase1_supabase_database_url_value_printed=false"
psql --version
pg_dump --version
pg_restore --version

echo "PHASE1_SOURCE_INVENTORY_BEGIN"
source_inventory=$(PGSSLMODE=require psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F $'\t' -c \
  "WITH s AS (SELECT pg_database_size(current_database())::bigint AS bytes) SELECT current_database(), bytes, pg_size_pretty(bytes), 524288000::bigint, (524288000::bigint - bytes), round(bytes::numeric * 100 / 524288000::numeric, 4) FROM s;")
source_inventory_rc=$?
printf 'database\tsize_bytes\tsize_pretty\tcap_bytes\tbytes_remaining\tpct_of_500mb_cap\n'
printf '%s\n' "$source_inventory"
echo "phase1_source_inventory_exit=$source_inventory_rc"
if (( source_inventory_rc != 0 )); then status=1; fi
echo "PHASE1_SOURCE_INVENTORY_END"

echo "PHASE1_TARGET_TLS_CLIENT_BEGIN"
PGSSLMODE=require psql "$SUPABASE_DATABASE_URL" -X -v ON_ERROR_STOP=1 -c '\conninfo' 2>&1
target_conninfo_rc=$?
echo "phase1_target_psql_conninfo_exit=$target_conninfo_rc"
if (( target_conninfo_rc != 0 )); then status=1; fi
echo "PHASE1_TARGET_TLS_CLIENT_END"

source_tables="$workdir/source_tables.txt"
target_tables="$workdir/target_tables.txt"
source_counts="$workdir/source_counts.tsv"
target_counts="$workdir/target_counts.tsv"
source_constraints="$workdir/source_constraints.tsv"
target_constraints="$workdir/target_constraints.tsv"
source_migrations="$workdir/source_schema_migrations.txt"
target_migrations="$workdir/target_schema_migrations.txt"

PGSSLMODE=require psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c \
  "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" >"$source_tables"
source_tables_rc=$?
echo "phase1_source_table_inventory_exit=$source_tables_rc"
if (( source_tables_rc != 0 )); then status=1; fi

echo "PHASE1_SOURCE_TABLES_BEGIN"
cat "$source_tables"
echo "PHASE1_SOURCE_TABLES_END"

write_counts() {
  local url=$1
  local tables_file=$2
  local output=$3
  : >"$output"
  while IFS= read -r table_name; do
    [[ -n "$table_name" ]] || continue
    local row_count
    row_count=$(PGSSLMODE=require psql "$url" -X -v ON_ERROR_STOP=1 -v table_name="$table_name" -At -c \
      'SELECT count(*)::bigint FROM public.:"table_name";') || return $?
    printf '%s\t%s\n' "$table_name" "$row_count" >>"$output"
  done <"$tables_file"
  sort -o "$output" "$output"
}

write_counts "$DATABASE_URL" "$source_tables" "$source_counts"
source_counts_rc=$?
echo "phase1_source_row_counts_exit=$source_counts_rc"
if (( source_counts_rc != 0 )); then status=1; fi

echo "PHASE1_SOURCE_ROW_COUNTS_BEGIN"
printf 'table\trows\n'
cat "$source_counts"
echo "PHASE1_SOURCE_ROW_COUNTS_END"

constraint_sql="SELECT cls.relname || E'\\t' || con.conname || E'\\t' || con.contype || E'\\t' || regexp_replace(pg_get_constraintdef(con.oid, true), E'[\\n\\r\\t]+', ' ', 'g') FROM pg_constraint con JOIN pg_class cls ON cls.oid = con.conrelid JOIN pg_namespace ns ON ns.oid = cls.relnamespace WHERE ns.nspname = 'public' ORDER BY cls.relname, con.conname, con.contype, pg_get_constraintdef(con.oid, true);"

PGSSLMODE=require psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c "$constraint_sql" | sort >"$source_constraints"
source_constraints_rc=${PIPESTATUS[0]}
echo "phase1_source_constraints_exit=$source_constraints_rc"
if (( source_constraints_rc != 0 )); then status=1; fi

echo "PHASE1_SOURCE_CONSTRAINTS_BEGIN"
cat "$source_constraints"
echo "PHASE1_SOURCE_CONSTRAINTS_END"

PGSSLMODE=require psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c \
  "SELECT version::text FROM public.schema_migrations ORDER BY version;" >"$source_migrations"
source_migrations_rc=$?
echo "phase1_source_schema_migrations_exit=$source_migrations_rc"
if (( source_migrations_rc != 0 )); then status=1; fi

echo "PHASE1_SOURCE_SCHEMA_MIGRATIONS_BEGIN"
cat "$source_migrations"
echo "PHASE1_SOURCE_SCHEMA_MIGRATIONS_END"

if (( status != 0 )); then
  echo "PHASE1_RESULT=FAIL_SOURCE_PROOF"
  exit "$status"
fi

echo "PHASE1_PG_DUMP_RAW_BEGIN"
(
  cd "$repo_root"
  PGSSLMODE=require bash ops/postgres_backup.sh "$dump"
) 2>&1 | tee "$workdir/pg_dump.log"
backup_rc=${PIPESTATUS[0]}
echo "phase1_pg_dump_exit=$backup_rc"
if (( backup_rc != 0 )); then
  echo "PHASE1_PG_DUMP_RAW_END"
  echo "PHASE1_RESULT=FAIL_DUMP"
  exit "$backup_rc"
fi

echo "phase1_dump_size_bytes=$(stat -c%s "$dump")"
printf 'phase1_dump_sha256='
sha256sum "$dump" | awk '{print $1}'
echo "PHASE1_PG_DUMP_RAW_END"

echo "PHASE1_PG_RESTORE_RAW_BEGIN"
(
  cd "$repo_root"
  PGSSLMODE=require \
  RESTORE_DATABASE_URL="$SUPABASE_DATABASE_URL" \
  CONFIRM_RESTORE=RESTORE_STRANGERTALKS \
  bash ops/postgres_restore.sh "$dump"
) 2>&1 | tee "$workdir/pg_restore.log"
restore_rc=${PIPESTATUS[0]}
echo "phase1_pg_restore_exit=$restore_rc"
echo "PHASE1_PG_RESTORE_RAW_END"
if (( restore_rc != 0 )); then status=1; fi

PGSSLMODE=require psql "$SUPABASE_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c \
  "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" >"$target_tables"
target_tables_rc=$?
echo "phase1_target_table_inventory_exit=$target_tables_rc"
if (( target_tables_rc != 0 )); then status=1; fi

echo "PHASE1_TARGET_TABLES_BEGIN"
cat "$target_tables"
echo "PHASE1_TARGET_TABLES_END"

write_counts "$SUPABASE_DATABASE_URL" "$target_tables" "$target_counts"
target_counts_rc=$?
echo "phase1_target_row_counts_exit=$target_counts_rc"
if (( target_counts_rc != 0 )); then status=1; fi

echo "PHASE1_ROW_COUNT_COMPARISON_BEGIN"
printf 'table\tsource_rows\ttarget_rows\tmatch\n'
row_counts_match=true
while IFS=$'\t' read -r table_name source_rows target_rows; do
  row_match=false
  if [[ "$source_rows" == "$target_rows" ]]; then row_match=true; fi
  if [[ "$row_match" != true ]]; then row_counts_match=false; fi
  printf '%s\t%s\t%s\t%s\n' "$table_name" "$source_rows" "$target_rows" "$row_match"
done < <(join -t $'\t' -a1 -a2 -e MISSING -o '0,1.2,2.2' "$source_counts" "$target_counts")
echo "phase1_row_counts_match=$row_counts_match"
echo "PHASE1_ROW_COUNT_COMPARISON_END"
if [[ "$row_counts_match" != true ]]; then status=1; fi

echo "PHASE1_TABLE_SET_DIFF_BEGIN"
if diff -u "$source_tables" "$target_tables"; then
  echo "phase1_table_sets_match=true"
else
  echo "phase1_table_sets_match=false"
  status=1
fi
echo "PHASE1_TABLE_SET_DIFF_END"

PGSSLMODE=require psql "$SUPABASE_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c "$constraint_sql" | sort >"$target_constraints"
target_constraints_rc=${PIPESTATUS[0]}
echo "phase1_target_constraints_exit=$target_constraints_rc"
if (( target_constraints_rc != 0 )); then status=1; fi

echo "PHASE1_CONSTRAINT_DIFF_BEGIN"
if diff -u "$source_constraints" "$target_constraints"; then
  echo "phase1_constraint_sets_match=true"
  echo "phase1_constraint_count=$(wc -l <"$source_constraints" | tr -d ' ')"
else
  echo "phase1_constraint_sets_match=false"
  status=1
fi
echo "PHASE1_CONSTRAINT_DIFF_END"

PGSSLMODE=require psql "$SUPABASE_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -c \
  "SELECT version::text FROM public.schema_migrations ORDER BY version;" >"$target_migrations"
target_migrations_rc=$?
echo "phase1_target_schema_migrations_exit=$target_migrations_rc"
if (( target_migrations_rc != 0 )); then status=1; fi

echo "PHASE1_SCHEMA_MIGRATIONS_COMPARISON_BEGIN"
echo "source_versions:"
cat "$source_migrations"
echo "target_versions:"
cat "$target_migrations"
if diff -u "$source_migrations" "$target_migrations"; then
  echo "phase1_schema_migrations_match=true"
else
  echo "phase1_schema_migrations_match=false"
  status=1
fi
echo "PHASE1_SCHEMA_MIGRATIONS_COMPARISON_END"

echo "PHASE1_TARGET_SIZE_AFTER_RESTORE_BEGIN"
PGSSLMODE=require psql "$SUPABASE_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F $'\t' -c \
  "WITH s AS (SELECT pg_database_size(current_database())::bigint AS bytes) SELECT current_database(), bytes, pg_size_pretty(bytes) FROM s;"
target_size_rc=$?
echo "phase1_target_size_query_exit=$target_size_rc"
if (( target_size_rc != 0 )); then status=1; fi
echo "PHASE1_TARGET_SIZE_AFTER_RESTORE_END"

echo "PHASE1_ECTO_POSTGREX_TLS_BEGIN"
ecto_expr='Application.load(:strangertalks_new); config = Application.fetch_env!(:strangertalks_new, StrangertalksNew.Repo); IO.puts("phase1_ecto_ssl_config=#{inspect(Keyword.get(config, :ssl))}"); {:ok, _, _} = Ecto.Migrator.with_repo(StrangertalksNew.Repo, fn repo -> result = Ecto.Adapters.SQL.query!(repo, "SELECT current_database(), ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid()", []); IO.inspect(result.rows, label: "phase1_ecto_pg_stat_ssl"); case result.rows do [[database, true, tls_version, cipher, bits]] -> IO.puts("phase1_ecto_tls_negotiated=true database=#{database} tls_version=#{tls_version} cipher=#{cipher} bits=#{bits}"); other -> IO.puts("phase1_ecto_tls_negotiated=unconfirmed rows=#{inspect(other)}") end end)'
DATABASE_URL="$SUPABASE_DATABASE_URL" "$release_bin" eval "$ecto_expr" 2>&1 | tee "$workdir/ecto_tls.log"
ecto_tls_rc=${PIPESTATUS[0]}
echo "phase1_ecto_tls_exit=$ecto_tls_rc"
if (( ecto_tls_rc != 0 )); then status=1; fi
if ! grep -q '^phase1_ecto_ssl_config=true$' "$workdir/ecto_tls.log"; then
  echo "phase1_ecto_ssl_config_proven=false"
  status=1
else
  echo "phase1_ecto_ssl_config_proven=true"
fi
if grep -q '^phase1_ecto_tls_negotiated=true ' "$workdir/ecto_tls.log"; then
  echo "phase1_ecto_tls_negotiation_proven=true"
else
  echo "phase1_ecto_tls_negotiation_proven=false"
  status=1
fi
echo "PHASE1_ECTO_POSTGREX_TLS_END"

if [[ "$DATABASE_URL" == "$source_url_at_start" ]]; then
  echo "phase1_production_database_url_unchanged=true"
else
  echo "phase1_production_database_url_unchanged=false"
  status=1
fi

echo "phase1_utc_finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( status == 0 )); then
  echo "PHASE1_RESULT=PASS"
else
  echo "PHASE1_RESULT=FAIL"
fi
exit "$status"
