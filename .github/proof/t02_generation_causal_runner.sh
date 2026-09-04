#!/usr/bin/env bash
set -euo pipefail

PRODUCT_SHA=e3e86c736ca6ef911bd0023c4877ac68642a48b9
OLD_FIX_LAB_SHA=06724eb3068df69efdbfd065940f2de011b4a57a
OLD_DIAGNOSTIC_BLOB=cc717de18b6341d86ff834e86ae790ca910a7dfa
TARGET=lib/strangertalks_new/conversation_lifecycle/conversation_server.ex
DIAG=test/strangertalks_new/t02_recovery_convergence_hostile_test.exs
PROBE=test/strangertalks_new/t02_generation_timeline_probe_test.exs
PROBE_SRC=.github/proof/t02_generation_timeline_probe_test.exs
OUT=/tmp/t02-causal
mkdir -p "$OUT"
cp "$PROBE_SRC" "$OUT/probe.exs"

export MIX_ENV=test
export STRANGERTALKS_LOCAL_DB_USER=strangertalks_local
export STRANGERTALKS_LOCAL_DB_PASSWORD=strangertalks_test

cleanup() {
  docker rm -f t02-causal-pg >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker run -d --name t02-causal-pg \
  -e POSTGRES_USER=strangertalks_local \
  -e POSTGRES_PASSWORD=strangertalks_test \
  -e POSTGRES_DB=strangertalks_new_test \
  -p 5432:5432 postgres:16 > "$OUT/postgres-container.txt"

for _ in $(seq 1 60); do
  if docker exec t02-causal-pg pg_isready -U strangertalks_local -d strangertalks_new_test >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec t02-causal-pg pg_isready -U strangertalks_local -d strangertalks_new_test

git fetch --no-tags origin "$OLD_FIX_LAB_SHA"

run_test() {
  local lane="$1" name="$2" file="$3"
  local log="$OUT/${lane}-${name}.log"
  local start end rc
  start=$(date +%s%N)
  set +e
  mix test "$file" --seed 0 --trace 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  end=$(date +%s%N)
  echo "T02_CAUSAL_RESULT lane=$lane proof=$name seed=0 rc=$rc elapsed_ns=$((end-start))" | tee -a "$OUT/results.txt"
  return "$rc"
}

apply_temporary_patch() {
  python3 - <<'PY'
from pathlib import Path
p=Path('lib/strangertalks_new/conversation_lifecycle/conversation_server.ex')
s=p.read_text()
old='''        case DynamicSupervisor.start_child(
               StrangertalksNew.ConversationDynamicSupervisor,
               {__MODULE__, %{conversation_id: conversation_id}}
             ) do'''
new='''        child_spec =
          Supervisor.child_spec(
            {__MODULE__, %{conversation_id: conversation_id}},
            restart: :temporary
          )

        case DynamicSupervisor.start_child(
               StrangertalksNew.ConversationDynamicSupervisor,
               child_spec
             ) do'''
if s.count(old) != 1:
    raise SystemExit(f'V2 patch anchor count={s.count(old)}')
p.write_text(s.replace(old,new,1))
PY
}

for lane in control temporary; do
  echo "===== LANE $lane =====" | tee -a "$OUT/results.txt"
  git reset --hard "$PRODUCT_SHA"
  git clean -fd
  test "$(git rev-parse HEAD)" = "$PRODUCT_SHA"
  git show "$OLD_FIX_LAB_SHA:test/strangertalks_new/t02_recovery_convergence_hostile_test.exs" > "$DIAG"
  cp "$OUT/probe.exs" "$PROBE"
  test "$(git hash-object "$DIAG")" = "$OLD_DIAGNOSTIC_BLOB"

  for f in \
    runtime_restart_reconciliation_test.exs \
    runtime_terminal_contract_test.exs \
    f_x07_canonical_terminal_truth_test.exs \
    team3_recovery_coordination_test.exs \
    team4_safety_boundary_test.exs; do
    test -f "test/strangertalks_new/$f"
  done

  if [ "$lane" = temporary ]; then
    apply_temporary_patch
  fi
  git diff --check

  delta=$(git diff --name-only -- lib config mix.exs mix.lock | sort)
  echo "T02_CAUSAL_DELTA lane=$lane delta=$delta" | tee -a "$OUT/results.txt"
  if [ "$lane" = control ]; then
    test -z "$delta"
  else
    test "$delta" = "$TARGET"
    grep -Fq 'restart: :temporary' "$TARGET"
  fi

  echo "T02_CAUSAL_IDENTITY lane=$lane sha=$(git rev-parse HEAD) tree=$(git rev-parse HEAD^{tree}) diagnostic=$(git hash-object "$DIAG")" | tee -a "$OUT/results.txt"

  mix local.hex --force
  mix local.rebar --force
  mix deps.get
  mix ecto.drop --quiet || true
  mix ecto.create --quiet
  mix ecto.migrate
  mix compile --warnings-as-errors
  echo "T02_CAUSAL_PREFLIGHT lane=$lane db_migrate_compile=PASS" | tee -a "$OUT/results.txt"

  TRACE_LANE="$lane" run_test "$lane" timeline "$PROBE"

  if run_test "$lane" hostile "$DIAG"; then
    hostile_rc=0
  else
    hostile_rc=$?
  fi

  declare -A file_rc=()
  for spec in \
    "f1:test/strangertalks_new/runtime_restart_reconciliation_test.exs" \
    "f2:test/strangertalks_new/runtime_terminal_contract_test.exs" \
    "f3:test/strangertalks_new/f_x07_canonical_terminal_truth_test.exs" \
    "f4:test/strangertalks_new/team3_recovery_coordination_test.exs" \
    "f5:test/strangertalks_new/team4_safety_boundary_test.exs"; do
    name=${spec%%:*}
    file=${spec#*:}
    if run_test "$lane" "$name" "$file"; then
      file_rc[$name]=0
    else
      file_rc[$name]=$?
    fi
  done

  if [ "${file_rc[f1]}" -eq 0 ] && [ "${file_rc[f2]}" -eq 0 ] && [ "${file_rc[f3]}" -eq 0 ] && [ "${file_rc[f4]}" -eq 0 ] && [ "${file_rc[f5]}" -eq 0 ]; then
    start=$(date +%s%N)
    set +e
    mix test \
      test/strangertalks_new/runtime_restart_reconciliation_test.exs \
      test/strangertalks_new/runtime_terminal_contract_test.exs \
      test/strangertalks_new/f_x07_canonical_terminal_truth_test.exs \
      test/strangertalks_new/team3_recovery_coordination_test.exs \
      test/strangertalks_new/team4_safety_boundary_test.exs \
      --seed 0 --trace 2>&1 | tee "$OUT/${lane}-bundle.log"
    bundle_rc=${PIPESTATUS[0]}
    set -e
    end=$(date +%s%N)
    echo "T02_CAUSAL_RESULT lane=$lane proof=bundle seed=0 rc=$bundle_rc elapsed_ns=$((end-start))" | tee -a "$OUT/results.txt"
  else
    bundle_rc=99
    echo "T02_CAUSAL_RESULT lane=$lane proof=bundle rc=NOT_ELIGIBLE" | tee -a "$OUT/results.txt"
  fi

  echo "T02_CAUSAL_SUMMARY lane=$lane hostile_rc=$hostile_rc f1=${file_rc[f1]} f2=${file_rc[f2]} f3=${file_rc[f3]} f4=${file_rc[f4]} f5=${file_rc[f5]} bundle_rc=$bundle_rc" | tee -a "$OUT/results.txt"
  test "$(git hash-object "$DIAG")" = "$OLD_DIAGNOSTIC_BLOB"
done

cat "$OUT/results.txt"
echo "T02_CAUSAL_RUNNER=COMPLETE"
