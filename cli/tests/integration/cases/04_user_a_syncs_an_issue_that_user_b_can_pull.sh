#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="user A syncs an issue that user B can pull"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

user_sync="$ROOT/user-sync"
mkdir -p "$user_sync"
git -C "$user_sync" init --bare remote.git >/dev/null
init_repo "$user_sync/a"
init_repo "$user_sync/b"
configure_bob_signing "$user_sync/b"
git -C "$user_sync/a" remote add origin "$user_sync/remote.git"
git -C "$user_sync/b" remote add origin "$user_sync/remote.git"
(
  cd "$user_sync/a"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "A synced issue" --body "A body" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$user_sync/b"
  gt sync --pull-only >/dev/null
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"title":"A synced issue"'
  assert_contains "$issues" '"body":"A body"'
  gt fsck >/dev/null
)

