#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="stale config seq is recovered before writing"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

seq_recovery="$ROOT/seq-recovery"
init_repo "$seq_recovery"
(
  cd "$seq_recovery"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Seq base" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id"
  write_gt_config "$REPO_ID" alice laptop 0
  gt issue title "#$(object_ref "$issue_id")" --title "Recovered seq" >/dev/null
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"seq":2'
  gt fsck >/dev/null
)

