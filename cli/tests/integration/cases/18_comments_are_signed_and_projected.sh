#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="comments are signed and projected"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

comments="$ROOT/comments"
init_repo "$comments"
(
  cd "$comments"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Commented issue" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#$(object_ref "$issue_id")"
  gt comment add issue "$issue_ref" --body "Initial comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_line_count "$comments_json" 1
  assert_contains "$comments_json" '"body":"Initial comment"'
  assert_contains "$comments_json" '"redacted":false'
  comment_id="$(json_field "$comments_json" id)"
  [[ -n "$comment_id" ]] || fail "expected comment id from comment list"
  comment_ref="comment:$(object_ref "$comment_id")"
  gt issue comment "$issue_ref" --body "Issue alias comment" >/dev/null
  gt issue close "$issue_ref" --body "Closing note" >/dev/null
  issues_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issues_json" '"state":"closed"'
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Issue alias comment"'
  assert_contains "$comments_json" '"body":"Closing note"'
  gt issue reopen "$issue_ref" --body "Reopening note" >/dev/null
  issues_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issues_json" '"state":"open"'
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Reopening note"'
  gt issue react "$issue_ref" +1 >/dev/null
  issue_show_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issue_show_json" '"reactions":[{'
  assert_contains "$issue_show_json" '"count":1'
  assert_contains "$issue_show_json" '"actors":["alice"]'
  gt issue unreact "$issue_ref" +1 >/dev/null
  issue_show_json="$(gt issue show "$issue_ref" --json)"
  assert_contains "$issue_show_json" '"reactions":[]'
  gt comment react "$comment_ref" heart >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"reactions":[{'
  assert_contains "$comments_json" '"actors":["alice"]'
  gt comment unreact "$comment_ref" heart >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"reactions":[]'
  gt comment reply "$comment_ref" --body "Reply comment" >/dev/null
  gt issue comment "$issue_ref" --reply "$comment_ref" --body "Issue alias reply" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_line_count "$comments_json" 6
  assert_contains "$comments_json" '"body":"Reply comment"'
  assert_contains "$comments_json" '"body":"Issue alias reply"'
  assert_contains "$comments_json" '"reply_parent_id":"'"$comment_id"'"'
  assert_contains "$comments_json" '"reply_parent_hash":'
  issue_agent="$(gt issue show "$issue_ref" --view agent)"
  assert_line_count "$issue_agent" 1
  assert_contains "$issue_agent" '"kind":"issue"'
  assert_contains "$issue_agent" '"comments":['
  assert_contains "$issue_agent" '"body":"Issue alias reply"'
  assert_contains "$issue_agent" '"timeline_events":['
  assert_contains "$issue_agent" '"cli_commands":{'
  assert_contains "$issue_agent" '"comment":"gt issue comment #'
  issue_list_agent="$(gt issue list --view agent --state open --limit 5)"
  assert_line_count "$issue_list_agent" 1
  assert_contains "$issue_list_agent" '"kind":"issue_list"'
  assert_contains "$issue_list_agent" '"filters":{"state":"open"'
  assert_contains "$issue_list_agent" '"issues":['
  assert_contains "$issue_list_agent" '"cli_commands":{'
  sleep 1
  gt comment edit "$comment_ref" --body "Edited comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Edited comment"'
  gt comment redact "$comment_ref" --reason "cleanup" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"redacted":true'
  assert_contains "$comments_json" '"body":""'
  sleep 1
  gt comment edit "$comment_ref" --body "Restored comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"redacted":true'
  assert_contains "$comments_json" '"body":""'
  latest_body_event="$(gt events list --json | grep '"event_type":"comment.body_set"' | tail -n 1)"
  assert_contains "$latest_body_event" '"domain_status":"rejected"'
  assert_contains "$latest_body_event" '"rejection_reason":"object_redacted"'
  gt fsck >/dev/null
)

