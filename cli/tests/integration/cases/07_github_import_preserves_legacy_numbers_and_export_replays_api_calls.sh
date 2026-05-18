#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="github import preserves legacy numbers and export replays API calls"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

github_io="$ROOT/github-io"
seed_github_legacy_import "$github_io"
(
  cd "$github_io"
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Legacy bug"'
  assert_contains "$issues" '"source_author":"octocat"'
  assert_contains "$issues" '"milestone":"v1.0"'
  assert_contains "$issues" '"labels":["bug","triage"]'
  assert_contains "$issues" '"projects":[{"project":"Roadmap","column":"Done"}]'
  assert_contains "$issues" '"legacy_github_issue_number":42'
  issue_show="$(gt issue show '#42')"
  assert_contains "$issue_show" "github:    #42"
  assert_contains "$issue_show" "source:    octocat"
  assert_contains "$issue_show" "milestone: v1.0"
  assert_contains "$issue_show" "projects:  Roadmap / Done"
  comments="$(gt comment list issue '#42' --json)"
  assert_contains "$comments" '"source_author":"commenter"'
  assert_contains "$comments" '"source_author":"reviewer"'
  assert_contains "$comments" '"reply_parent_id":'
  assert_contains "$comments" '"reply_parent_hash":'
  pulls="$(gt pr list --json)"
  assert_contains "$pulls" '"title":"Legacy PR"'
  assert_contains "$pulls" '"source_author":"ichewm"'
  assert_contains "$pulls" '"labels":["docs"]'
  assert_contains "$pulls" '"assignees":["bob"]'
  assert_contains "$pulls" '"reviewers":["Okenx"]'
  assert_contains "$pulls" '"commit_count":1'
  assert_contains "$pulls" '"changed_files":4'
  assert_contains "$pulls" '"additions":40'
  assert_contains "$pulls" '"deletions":4'
  assert_contains "$pulls" '"legacy_github_pull_number":7'
  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"acl.delegation_granted"'
  assert_contains "$events" '"actor_principal":"alice"'
  assert_contains "$events" '"actor_principal":"import-bot"'
  assert_contains "$events" '"event_type":"comment.added"'
  printf 'legacy refs\n' > src/legacy.txt
  git add src/legacy.txt
  git commit -m "Connect #42 and #7" >/dev/null
  code_commit="$(git rev-parse HEAD)"
  issue_show_json="$(gt issue show '#42' --json)"
  assert_contains "$issue_show_json" '"commit_references":["'"$code_commit"'"]'
  pull_show_json="$(gt pr view '#7' --json)"
  assert_contains "$pull_show_json" '"source_author":"ichewm"'
  assert_contains "$pull_show_json" '"reviewers":["Okenx"]'
  assert_contains "$pull_show_json" '"commit_count":1'
  assert_contains "$pull_show_json" '"changed_files":4'
  assert_contains "$pull_show_json" '"additions":40'
  assert_contains "$pull_show_json" '"deletions":4'
  assert_contains "$pull_show_json" '"commit_references":["'"$code_commit"'"]'
  replay="$(gt github export --repo acme/project --dry-run --reuse-legacy --rest)"
  assert_contains "$replay" "PATCH /repos/acme/project/issues/42"
  assert_contains "$replay" "PUT /repos/acme/project/pulls/7/merge"
  assert_contains "$replay" "POST /repos/acme/project/issues/42/comments"
  assert_contains "$replay" "POST /repos/acme/project/issues/7/comments"
  gt fsck >/dev/null
)
