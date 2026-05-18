#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="two users sync interleaved issue events and converge with LWW edits"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

interleaved="$ROOT/interleaved-users"
mkdir -p "$interleaved"
git -C "$interleaved" init --bare remote.git >/dev/null
init_repo "$interleaved/a"
init_repo "$interleaved/b"
configure_bob_signing "$interleaved/b"
git -C "$interleaved/a" remote add origin "$interleaved/remote.git"
git -C "$interleaved/b" remote add origin "$interleaved/remote.git"
(
  cd "$interleaved/a"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" >/dev/null
  gt acl grant bob maintainer >/dev/null
  gt issue open --title "Shared interleaved issue" --body "Initial shared body" >/dev/null
  shared_issue_id="$(json_field "$(gt issue list --json)" id)"
  [[ -n "$shared_issue_id" ]] || fail "expected shared issue id"
  printf '%s\n' "$shared_issue_id" > "$interleaved/shared_issue_id"
  gt sync --push-only >/dev/null
)
(
  cd "$interleaved/b"
  gt sync >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Shared interleaved issue"'
)
(
  cd "$interleaved/a"
  gt sync >/dev/null
)

(
  cd "$interleaved/a"
  gt issue open --title "Alice interleaved 1" >/dev/null
)
sleep 1
(
  cd "$interleaved/b"
  gt issue open --title "Bob interleaved 1" >/dev/null
)
sleep 1
(
  cd "$interleaved/a"
  gt issue open --title "Alice interleaved 2" >/dev/null
)
sleep 1
(
  cd "$interleaved/b"
  gt issue open --title "Bob interleaved 2" >/dev/null
)

(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/b"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 5
  assert_line_order "$issues" \
    '"title":"Bob interleaved 2"' \
    '"title":"Alice interleaved 2"' \
    '"title":"Bob interleaved 1"' \
    '"title":"Alice interleaved 1"' \
    '"title":"Shared interleaved issue"'
)
(
  cd "$interleaved/b"
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 5
  assert_line_order "$issues" \
    '"title":"Bob interleaved 2"' \
    '"title":"Alice interleaved 2"' \
    '"title":"Bob interleaved 1"' \
    '"title":"Alice interleaved 1"' \
    '"title":"Shared interleaved issue"'
)

shared_issue_id="$(cat "$interleaved/shared_issue_id")"
shared_issue_ref="#$(object_ref "$shared_issue_id")"
(
  cd "$interleaved/a"
  gt comment add issue "$shared_issue_ref" --body "Alice local comment" >/dev/null
)
sleep 1
(
  cd "$interleaved/b"
  gt comment add issue "$shared_issue_ref" --body "Bob local comment" >/dev/null
)
sleep 1
(
  cd "$interleaved/a"
  gt issue body "$shared_issue_ref" --body "Alice local edit" >/dev/null
  git rev-parse refs/gitomi/inbox/alice/laptop > "$interleaved/alice_edit_hash"
)
sleep 1
(
  cd "$interleaved/b"
  gt issue body "$shared_issue_ref" --body "Bob local edit" >/dev/null
  git rev-parse refs/gitomi/inbox/bob/desktop > "$interleaved/bob_edit_hash"
)
alice_edit_hash="$(cat "$interleaved/alice_edit_hash")"
bob_edit_hash="$(cat "$interleaved/bob_edit_hash")"
if [[ "$alice_edit_hash" > "$bob_edit_hash" ]]; then
  expected_body="Alice local edit"
else
  expected_body="Bob local edit"
fi

(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/b"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  gt sync >/dev/null
)
(
  cd "$interleaved/a"
  issue_show="$(gt issue show "$shared_issue_ref" --json)"
  comments="$(gt comment list issue "$shared_issue_ref" --json)"
  assert_contains "$issue_show" '"body":"'"$expected_body"'"'
  assert_line_count "$comments" 2
  assert_contains "$comments" '"body":"Alice local comment"'
  assert_contains "$comments" '"body":"Bob local comment"'
  printf '%s\n' "$issue_show" > "$interleaved/a_issue.json"
  printf '%s\n' "$comments" > "$interleaved/a_comments.json"
  gt fsck >/dev/null
)
(
  cd "$interleaved/b"
  issue_show="$(gt issue show "$shared_issue_ref" --json)"
  comments="$(gt comment list issue "$shared_issue_ref" --json)"
  assert_contains "$issue_show" '"body":"'"$expected_body"'"'
  assert_line_count "$comments" 2
  assert_contains "$comments" '"body":"Alice local comment"'
  assert_contains "$comments" '"body":"Bob local comment"'
  assert_equal "$(cat "$interleaved/a_issue.json")" "$issue_show" "expected user A and user B issue projections to match"
  assert_equal "$(cat "$interleaved/a_comments.json")" "$comments" "expected user A and user B comment projections to match"
  gt fsck >/dev/null
)

