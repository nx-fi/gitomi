#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="RBAC pre-flight blocks unauthorized ACL and identity events"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

rbac_preflight="$ROOT/rbac-preflight"
init_repo "$rbac_preflight"
(
  cd "$rbac_preflight"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt acl grant bob maintainer >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$PWD"

  if gt acl grant charlie owner >acl-escalate.out 2>&1; then
    fail "expected non-owner ACL grant owner to fail pre-flight"
  fi
  assert_contains "$(cat acl-escalate.out)" "refusing to grant owner; current actor bob has role maintainer"

  if gt acl grant charlie reader >acl-grant.out 2>&1; then
    fail "expected non-owner ACL grant to fail pre-flight"
  fi
  assert_contains "$(cat acl-grant.out)" "owner role required to grant ACL roles"

  if gt acl revoke alice >acl-revoke.out 2>&1; then
    fail "expected non-owner ACL revoke to fail pre-flight"
  fi
  assert_contains "$(cat acl-revoke.out)" "owner role required to revoke ACL roles"

  if gt identity add-device charlie phone >identity-add.out 2>&1; then
    fail "expected non-owner identity add-device to fail pre-flight"
  fi
  assert_contains "$(cat identity-add.out)" "owner role required to add identity devices"

  if gt identity revoke-device alice laptop >identity-revoke.out 2>&1; then
    fail "expected non-owner identity revoke-device to fail pre-flight"
  fi
  assert_contains "$(cat identity-revoke.out)" "owner role required to revoke identity devices"

  events="$(gt events list --json)"
  assert_line_count "$events" 2
  assert_not_contains "$events" "charlie"
  assert_not_contains "$events" "acl.role_revoked alice"
  assert_not_contains "$events" "identity.device_revoked alice/laptop"
)

