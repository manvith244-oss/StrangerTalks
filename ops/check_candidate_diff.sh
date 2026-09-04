#!/usr/bin/env bash
set -euo pipefail

base_sha=${1:?usage: check_candidate_diff.sh BASE_SHA [CANDIDATE_SHA]}
candidate_sha=${2:-HEAD}

git cat-file -e "${base_sha}^{commit}"
git cat-file -e "${candidate_sha}^{commit}"

merge_base_sha=$(git merge-base "$base_sha" "$candidate_sha")

echo "CANDIDATE_BASE_SHA=$base_sha"
echo "CANDIDATE_SHA=$(git rev-parse "$candidate_sha")"
echo "CANDIDATE_MERGE_BASE_SHA=$merge_base_sha"

git diff --check "$base_sha...$candidate_sha"
git diff --check

echo "CANDIDATE_DIFF_INTEGRITY=PASS"
