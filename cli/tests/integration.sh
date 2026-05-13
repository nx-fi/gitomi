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

write_gt_config() {
  local repo_id="$1"
  local principal="$2"
  local device="$3"
  local seq="$4"
  cat > .git/gitomi/config.toml <<EOF
repo_id = "$repo_id"
principal = "$principal"
device = "$device"
seq = $seq
EOF
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
  issue_id="$(json_field "$issues" id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from issue list"
  issue_show="$(gt issue show "#${issue_id:0:7}")"
  assert_contains "$issue_show" "id:        $issue_id"
  assert_contains "$issue_show" "labels:    bug"
  assert_contains "$issue_show" "assignees: alice"
  assert_contains "$issue_show" "Body text"
  issue_show_json="$(gt issue show "#${issue_id:0:7}" --json)"
  assert_line_count "$issue_show_json" 1
  assert_contains "$issue_show_json" '"id":"'"$issue_id"'"'
  assert_contains "$issue_show_json" '"body":"Body text"'
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
  gt issue label "$issue_ref" remove bug >/dev/null
  gt issue assignee "$issue_ref" remove alice >/dev/null
  gt issue label "$issue_ref" add regression >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"state":"closed"'
  assert_contains "$issues" '"title":"Updated title"'
  assert_contains "$issues" '"body":"Updated body"'
  assert_contains "$issues" '"labels":["regression"]'
  assert_contains "$issues" '"assignees":[]'
  gt fsck >/dev/null
)

echo "integration: issue edit batches multiple updates"
issue_edit="$ROOT/issue-edit"
init_repo "$issue_edit"
(
  cd "$issue_edit"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Batch original" --body "Old body" --label bug --assignee alice >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id from event list"
  issue_ref="#${issue_id:0:7}"
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
  pull_ref="#${pull_id:0:7}"
  legacy_pulls_json="$(gt pull list --json)"
  assert_contains "$legacy_pulls_json" '"id":"'"$pull_id"'"'
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
  sleep 1
  gt pr title "$pull_ref" --title "Updated pull" >/dev/null
  gt pr base "$pull_ref" --base trunk >/dev/null
  gt pr label "$pull_ref" add review >/dev/null
  gt pr reviewer "$pull_ref" add alice >/dev/null
  gt pr merge "$pull_ref" --target-oid 0123456789abcdef0123456789abcdef01234567 >/dev/null
  pulls_json="$(gt pr list --json)"
  assert_line_count "$pulls_json" 1
  assert_contains "$pulls_json" '"state":"merged"'
  assert_contains "$pulls_json" '"title":"Updated pull"'
  assert_contains "$pulls_json" '"base_ref":"trunk"'
  assert_contains "$pulls_json" '"labels":["review"]'
  assert_contains "$pulls_json" '"reviewers":["alice"]'
  assert_contains "$pulls_json" '"target_oid":"0123456789abcdef0123456789abcdef01234567"'
  gt fsck >/dev/null
)

echo "integration: pull edit batches multiple updates"
pull_edit="$ROOT/pull-edit"
init_repo "$pull_edit"
(
  cd "$pull_edit"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt pr create --title "Batch pull" --base main --head feature --body "Old body" >/dev/null
  pulls_json="$(gt pr list --json)"
  pull_id="$(json_field "$pulls_json" id)"
  [[ -n "$pull_id" ]] || fail "expected pull id from pull list"
  pull_ref="#${pull_id:0:7}"
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

echo "integration: invalid signed event is not projected"
invalid="$ROOT/invalid"
init_repo "$invalid"
(
  cd "$invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000002","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000003"},"idempotency_key":"018f0000-0000-7000-8000-000000000004","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","causal":[],"related":[]},"legacy":{},"payload":{}}'
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

