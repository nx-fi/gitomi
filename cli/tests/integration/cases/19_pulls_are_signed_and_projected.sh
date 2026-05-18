#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="pulls are signed and projected"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

pulls_repo="$ROOT/pulls"
init_repo "$pulls_repo"
(
  cd "$pulls_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt pr create --title "First pull" -B main -H feature --body "Pull body" -d >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"open"'
  assert_contains "$pulls_json" '"title":"First pull"'
  assert_contains "$pulls_json" '"body":"Pull body"'
  assert_contains "$pulls_json" '"base_ref":"main"'
  assert_contains "$pulls_json" '"head_ref":"feature"'
  assert_contains "$pulls_json" '"draft":true'
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"
  pull_ref="#$(object_ref "$pull_id")"
  pull_show="$(gt pr view "$pull_ref")"
  assert_contains "$pull_show" "id:         $pull_id"
  assert_contains "$pull_show" "base:       main"
  assert_contains "$pull_show" "head:       feature"
  assert_contains "$pull_show" "draft:      true"
  assert_contains "$pull_show" "Pull body"
  pull_show_json="$(gt pr view "$pull_ref" --json)"
  assert_line_count "$pull_show_json" 1
  assert_contains "$pull_show_json" '"id":"'"$pull_id"'"'
  assert_contains "$pull_show_json" '"base_ref":"main"'
  assert_contains "$pull_show_json" '"head_ref":"feature"'
  gt pr comment "$pull_ref" --body "Pull comment" >/dev/null
  pull_comments="$(gt comment list pr "$pull_ref" --json)"
  assert_line_count "$pull_comments" 1
  assert_contains "$pull_comments" '"body":"Pull comment"'
  pull_comment_id="$(json_field "$pull_comments" id)"
  [[ -n "$pull_comment_id" ]] || fail "expected pull comment id from comment list"
  pull_comment_ref="comment:$(object_ref "$pull_comment_id")"
  gt pr react "$pull_ref" eyes >/dev/null
  pull_show_json="$(gt pr view "$pull_ref" --json)"
  assert_contains "$pull_show_json" '"reactions":[{'
  assert_contains "$pull_show_json" '"actors":["alice"]'
  gt comment react "$pull_comment_ref" +1 >/dev/null
  gt pr comment "$pull_ref" --reply "$pull_comment_ref" --body "Pull reply" >/dev/null
  pull_comments="$(gt comment list pr "$pull_ref" --json)"
  assert_line_count "$pull_comments" 2
  assert_contains "$pull_comments" '"body":"Pull reply"'
  assert_contains "$pull_comments" '"reply_parent_id":"'"$pull_comment_id"'"'
  assert_contains "$pull_comments" '"reactions":[{'
  gt pr comment "$pull_ref" --body "Line note" --file cli/src/pr.zig --side new --line 42 >/dev/null
  gt pr comment "$pull_ref" --body "Range note" --file cli/src/pr.zig --side old --start-line 10 --end-line 12 >/dev/null
  pull_comments="$(gt comment list pr "$pull_ref" --json)"
  assert_line_count "$pull_comments" 4
  assert_contains "$pull_comments" 'Review comment on `cli/src/pr.zig` (new line 42).'
  assert_contains "$pull_comments" 'Review comment on `cli/src/pr.zig` (old lines 10-12).'
  pull_agent="$(gt pr view "$pull_ref" --view agent)"
  assert_line_count "$pull_agent" 1
  assert_contains "$pull_agent" '"kind":"pull_request"'
  assert_contains "$pull_agent" '"comments":['
  assert_contains "$pull_agent" 'Range note'
  assert_contains "$pull_agent" '"timeline_events":['
  assert_contains "$pull_agent" '"cli_commands":{'
  assert_contains "$pull_agent" '"review_line":"gt pr comment #'
  pull_agent_with_diff="$(gt pr view "$pull_ref" --view agent --include-diff)"
  assert_line_count "$pull_agent_with_diff" 1
  assert_contains "$pull_agent_with_diff" '"diff_available":false'
  assert_contains "$pull_agent_with_diff" '"refresh_with_diff":"gt pr view #'
  pull_list_agent="$(gt pr list --view agent --state open --limit 5)"
  assert_line_count "$pull_list_agent" 1
  assert_contains "$pull_list_agent" '"kind":"pull_request_list"'
  assert_contains "$pull_list_agent" '"filters":{"state":"open"'
  assert_contains "$pull_list_agent" '"pull_requests":['
  assert_contains "$pull_list_agent" '"cli_commands":{'
  sleep 1
  gt pr title "$pull_ref" --title "Updated pull" >/dev/null
  gt pr base "$pull_ref" --base trunk >/dev/null
  gt pr label "$pull_ref" add review >/dev/null
  gt pr reviewer "$pull_ref" add alice >/dev/null
  mkdir -p src
  printf 'pull merge target\n' > src/pull-merge-target.txt
  git add src/pull-merge-target.txt
  git commit -m "Pull merge target" >/dev/null
  merge_target_oid="$(git rev-parse HEAD)"
  gt pr merge "$pull_ref" --target-oid "$merge_target_oid" >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"merged"'
  assert_contains "$pulls_json" '"title":"Updated pull"'
  assert_contains "$pulls_json" '"base_ref":"trunk"'
  assert_contains "$pulls_json" '"labels":["review"]'
  assert_contains "$pulls_json" '"reviewers":["alice"]'
  assert_contains "$pulls_json" '"target_oid":"'"$merge_target_oid"'"'
  gt fsck >/dev/null
)

