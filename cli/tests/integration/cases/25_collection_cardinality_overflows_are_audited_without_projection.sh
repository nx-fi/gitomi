#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="collection cardinality overflows are audited without projection"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

collection_limits="$ROOT/collection-limits"
init_repo "$collection_limits"
(
  cd "$collection_limits"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null

  open_args=(issue open --title "Bounded issue")
  for n in $(seq 1 128); do
    open_args+=(--label "label$n" --assignee "user$n")
  done
  gt "${open_args[@]}" >/dev/null

  issue_json="$(gt issue list --json)"
  issue_id="$(json_field "$issue_json" id)"
  [[ -n "$issue_id" ]] || fail "expected bounded issue id"
  issue_ref="#$(object_ref "$issue_id")"

  add_labels=(issue edit "$issue_ref")
  for n in $(seq 129 256); do
    add_labels+=(--label "label$n")
  done
  gt "${add_labels[@]}" >/dev/null

  gt issue edit "$issue_ref" --title "Overflow issue title" --label label257 --assignee user129 >/dev/null
  events="$(gt events list --json)"
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"collection_limit_exceeded"'
  issue_show="$(gt issue show "$issue_ref")"
  assert_contains "$issue_show" "Bounded issue"
  assert_not_contains "$issue_show" "Overflow issue title"
  assert_not_contains "$issue_show" "label257"
  assert_not_contains "$issue_show" "user129"

  gt pr create --title "Bounded pull" --base main --head feature >/dev/null
  pull_json="$(gt pr list --json)"
  pull_id="$(json_field "$pull_json" id)"
  [[ -n "$pull_id" ]] || fail "expected bounded pull id"
  pull_ref="#$(object_ref "$pull_id")"

  add_reviewers=(pr edit "$pull_ref")
  for n in $(seq 1 128); do
    add_reviewers+=(--add-reviewer "reviewer$n")
  done
  gt "${add_reviewers[@]}" >/dev/null

  gt pr edit "$pull_ref" --title "Overflow pull title" --add-reviewer reviewer129 >/dev/null
  events="$(gt events list --json)"
  assert_contains "$events" '"rejection_reason":"collection_limit_exceeded"'
  pull_show="$(gt pr view "$pull_ref")"
  assert_contains "$pull_show" "Bounded pull"
  assert_not_contains "$pull_show" "Overflow pull title"
  assert_not_contains "$pull_show" "reviewer129"
  gt fsck >/dev/null
)

