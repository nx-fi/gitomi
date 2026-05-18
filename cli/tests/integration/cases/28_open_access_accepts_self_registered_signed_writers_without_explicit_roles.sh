#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="open access accepts self-registered signed writers without explicit roles"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

open_rbac="$ROOT/open-rbac"
init_repo "$open_rbac"
(
  cd "$open_rbac"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop --access open >/dev/null
  genesis_manifest="$(git show refs/gitomi/genesis:.gitomi/genesis.json)"
  assert_contains "$genesis_manifest" '"access":{"mode":"open"}'
  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$PWD"
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt issue open --title "Open access Bob issue" >/dev/null
  events="$(gt events list --json)"
  identity_line="$(printf '%s\n' "$events" | grep 'identity.device_added' | grep 'bob')"
  assert_contains "$identity_line" '"domain_status":"accepted"'
  bob_line="$(printf '%s\n' "$events" | grep 'Open access Bob issue')"
  assert_contains "$bob_line" '"actor_principal":"bob"'
  assert_contains "$bob_line" '"domain_status":"accepted"'
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Open access Bob issue"'
  gt fsck >/dev/null
)

