#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="run refs prune by retention count"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

runs_repo="$ROOT/runs"
init_repo "$runs_repo"
(
  cd "$runs_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  run1="$(git commit-tree -S -m "run one" "$empty_tree")"
  git update-ref refs/gitomi/runs/local/run1 "$run1"
  sleep 1
  run2="$(git commit-tree -S -m "run two" "$empty_tree")"
  git update-ref refs/gitomi/runs/local/run2 "$run2"
  gt runs prune --max-count 1 --max-age-days 0 --max-bytes 0 >/dev/null
  run_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/runs)"
  assert_line_count "$run_refs" 1
  assert_contains "$run_refs" "refs/gitomi/runs/local/run2"
)

