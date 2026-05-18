#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="issue reducer applies signed updates"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

reducer="$ROOT/reducer"
init_repo "$reducer"
(
  cd "$reducer"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Original title" --body "Old body" --label bug --assignee alice >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"
  sleep 1
  gt issue title "$issue_ref" --title "Updated title" >/dev/null
  updated_body=$'Updated body first paragraph\n\nUpdated body second paragraph'
  gt issue body "$issue_ref" --body "$updated_body" >/dev/null
  body_update_commit="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  body_update_subject="$(git show -s --format=%s "$body_update_commit")"
  assert_contains "$body_update_subject" "issue.body_set #"
  body_update_event_body="$(git show -s --format=%b "$body_update_commit")"
  [[ "$body_update_event_body" == \{* ]] || fail "expected multiline issue body update commit body to start with JSON"$'\n'"$body_update_event_body"
  assert_contains "$body_update_event_body" '"event_type":"issue.body_set"'
  assert_contains "$body_update_event_body" '"body":"Updated body first paragraph\n\nUpdated body second paragraph"'
  gt issue close "$issue_ref" >/dev/null
  gt issue label "$issue_ref" remove bug >/dev/null
  gt issue assignee "$issue_ref" remove alice >/dev/null
  gt issue label "$issue_ref" add regression >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Updated title"'
  assert_contains "$issues" '"body":"Updated body first paragraph\n\nUpdated body second paragraph"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":[]'
  gt fsck >/dev/null
)

