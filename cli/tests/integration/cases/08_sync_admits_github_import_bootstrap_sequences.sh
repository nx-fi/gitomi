#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync admits github import bootstrap sequences"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

github_io="$ROOT/github-io"
seed_github_legacy_import "$github_io"
github_sync="$ROOT/github-sync"
mkdir -p "$github_sync"
git -C "$github_sync" init --bare remote.git >/dev/null
init_repo "$github_sync/replica"
git -C "$github_io" remote add import-sync "$github_sync/remote.git"
git -C "$github_sync/replica" remote add origin "$github_sync/remote.git"
(
  cd "$github_io"
  gt sync --remote import-sync --push-only >/dev/null
  write_gt_config "$REPO_ID" import-bot github 0
  gt sync --remote import-sync --push-only >/dev/null
)
(
  cd "$github_sync/replica"
  gt sync --pull-only >/dev/null
  issues="$(gt issue list --json)"
  assert_contains "$issues" '"title":"Legacy bug"'
  pulls="$(gt pr list --json)"
  assert_contains "$pulls" '"title":"Legacy PR"'
  events="$(gt events list --json)"
  delegation_line="$(printf '%s\n' "$events" | grep 'acl.delegation_granted')"
  assert_contains "$delegation_line" '"actor_principal":"alice"'
  assert_contains "$delegation_line" '"domain_status":"accepted"'
  import_line="$(printf '%s\n' "$events" | grep 'issue.opened' | grep 'import-bot')"
  assert_contains "$import_line" '"domain_status":"accepted"'
  gt fsck >/dev/null
)