echo "integration: domain-invalid issue update is audited and not projected"
domain_invalid="$ROOT/domain-invalid"
init_repo "$domain_invalid"
(
  cd "$domain_invalid"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  missing_issue="018f0000-0000-7000-8000-000000000111"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000112","event_type":"issue.title_set","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000111"},"idempotency_key":"018f0000-0000-7000-8000-000000000113","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"No opener"}}'
  bad_commit="$(git commit-tree -S -m "issue.title_set #${missing_issue:0:7}" -m "$bad_body" "$empty_tree")"
  git update-ref refs/gitomi/inbox/alice/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"object_not_created"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  gt fsck >/dev/null
)

echo "integration: duplicate opened event is audited and only one object projects"
duplicate_open="$ROOT/duplicate-open"
init_repo "$duplicate_open"
(
  cd "$duplicate_open"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  issue_id="018f0000-0000-7000-8000-000000000211"
  body1='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000212","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000211"},"idempotency_key":"018f0000-0000-7000-8000-000000000213","actor":{"principal":"alice","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"First open"}}'
  first_commit="$(git commit-tree -S -m "issue.opened #${issue_id:0:7} First open" -m "$body1" "$empty_tree")"
  body2='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000214","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000211"},"idempotency_key":"018f0000-0000-7000-8000-000000000215","actor":{"principal":"alice","device":"laptop"},"seq":2,"occurred_at":"2026-05-13T18:31:00Z","parent_hashes":{"log":"'"$first_commit"'","causal":[],"related":["'"$first_commit"'"]},"legacy":{},"payload":{"title":"Second open"}}'
  second_commit="$(git commit-tree -S -m "issue.opened #${issue_id:0:7} Second open" -m "$body2" -p "$first_commit" "$empty_tree")"
  git update-ref refs/gitomi/inbox/alice/laptop "$second_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"domain_status":"accepted"'
  assert_contains "$events" '"rejection_reason":"duplicate_object_id"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  gt fsck >/dev/null
)

echo "integration: RBAC projections and CLI preflight"
rbac_repo="$ROOT/rbac"
init_repo "$rbac_repo"
(
  cd "$rbac_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  acl_json="$(gt acl list --json)"
  assert_contains "$acl_json" '"principal":"alice"'
  assert_contains "$acl_json" '"role":"owner"'
  identity_json="$(gt identity list --json)"
  assert_contains "$identity_json" '"principal":"alice"'
  assert_contains "$identity_json" '"device":"laptop"'
  assert_contains "$identity_json" '"active":true'
  if gt acl revoke alice >last-owner.out 2>&1; then
    fail "expected last owner revoke to fail authorization"
  fi
  assert_contains "$(cat last-owner.out)" "last owner"
  gt acl grant bob reader >/dev/null
  gt identity add-device bob desktop >/dev/null
  acl_json="$(gt acl list --json)"
  assert_contains "$acl_json" '"principal":"bob"'
  assert_contains "$acl_json" '"role":"reader"'
  write_gt_config "$REPO_ID" bob desktop 0
  if gt issue open --title "Reader cannot open" >preflight.out 2>&1; then
    fail "expected reader issue open to fail authorization"
  fi
  assert_contains "$(cat preflight.out)" "insufficient_role"
)

echo "integration: unauthorized remote event is audited and not projected"
unauthorized="$ROOT/unauthorized"
init_repo "$unauthorized"
(
  cd "$unauthorized"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  issue_id="018f0000-0000-7000-8000-000000000311"
  bad_body='{"$schema":"urn:gitomi:event:v1","repo_id":"018f0000-0000-7000-8000-000000000001","event_uuid":"018f0000-0000-7000-8000-000000000312","event_type":"issue.opened","object":{"kind":"issue","id":"018f0000-0000-7000-8000-000000000311"},"idempotency_key":"018f0000-0000-7000-8000-000000000313","actor":{"principal":"mallory","device":"laptop"},"seq":1,"occurred_at":"2026-05-13T18:30:59Z","parent_hashes":{"log":"","causal":[],"related":[]},"legacy":{},"payload":{"title":"Unauthorized"}}'
  bad_commit="$(git commit-tree -S -m "issue.opened #${issue_id:0:7} Unauthorized" -m "$bad_body" "$empty_tree")"
  git update-ref refs/gitomi/inbox/mallory/laptop "$bad_commit"
  events="$(gt events list --json)"
  assert_line_count "$events" 1
  assert_contains "$events" '"domain_status":"rejected"'
  assert_contains "$events" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 0
  gt fsck >/dev/null
)

