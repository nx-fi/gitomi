#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="issue edit batches multiple updates"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

issue_edit="$ROOT/issue-edit"
init_repo "$issue_edit"
(
  cd "$issue_edit"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Batch original" --body "Old body" --label bug --assignee alice >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"
  sleep 1
  gt issue edit "$issue_ref" --title "Batch title" --body "Batch body" --state closed --unlabel bug --label regression --unassign alice --assignee bob >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Batch title"'
  assert_contains "$issues" '"body":"Batch body"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":["bob"]'
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"event_type":"issue.updated"'
  gt fsck >/dev/null
)

