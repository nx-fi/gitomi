#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="github import without options uses local gh current-repo context"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

github_gh="$ROOT/github-gh"
init_repo "$github_gh"
(
  cd "$github_gh"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  git remote add origin git@github.com:acme/current.git
  mkdir -p src
  printf 'gh fixture merge target\n' > src/gh-merge-target.txt
  git add src/gh-merge-target.txt
  git commit -m "GH fixture merge target" >/dev/null
  gh_fixture_merge_oid="$(git rev-parse HEAD)"
  fakebin="$PWD/fakebin"
  mkdir -p "$fakebin"
  write_bash_script "$fakebin/gh" <<'SH'
set -euo pipefail

printf '%s\n' "$*" >> "${GH_CALL_LOG:?}"
[[ "${1:-}" == "api" ]] || {
  echo "expected gh api" >&2
  exit 2
}

endpoint="${@: -1}"
case "$endpoint" in
  'repos/{owner}/{repo}/issues?state=all&per_page=100&page=1')
    cat <<'JSON'
[
  {
    "number": 43,
    "title": "Current repo issue",
    "body": "Imported through gh",
    "state": "open",
    "created_at": "2026-01-05T00:00:00Z",
    "comments": 1,
    "labels": [],
    "assignees": []
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/issues/43/comments?per_page=100&page=1')
    if [[ "${GH_FAIL_COMMENTS:-}" == "1" || "${GH_FAIL_ISSUE_COMMENTS:-}" == "1" ]]; then
      echo "issue comments endpoint failed" >&2
      exit 4
    fi
    cat <<'JSON'
[
  {
    "body": "Current repo comment",
    "created_at": "2026-01-05T01:00:00Z"
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/pulls?state=all&per_page=100&page=1')
    cat <<'JSON'
[
  {
    "number": 44,
    "title": "Current repo pull summary",
    "body": "Summary payload should not be imported",
    "state": "open",
    "created_at": "2026-01-06T00:00:00Z",
    "base": { "ref": "main" },
    "head": { "ref": "feature" },
    "draft": false
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/pulls/44')
    cat <<JSON
{
  "number": 44,
  "title": "Current repo pull",
  "body": "Imported pull through gh",
  "state": "closed",
  "created_at": "2026-01-06T00:00:00Z",
  "merged_at": "2026-01-06T02:00:00Z",
  "merge_commit_sha": "${GH_FIXTURE_MERGE_OID:?}",
  "user": { "login": "pull-author" },
  "comments": 1,
  "labels": [{ "name": "api" }],
  "assignees": [{ "login": "api-assignee" }],
  "requested_reviewers": [{ "login": "api-reviewer" }],
  "base": { "ref": "main" },
  "head": { "ref": "feature" },
  "draft": false,
  "commits": 2,
  "changed_files": 3,
  "additions": 12,
  "deletions": 5
}
JSON
    ;;
  'repos/{owner}/{repo}/issues/44/comments?per_page=100&page=1')
    if [[ "${GH_FAIL_COMMENTS:-}" == "1" || "${GH_FAIL_PULL_COMMENTS:-}" == "1" ]]; then
      echo "pull comments endpoint failed" >&2
      exit 4
    fi
    cat <<'JSON'
[
  {
    "body": "Current repo pull comment",
    "created_at": "2026-01-06T01:00:00Z"
  }
]
JSON
    ;;
  'repos/{owner}/{repo}/projects?per_page=100')
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
    ;;
  *)
    echo "unexpected endpoint: $endpoint" >&2
    exit 3
    ;;
esac
SH
  export GH_CALL_LOG="$PWD/gh-calls.log"
  export GH_FIXTURE_MERGE_OID="$gh_fixture_merge_oid"
  set +e
  GH_FAIL_ISSUE_COMMENTS=1 PATH="$fakebin:$PATH" gt github import --rest >/tmp/github-import-issue-comment-failure.log 2>&1
  failed_status=$?
  set -e
  [[ "$failed_status" -ne 0 ]] || fail "expected github import to fail when issue comments fail"
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" "Current repo issue"
  pulls="$(gt pr list --json)"
  assert_not_contains "$pulls" "Current repo pull"
  : > "$GH_CALL_LOG"

  set +e
  GH_FAIL_PULL_COMMENTS=1 PATH="$fakebin:$PATH" gt github import --rest >/tmp/github-import-pull-comment-failure.log 2>&1
  failed_status=$?
  set -e
  [[ "$failed_status" -ne 0 ]] || fail "expected github import to fail when pull comments fail"
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Current repo issue"'
  pulls="$(gt pr list --json)"
  assert_not_contains "$pulls" "Current repo pull"
  : > "$GH_CALL_LOG"

  PATH="$fakebin:$PATH" gt github import --rest >/dev/null
  gh_calls="$(cat "$GH_CALL_LOG")"
  assert_contains "$gh_calls" "api --method GET"
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/issues?state=all&per_page=100&page=1'
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/pulls/44'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Current repo issue"'
  assert_contains "$issues" '"legacy_github_issue_number":43'
  pulls="$(gt pr list --json)"
  assert_contains "$pulls" '"title":"Current repo pull"'
  assert_contains "$pulls" '"state":"merged"'
  assert_not_contains "$pulls" "Summary payload should not be imported"
  assert_contains "$pulls" '"source_author":"pull-author"'
  assert_contains "$pulls" '"labels":["api"]'
  assert_contains "$pulls" '"assignees":["api-assignee"]'
  assert_contains "$pulls" '"reviewers":["api-reviewer"]'
  assert_contains "$pulls" '"commit_count":2'
  assert_contains "$pulls" '"changed_files":3'
  assert_contains "$pulls" '"additions":12'
  assert_contains "$pulls" '"deletions":5'
  assert_contains "$pulls" '"legacy_github_pull_number":44'
  events="$(gt events list --json)"
  assert_contains "$events" '"event_type":"comment.added"'
  : > "$GH_CALL_LOG"
  GH_FAIL_COMMENTS=1 PATH="$fakebin:$PATH" gt github import --rest >/dev/null
  gh_calls="$(cat "$GH_CALL_LOG")"
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/issues?state=all&per_page=100&page=1'
  assert_contains "$gh_calls" 'repos/{owner}/{repo}/pulls?state=all&per_page=100&page=1'
  assert_not_contains "$gh_calls" 'repos/{owner}/{repo}/pulls/44'
  assert_not_contains "$gh_calls" 'repos/{owner}/{repo}/issues/43/comments?per_page=100&page=1'
  assert_not_contains "$gh_calls" 'repos/{owner}/{repo}/issues/44/comments?per_page=100&page=1'
  gt fsck >/dev/null
)
