#!/usr/bin/env bash
set -euo pipefail

GT_BIN="${1:?usage: integration.sh /path/to/gt}"
GT_BIN="$(cd "$(dirname "$GT_BIN")" && pwd)/$(basename "$GT_BIN")"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitomi-cli-it.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO_ID="018f0000-0000-7000-8000-000000000001"
KEY="$ROOT/signing_key"
ALLOWED_SIGNERS="$ROOT/allowed_signers"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"output was:"$'\n'"$haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"$'\n'"output was:"$'\n'"$haystack"
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

assert_line_count() {
  local text="$1"
  local expected="$2"
  local count
  count="$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "$expected" ]] || fail "expected $expected non-empty line(s), got $count"$'\n'"$text"
}

json_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | sed -n 's/.*"'"$field"'":"\([^"]*\)".*/\1/p' | head -n 1
}

configure_signing() {
  local repo="$1"
  git -C "$repo" config user.name "Alice"
  git -C "$repo" config user.email "alice@example.com"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config user.signingkey "$KEY"
  git -C "$repo" config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init >/dev/null
  configure_signing "$repo"
}

gt() {
  "$GT_BIN" "$@"
}

ssh-keygen -q -t ed25519 -N "" -C "alice@example.com" -f "$KEY"
awk '{ print "alice@example.com " $1 " " $2 }' "$KEY.pub" > "$ALLOWED_SIGNERS"

echo "integration: init, issue open, events list --json"
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
  gt fsck >/dev/null
)

echo "integration: issue reducer applies signed updates"
reducer="$ROOT/reducer"
init_repo "$reducer"
(
  cd "$reducer"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Original title" --body "Old body" --label bug --assignee alice >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#${issue_id:0:7}"
  sleep 1
  gt issue title "$issue_ref" --title "Updated title" >/dev/null
  gt issue body "$issue_ref" --body "Updated body" >/dev/null
  gt issue close "$issue_ref" >/dev/null
  gt issue label remove "$issue_ref" bug >/dev/null
  gt issue assignee remove "$issue_ref" alice >/dev/null
  gt issue label add "$issue_ref" regression >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Updated title"'
  assert_contains "$issues" '"body":"Updated body"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":[]'
  gt fsck >/dev/null
)

echo "integration: comments are signed and projected"
comments="$ROOT/comments"
init_repo "$comments"
(
  cd "$comments"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Commented issue" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#${issue_id:0:7}"
  gt comment add issue "$issue_ref" --body "Initial comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_line_count "$comments_json" 1
  assert_contains "$comments_json" '"body":"Initial comment"'
  assert_contains "$comments_json" '"redacted":false'
  comment_id="$(json_field "$comments_json" id)"
  [[ -n "$comment_id" ]] || fail "expected comment id from comment list"
  comment_ref="#${comment_id:0:7}"
  sleep 1
  gt comment edit "$comment_ref" --body "Edited comment" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"body":"Edited comment"'
  gt comment redact "$comment_ref" --reason "cleanup" >/dev/null
  comments_json="$(gt comment list issue "$issue_ref" --json)"
  assert_contains "$comments_json" '"redacted":true'
  assert_contains "$comments_json" '"body":""'
  gt fsck >/dev/null
)

echo "integration: pulls are signed and projected"
pulls_repo="$ROOT/pulls"
init_repo "$pulls_repo"
(
  cd "$pulls_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt pull open --title "First pull" --base main --head feature --body "Pull body" --draft >/dev/null
  pulls_json="$(gt pull list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"open"'
  assert_contains "$pulls_json" '"title":"First pull"'
  assert_contains "$pulls_json" '"body":"Pull body"'
  assert_contains "$pulls_json" '"base_ref":"main"'
  assert_contains "$pulls_json" '"head_ref":"feature"'
  assert_contains "$pulls_json" '"draft":true'
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"
  pull_ref="#${pull_id:0:7}"
  sleep 1
  gt pull title "$pull_ref" --title "Updated pull" >/dev/null
  gt pull base "$pull_ref" --base trunk >/dev/null
  gt pull label add "$pull_ref" review >/dev/null
  gt pull reviewer add "$pull_ref" alice >/dev/null
  gt pull merge "$pull_ref" --target-oid 0123456789abcdef0123456789abcdef01234567 >/dev/null
  pulls_json="$(gt pull list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"merged"'
  assert_contains "$pulls_json" '"title":"Updated pull"'
  assert_contains "$pulls_json" '"base_ref":"trunk"'
  assert_contains "$pulls_json" '"labels":["review"]'
  assert_contains "$pulls_json" '"reviewers":["alice"]'
  assert_contains "$pulls_json" '"target_oid":"0123456789abcdef0123456789abcdef01234567"'
  gt fsck >/dev/null
)

echo "integration: invalid signed event is not projected"
invalid="$ROOT/invalid"
init_repo "$invalid"
(
  cd "$invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000002","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000003"},"idempotency_key":"018f0000-0000-7000-8000-000000000004","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","legacy":{},"payload":{}}'
  bad_commit="$(git commit-tree -S -m "bad issue" -m "$bad_body" "$empty_tree")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 0
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  if gt fsck >fsck.out 2>&1; then
    fail "expected fsck to reject invalid signed event"
  fi
  assert_contains "$(cat fsck.out)" "issue.opened payload.title"
)

echo "integration: bare-remote sync"
sync_root="$ROOT/sync"
mkdir -p "$sync_root"
git -C "$sync_root" init --bare remote.git >/dev/null
init_repo "$sync_root/a"
init_repo "$sync_root/b"
git -C "$sync_root/a" remote add origin "$sync_root/remote.git"
git -C "$sync_root/b" remote add origin "$sync_root/remote.git"
(
  cd "$sync_root/a"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Synced issue" >/dev/null
  gt sync --push-only >/dev/null
)
remote_refs="$(git --git-dir="$sync_root/remote.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$remote_refs" "refs/gitomi/inbox/alice/laptop"
assert_not_contains "$remote_refs" "refs/gitomi/staging"
(
  cd "$sync_root/b"
  gt init --repo-id "$REPO_ID" --principal bob --device desktop >/dev/null
  gt sync --pull-only >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/staging/origin/inbox/alice/laptop"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 1
  assert_contains "$json" '"actor_device":"laptop"'
  gt fsck >/dev/null
)

echo "integration: two-device divergence"
div_root="$ROOT/divergence"
mkdir -p "$div_root"
git -C "$div_root" init --bare remote.git >/dev/null
init_repo "$div_root/laptop"
init_repo "$div_root/desktop"
git -C "$div_root/laptop" remote add origin "$div_root/remote.git"
git -C "$div_root/desktop" remote add origin "$div_root/remote.git"
(
  cd "$div_root/laptop"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Laptop issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$div_root/desktop"
  gt init --repo-id "$REPO_ID" --principal alice --device desktop >/dev/null
  gt issue open --title "Desktop issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$div_root/laptop"
  gt sync --pull-only >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  assert_contains "$refs" "refs/gitomi/inbox/alice/desktop"
  json="$(gt events list --json)"
  assert_line_count "$json" 2
  assert_contains "$json" '"actor_device":"laptop"'
  assert_contains "$json" '"actor_device":"desktop"'
  gt fsck >/dev/null
)

echo "integration: ok"
