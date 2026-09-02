#!/usr/bin/env bash
set -euo pipefail

: "${EXPECTED_SHA:?EXPECTED_SHA must identify the exact candidate under verification}"

repo_root=$(git rev-parse --show-toplevel)
checked_out_sha=$(git -C "$repo_root" rev-parse HEAD)

echo "PRECOMMIT_SOURCE_SHA=$checked_out_sha"
test "$checked_out_sha" = "$EXPECTED_SHA"

initial_status=$(git -C "$repo_root" status --porcelain)
if [ -n "$initial_status" ]; then
  printf '%s\n' "$initial_status"
  echo "ISOLATED_PRECOMMIT_RESULT=BLOCKED_DIRTY_SOURCE"
  exit 2
fi

worktree_root=${RUNNER_TEMP:-/tmp}
worktree_dir="$worktree_root/strangertalks-precommit-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"

cleanup() {
  git -C "$repo_root" worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$worktree_dir"
git -C "$repo_root" worktree add --detach "$worktree_dir" "$EXPECTED_SHA"

if [ -d "$repo_root/deps" ]; then
  ln -s "$repo_root/deps" "$worktree_dir/deps"
fi

if [ -d "$repo_root/_build" ]; then
  ln -s "$repo_root/_build" "$worktree_dir/_build"
fi

(
  cd "$worktree_dir"
  test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"
  mix precommit
  echo "ISOLATED_PRECOMMIT_TESTED_SHA=$(git rev-parse HEAD)"
)

test "$(git -C "$repo_root" rev-parse HEAD)" = "$EXPECTED_SHA"

final_status=$(git -C "$repo_root" status --porcelain)
if [ -n "$final_status" ]; then
  printf '%s\n' "$final_status"
  echo "ISOLATED_PRECOMMIT_RESULT=SOURCE_MUTATED"
  exit 2
fi

echo "ISOLATED_PRECOMMIT_RESULT=PASS"