echo "integration: stale config seq is recovered before writing"
seq_recovery="$ROOT/seq-recovery"
init_repo "$seq_recovery"
(
  cd "$seq_recovery"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Seq base" >/dev/null
  first_event="$(gt events list --json)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected issue id"
  write_gt_config "$REPO_ID" alice laptop 0
  gt issue title "#${issue_id:0:7}" --title "Recovered seq" >/dev/null
  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_contains "$events" '"seq":2'
  gt fsck >/dev/null
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
  gt sync >/dev/null
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

echo "integration: default push only publishes local actor inbox"
scope_root="$ROOT/sync-push-scope"
mkdir -p "$scope_root"
git -C "$scope_root" init --bare upstream.git >/dev/null
git -C "$scope_root" init --bare backup.git >/dev/null
init_repo "$scope_root/source"
init_repo "$scope_root/replica"
git -C "$scope_root/source" remote add origin "$scope_root/upstream.git"
git -C "$scope_root/replica" remote add origin "$scope_root/upstream.git"
git -C "$scope_root/replica" remote add backup "$scope_root/backup.git"
(
  cd "$scope_root/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Alice upstream issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$scope_root/replica"
  gt init --repo-id "$REPO_ID" --principal bob --device desktop >/dev/null
  gt sync --pull-only >/dev/null
  gt issue open --title "Bob backup issue" >/dev/null
  gt sync --remote backup --push-only >/dev/null
)
backup_refs="$(git --git-dir="$scope_root/backup.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$backup_refs" "refs/gitomi/inbox/bob/desktop"
assert_not_contains "$backup_refs" "refs/gitomi/inbox/alice/laptop"

echo "integration: causal parents are capped"
cap_repo="$ROOT/causal-cap"
init_repo "$cap_repo"
(
  cd "$cap_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Laptop root" >/dev/null
  for n in $(seq 1 40); do
    gt identity add-device alice "device$n" >/dev/null
  done
  for n in $(seq 1 40); do
    write_gt_config "$REPO_ID" alice "device$n" 0
    gt issue open --title "Device $n root" >/dev/null
    write_gt_config "$REPO_ID" alice laptop 0
  done
  write_gt_config "$REPO_ID" alice laptop 1
  first_event="$(gt events list --json --ref refs/gitomi/inbox/alice/laptop)"
  issue_id="$(json_field "$first_event" object_id)"
  [[ -n "$issue_id" ]] || fail "expected laptop issue id"
  gt issue title "$issue_id" --title "Laptop capped update" >/dev/null
  laptop_head="$(git rev-parse refs/gitomi/inbox/alice/laptop)"
  parents="$(git show -s --format=%P "$laptop_head")"
  parent_count="$(printf '%s\n' "$parents" | awk '{ print NF }')"
  [[ "$parent_count" == "33" ]] || fail "expected 33 parents (1 log + 32 causal), got $parent_count: $parents"
  gt fsck >/dev/null
)

echo "integration: run refs prune by retention count"
runs_repo="$ROOT/runs"
init_repo "$runs_repo"
(
  cd "$runs_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  empty_tree="$(git hash-object -w -t tree --stdin < /dev/null)"
  run1="$(git commit-tree -S -m "run one" "$empty_tree")"
  git update-ref refs/gitomi/runs/local/run1 "$run1"
  sleep 1
  run2="$(git commit-tree -S -m "run two" "$empty_tree")"
  git update-ref refs/gitomi/runs/local/run2 "$run2"
  gt runs prune --max-count 1 --max-age-days 0 --max-bytes 0 >/dev/null
  run_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/runs)"
  assert_line_count "$run_refs" 1
  assert_contains "$run_refs" "refs/gitomi/runs/local/run2"
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
