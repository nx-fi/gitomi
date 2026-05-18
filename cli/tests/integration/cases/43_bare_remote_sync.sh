#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="bare-remote sync"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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
  gt sync --pull-only >/dev/null
  refs="$(gt refs)"
  assert_contains "$refs" "refs/gitomi/staging/origin/inbox/alice/laptop"
  assert_contains "$refs" "refs/gitomi/inbox/alice/laptop"
  json="$(gt events list --json)"
  assert_file ".git/gitomi/index.sqlite"
  assert_line_count "$json" 1
  assert_contains "$json" '"actor_device":"laptop"'
  issues="$(gt issue list --json)"
  assert_line_count "$issues" 1
  assert_contains "$issues" '"title":"Synced issue"'
  gt fsck >/dev/null
)

