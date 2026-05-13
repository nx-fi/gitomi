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

append_issue_event() {
  local event_type="$1"
  local issue_id="$2"
  local payload="$3"
  local seq="$4"
  local event_uuid
  local idem
  local empty_tree
  local head
  local body
  local commit

  printf -v event_uuid '018f0000-0000-7000-8000-%012d' "$((100 + seq))"
  printf -v idem '018f0000-0000-7000-8000-%012d' "$((200 + seq))"
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  head="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  body="$(printf '{"$schema":"urn:gitomi:event:v1","repo_id":"%s","event_uuid":"%s","event_type":"%s","object":{"kind":"issue","id":"%s"},"idempotency_key":"%s","actor":{"principal":"alice","device":"laptop"},"seq":%s,"occurred_at":"2026-05-13T18:31:%02dZ","legacy":{},"payload":%s}' "$REPO_ID" "$event_uuid" "$event_type" "$issue_id" "$idem" "$seq" "$seq" "$payload")"
  commit="$(git commit-tree -S -p "$head" -m "$event_type" -m "$body" "$empty_tree")"
  git update-ref refs/gitomi/inbox/alice/laptop "$commit" "$head"
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
  append_issue_event "issue.title_set" "$issue_id" '{"title":"Updated title"}' 2
  append_issue_event "issue.state_set" "$issue_id" '{"state":"closed"}' 3
  append_issue_event "issue.label_removed" "$issue_id" '{"label":"bug"}' 4
  append_issue_event "issue.assignee_removed" "$issue_id" '{"assignee":"alice"}' 5
  append_issue_event "issue.label_added" "$issue_id" '{"label":"regression"}' 6
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Updated title"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":[]'
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
