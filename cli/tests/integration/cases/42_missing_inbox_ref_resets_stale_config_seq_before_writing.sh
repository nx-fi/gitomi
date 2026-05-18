#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="missing inbox ref resets stale config seq before writing"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

seq_missing="$ROOT/seq-missing"
init_repo "$seq_missing"
(
  cd "$seq_missing"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  write_gt_config "$REPO_ID" alice laptop 99
  gt issue open --title "Missing inbox seq reset" >/dev/null
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"seq":1'
  gt fsck >/dev/null
)

