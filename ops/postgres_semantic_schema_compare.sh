#!/usr/bin/env bash
set -euo pipefail

source_url=${1:?usage: postgres_semantic_schema_compare.sh SOURCE_DATABASE_URL TARGET_DATABASE_URL [SCHEMA]}
target_url=${2:?usage: postgres_semantic_schema_compare.sh SOURCE_DATABASE_URL TARGET_DATABASE_URL [SCHEMA]}
schema=${3:-public}

if [[ ! "$schema" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "invalid schema identifier: $schema" >&2
  exit 2
fi

for command in psql pg_dump diff sha256sum mktemp; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 127
  }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

server_major() {
  psql "$1" -X -v ON_ERROR_STOP=1 -Atc \
    "SELECT current_setting('server_version_num')::integer / 10000"
}

source_major=$(server_major "$source_url")
target_major=$(server_major "$target_url")
echo "semantic_schema_source_server_major=$source_major"
echo "semantic_schema_target_server_major=$target_major"

if [[ "$source_major" != "$target_major" ]]; then
  echo "semantic_schema_match=false"
  echo "semantic_schema_reason=server_major_mismatch"
  exit 1
fi

constraint_snapshot() {
  local database_url=$1
  local output=$2

  psql "$database_url" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' -c "
    SELECT
      n.nspname,
      COALESCE(rel.relname, typ.typname, ''),
      c.conname,
      c.contype,
      c.condeferrable,
      c.condeferred,
      c.convalidated,
      c.conislocal,
      c.coninhcount,
      c.connoinherit,
      COALESCE((
        SELECT string_agg(COALESCE(a.attname, '#' || key.attnum::text), ',' ORDER BY key.ord)
        FROM unnest(c.conkey) WITH ORDINALITY AS key(attnum, ord)
        LEFT JOIN pg_attribute AS a
          ON a.attrelid = c.conrelid AND a.attnum = key.attnum
      ), ''),
      COALESCE(refn.nspname || '.' || refrel.relname, ''),
      COALESCE((
        SELECT string_agg(COALESCE(a.attname, '#' || key.attnum::text), ',' ORDER BY key.ord)
        FROM unnest(c.confkey) WITH ORDINALITY AS key(attnum, ord)
        LEFT JOIN pg_attribute AS a
          ON a.attrelid = c.confrelid AND a.attnum = key.attnum
      ), ''),
      c.confupdtype,
      c.confdeltype,
      c.confmatchtype,
      COALESCE((
        SELECT string_agg(op.opr::regoperator::text, ',' ORDER BY op.ord)
        FROM unnest(c.conpfeqop) WITH ORDINALITY AS op(opr, ord)
      ), ''),
      COALESCE((
        SELECT string_agg(op.opr::regoperator::text, ',' ORDER BY op.ord)
        FROM unnest(c.conppeqop) WITH ORDINALITY AS op(opr, ord)
      ), ''),
      COALESCE((
        SELECT string_agg(op.opr::regoperator::text, ',' ORDER BY op.ord)
        FROM unnest(c.conffeqop) WITH ORDINALITY AS op(opr, ord)
      ), ''),
      COALESCE((
        SELECT string_agg(op.opr::regoperator::text, ',' ORDER BY op.ord)
        FROM unnest(c.conexclop) WITH ORDINALITY AS op(opr, ord)
      ), ''),
      COALESCE((
        SELECT string_agg(attnum::text, ',' ORDER BY ord)
        FROM unnest(c.confdelsetcols) WITH ORDINALITY AS x(attnum, ord)
      ), ''),
      COALESCE(ind.relname, ''),
      COALESCE(parent_n.nspname || '.' || parent_rel.relname || '.' || parent.conname, ''),
      regexp_replace(COALESCE(c.conbin::text, ''), ' :location -?[0-9]+', ' :location 0', 'g')
    FROM pg_constraint AS c
    JOIN pg_namespace AS n ON n.oid = c.connamespace
    LEFT JOIN pg_class AS rel ON rel.oid = c.conrelid
    LEFT JOIN pg_type AS typ ON typ.oid = c.contypid
    LEFT JOIN pg_class AS refrel ON refrel.oid = c.confrelid
    LEFT JOIN pg_namespace AS refn ON refn.oid = refrel.relnamespace
    LEFT JOIN pg_class AS ind ON ind.oid = c.conindid
    LEFT JOIN pg_constraint AS parent ON parent.oid = c.conparentid
    LEFT JOIN pg_class AS parent_rel ON parent_rel.oid = parent.conrelid
    LEFT JOIN pg_namespace AS parent_n ON parent_n.oid = parent_rel.relnamespace
    WHERE n.nspname = '$schema'
    ORDER BY 1, 2, 3, 4;
  " > "$output"
}

constraint_diagnostic() {
  local database_url=$1
  local output=$2

  psql "$database_url" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' -c "
    SELECT n.nspname, COALESCE(rel.relname, typ.typname, ''), c.conname,
           pg_get_constraintdef(c.oid, false)
    FROM pg_constraint AS c
    JOIN pg_namespace AS n ON n.oid = c.connamespace
    LEFT JOIN pg_class AS rel ON rel.oid = c.conrelid
    LEFT JOIN pg_type AS typ ON typ.oid = c.contypid
    WHERE n.nspname = '$schema'
    ORDER BY 1, 2, 3;
  " > "$output"
}

index_snapshot() {
  local database_url=$1
  local output=$2

  psql "$database_url" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' -c "
    SELECT
      n.nspname,
      tbl.relname,
      idx.relname,
      am.amname,
      i.indnatts,
      i.indnkeyatts,
      i.indisunique,
      i.indnullsnotdistinct,
      i.indisprimary,
      i.indisexclusion,
      i.indimmediate,
      i.indisclustered,
      i.indisvalid,
      i.indcheckxmin,
      i.indisready,
      i.indislive,
      i.indisreplident,
      COALESCE((
        SELECT string_agg(
          CASE WHEN key.attnum = 0 THEN '<expression>' ELSE COALESCE(a.attname, '#' || key.attnum::text) END ||
          CASE WHEN key.ord <= i.indnkeyatts THEN ':key' ELSE ':include' END,
          ',' ORDER BY key.ord
        )
        FROM unnest(i.indkey::smallint[]) WITH ORDINALITY AS key(attnum, ord)
        LEFT JOIN pg_attribute AS a
          ON a.attrelid = i.indrelid AND a.attnum = key.attnum
      ), ''),
      COALESCE((
        SELECT string_agg(opn.nspname || '.' || opc.opcname, ',' ORDER BY x.ord)
        FROM unnest(i.indclass::oid[]) WITH ORDINALITY AS x(opcoid, ord)
        JOIN pg_opclass AS opc ON opc.oid = x.opcoid
        JOIN pg_namespace AS opn ON opn.oid = opc.opcnamespace
      ), ''),
      COALESCE((
        SELECT string_agg(
          CASE WHEN x.collation_oid = 0 THEN '0' ELSE cn.nspname || '.' || coll.collname END,
          ',' ORDER BY x.ord
        )
        FROM unnest(i.indcollation::oid[]) WITH ORDINALITY AS x(collation_oid, ord)
        LEFT JOIN pg_collation AS coll ON coll.oid = x.collation_oid
        LEFT JOIN pg_namespace AS cn ON cn.oid = coll.collnamespace
      ), ''),
      COALESCE((
        SELECT string_agg(x.option::text, ',' ORDER BY x.ord)
        FROM unnest(i.indoption::smallint[]) WITH ORDINALITY AS x(option, ord)
      ), ''),
      regexp_replace(COALESCE(i.indexprs::text, ''), ' :location -?[0-9]+', ' :location 0', 'g'),
      regexp_replace(COALESCE(i.indpred::text, ''), ' :location -?[0-9]+', ' :location 0', 'g')
    FROM pg_index AS i
    JOIN pg_class AS idx ON idx.oid = i.indexrelid
    JOIN pg_class AS tbl ON tbl.oid = i.indrelid
    JOIN pg_namespace AS n ON n.oid = tbl.relnamespace
    JOIN pg_am AS am ON am.oid = idx.relam
    WHERE n.nspname = '$schema'
    ORDER BY 1, 2, 3;
  " > "$output"
}

index_diagnostic() {
  local database_url=$1
  local output=$2

  psql "$database_url" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' -c "
    SELECT n.nspname, tbl.relname, idx.relname,
           pg_get_indexdef(i.indexrelid, 0, false),
           COALESCE(pg_get_expr(i.indexprs, i.indrelid, false), ''),
           COALESCE(pg_get_expr(i.indpred, i.indrelid, false), '')
    FROM pg_index AS i
    JOIN pg_class AS idx ON idx.oid = i.indexrelid
    JOIN pg_class AS tbl ON tbl.oid = i.indrelid
    JOIN pg_namespace AS n ON n.oid = tbl.relnamespace
    WHERE n.nspname = '$schema'
    ORDER BY 1, 2, 3;
  " > "$output"
}

canonical_dump() {
  local database_url=$1
  local output=$2
  local raw="$output.raw"

  pg_dump --schema-only --no-owner --no-acl --schema="$schema" "$database_url" > "$raw"
  grep -Ev '^(--|\\restrict |\\unrestrict |$)' "$raw" > "$output"
}

constraint_snapshot "$source_url" "$work/source.constraints"
constraint_snapshot "$target_url" "$work/target.constraints"
constraint_diagnostic "$source_url" "$work/source.constraints.readable"
constraint_diagnostic "$target_url" "$work/target.constraints.readable"
index_snapshot "$source_url" "$work/source.indexes"
index_snapshot "$target_url" "$work/target.indexes"
index_diagnostic "$source_url" "$work/source.indexes.readable"
index_diagnostic "$target_url" "$work/target.indexes.readable"
canonical_dump "$source_url" "$work/source.schema"
canonical_dump "$target_url" "$work/target.schema"

for artifact in constraints indexes schema; do
  echo "semantic_schema_source_${artifact}_sha256=$(sha256sum "$work/source.$artifact" | awk '{print $1}')"
  echo "semantic_schema_target_${artifact}_sha256=$(sha256sum "$work/target.$artifact" | awk '{print $1}')"
done

mismatch=0

if ! diff -u --label source.constraints --label target.constraints \
  "$work/source.constraints" "$work/target.constraints"; then
  mismatch=1
  echo "SEMANTIC_SCHEMA_CONSTRAINT_READABLE_DIFF_BEGIN"
  diff -u --label source.constraints.readable --label target.constraints.readable \
    "$work/source.constraints.readable" "$work/target.constraints.readable" || true
  echo "SEMANTIC_SCHEMA_CONSTRAINT_READABLE_DIFF_END"
fi

if ! diff -u --label source.indexes --label target.indexes \
  "$work/source.indexes" "$work/target.indexes"; then
  mismatch=1
  echo "SEMANTIC_SCHEMA_INDEX_READABLE_DIFF_BEGIN"
  diff -u --label source.indexes.readable --label target.indexes.readable \
    "$work/source.indexes.readable" "$work/target.indexes.readable" || true
  echo "SEMANTIC_SCHEMA_INDEX_READABLE_DIFF_END"
fi

if ! diff -u --label source.same-major-schema --label target.same-major-schema \
  "$work/source.schema" "$work/target.schema"; then
  mismatch=1
fi

if [[ "$mismatch" -ne 0 ]]; then
  echo "semantic_schema_match=false"
  exit 1
fi

echo "semantic_schema_match=true"
