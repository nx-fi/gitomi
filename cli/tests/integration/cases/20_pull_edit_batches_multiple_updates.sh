#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="pull edit batches multiple updates"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

pull_edit="$ROOT/pull-edit"
init_repo "$pull_edit"
(
  cd "$pull_edit"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt pr create --title "Batch pull" --base main --head feature --body "Old body" >/dev/null
  pulls_json="$(gt pr list --json)"
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"
  pull_ref="#$(object_ref "$pull_id")"
  sleep 1
  gt pr edit "$pull_ref" -t "Batch pull updated" -b "New body" --state closed -B trunk --head feature-v2 --add-label review --add-assignee bob --add-reviewer alice >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"closed"'
  assert_contains "$pulls_json" '"title":"Batch pull updated"'
  assert_contains "$pulls_json" '"body":"New body"'
  assert_contains "$pulls_json" '"base_ref":"trunk"'
  assert_contains "$pulls_json" '"head_ref":"feature-v2"'
  assert_contains "$pulls_json" '"labels":["review"]'
  assert_contains "$pulls_json" '"assignees":["bob"]'
  assert_contains "$pulls_json" '"reviewers":["alice"]'
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"event_type":"pull.updated"'
  gt fsck >/dev/null
)

