#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="team RBAC grants inherited write access"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

team_rbac="$ROOT/team-rbac"
init_repo "$team_rbac"
(
  cd "$team_rbac"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt team create core --name "Core" --description "Core team" >/dev/null
  gt acl grant @core reporter >/dev/null
  gt identity add-device bob desktop --public-key "$BOB_PUBLIC_KEY" --fingerprint "$BOB_FINGERPRINT" --scheme ssh >/dev/null
  gt team add-member core bob >/dev/null
  alice_seq="$(sed -n 's/^seq = //p' .git/gitomi/config.toml)"

  teams="$(gt team list --json)"
  assert_contains "$teams" '"slug":"core"'
  assert_contains "$teams" '"principal":"@core"'
  assert_contains "$teams" '"role":"reporter"'
  assert_contains "$teams" '"members":"bob"'

  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$PWD"
  gt issue open --title "Bob inherited team issue" >/dev/null
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Bob inherited team issue"'

  write_gt_config "$REPO_ID" alice laptop "$alice_seq"
  configure_signing "$PWD"
  gt team remove-member core bob >/dev/null

  write_gt_config "$REPO_ID" bob desktop 1
  configure_bob_signing "$PWD"
  gt issue open --title "Bob after team removal" >/dev/null
  events="$(gt events list --json)"
  removed_line="$(printf '%s\n' "$events" | grep 'Bob after team removal')"
  assert_contains "$removed_line" '"domain_status":"rejected"'
  assert_contains "$removed_line" '"rejection_reason":"unauthorized_principal"'
  issues="$(gt issue list --json)"
  assert_not_contains "$issues" '"title":"Bob after team removal"'
)
