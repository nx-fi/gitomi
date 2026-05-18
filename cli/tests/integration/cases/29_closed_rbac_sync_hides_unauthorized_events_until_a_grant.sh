#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="closed RBAC sync hides unauthorized events until a grant"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

closed_rbac="$ROOT/closed-rbac-sync"
mkdir -p "$closed_rbac"
git -C "$closed_rbac" init --bare remote.git >/dev/null
init_repo "$closed_rbac/alice"
init_repo "$closed_rbac/bob"
configure_bob_signing "$closed_rbac/bob"
git -C "$closed_rbac/alice" remote add origin "$closed_rbac/remote.git"
git -C "$closed_rbac/bob" remote add origin "$closed_rbac/remote.git"
(
  cd "$closed_rbac/alice"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop --access closed >/dev/null
  gt issue open --title "Alice visible issue" >/dev/null
  alice_issue_id="$(json_field "$(gt issue list --json)" id)"
  [[ -n "$alice_issue_id" ]] || fail "expected Alice issue id"
  printf '%s\n' "$alice_issue_id" > "$closed_rbac/alice_issue_id"
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/bob"
  gt sync --pull-only >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  gt issue open --title "Bob hidden issue" >/dev/null
  events="$(gt events list --json)"
  bob_line="$(printf '%s\n' "$events" | grep 'Bob hidden issue')"
  assert_contains "$bob_line" '"actor_principal":"bob"'
  assert_contains "$bob_line" '"domain_status":"rejected"'
  assert_contains "$bob_line" '"rejection_reason":"unauthorized_principal"'
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/alice"
  gt sync --pull-only >/dev/null
  events="$(gt events list --json)"
  bob_line="$(printf '%s\n' "$events" | grep 'Bob hidden issue')"
  assert_contains "$bob_line" '"domain_status":"rejected"'
  assert_contains "$bob_line" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Alice visible issue"'
  assert_not_contains "$issues" '"title":"Bob hidden issue"'
  gt acl grant bob reporter >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/bob"
  gt sync --pull-only >/dev/null
  alice_issue_id="$(cat "$closed_rbac/alice_issue_id")"
  alice_issue_ref="#$(object_ref "$alice_issue_id")"
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Alice visible issue"'
  gt comment add issue "$alice_issue_ref" --body "Bob visible comment" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$closed_rbac/alice"
  gt sync --pull-only >/dev/null
  alice_issue_id="$(cat "$closed_rbac/alice_issue_id")"
  alice_issue_ref="#$(object_ref "$alice_issue_id")"
  comments="$(gt comment list issue "$alice_issue_ref" --json)"
  assert_contains "$comments" '"body":"Bob visible comment"'
  events="$(gt events list --json)"
  comment_line="$(printf '%s\n' "$events" | grep 'comment.added' | grep 'bob')"
  assert_contains "$comment_line" '"domain_status":"accepted"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Bob hidden issue"'
  gt fsck >/dev/null
)

