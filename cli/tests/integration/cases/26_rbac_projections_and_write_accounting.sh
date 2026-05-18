#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="RBAC projections and write accounting"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

rbac_repo="$ROOT/rbac"
init_repo "$rbac_repo"
(
  cd "$rbac_repo"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  genesis_manifest="$(git show refs/gitomi/genesis:.gitomi/genesis.json)"
  assert_contains "$genesis_manifest" '"access":{"mode":"closed"}'
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
  gt issue open --title "Reader cannot open" >/dev/null
  events="$(gt events list --json)"
  reader_line="$(printf '%s\n' "$events" | grep 'Reader cannot open')"
  assert_contains "$reader_line" '"actor_principal":"bob"'
  assert_contains "$reader_line" '"domain_status":"rejected"'
  assert_contains "$reader_line" '"rejection_reason":"insufficient_role"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Reader cannot open"'
)

