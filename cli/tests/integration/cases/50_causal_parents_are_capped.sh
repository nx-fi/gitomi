#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="causal parents are capped"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

cap_repo="$ROOT/causal-cap"
init_repo "$cap_repo"
(
  cd "$cap_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Laptop root" >/dev/null
  for n in $(seq 1 40); do
    gt identity add-device alice "device$n" >/dev/null
  done
  for n in $(seq 1 40); do
    write_gt_config "$REPO_ID" alice "device$n" 0
    gt issue open --title "Device $n root" >/dev/null
    write_gt_config "$REPO_ID" alice laptop 0
  done
  write_gt_config "$REPO_ID" alice laptop 1
  first_event="$(gt events list --json --ref refs/gitomi/inbox/alice/laptop)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected laptop issue id"
  gt issue title "$issue_id" --title "Laptop capped update" >/dev/null
  laptop_head="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  parents="$(git show -s --format=%P "$laptop_head")"
  parent_count="$(printf '%s\n' "$parents" | awk '{ print NF }')"
  [[ "$parent_count" == "33" ]] || fail "expected 33 parents (1 log + 32 causal), got $parent_count: $parents"
  gt fsck >/dev/null
)

