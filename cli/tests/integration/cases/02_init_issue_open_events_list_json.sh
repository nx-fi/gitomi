#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="init, issue open, events list --json"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

single="$ROOT/single"
init_repo "$single"
(
  cd "$single"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "First issue" --body "Body text" --label bug --assignee alice >/dev/null
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 1
  assert_contains "$json" '"event_type":"issue.opened"'
  assert_contains "$json" '"object_kind":"issue"'
  assert_contains "$json" '"actor_principal":"alice"'
  assert_contains "$json" '"actor_device":"laptop"'
  assert_contains "$json" '"seq":1'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"open"'
  assert_contains "$issues" '"title":"First issue"'
  assert_contains "$issues" '"labels":["bug"]'
  assert_contains "$issues" '"assignees":["alice"]'
  issue_id="$(json_field "$issues" id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from issue list"
  issue_show="$(gt issue show "#$(object_ref "$issue_id")")"
  assert_contains "$issue_show" "id:        $issue_id"
  assert_contains "$issue_show" "labels:    bug"
  assert_contains "$issue_show" "assignees: alice"
  assert_contains "$issue_show" "Body text"
  issue_show_json="$(gt issue show "#$(object_ref "$issue_id")" --json)"
  assert_line_count "$issue_show_json" 1
  assert_contains "$issue_show_json" '"id":"'"$issue_id"'"'
  assert_contains "$issue_show_json" '"body":"Body text"'
  gt fsck >/dev/null
)

