#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="default push publishes only configured actor inbox ref"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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
  gt sync --pull-only >/dev/null
  write_gt_config "$REPO_ID" bob desktop 0
  configure_bob_signing "$scope_root/replica"
  gt issue open --title "Bob local issue" >/dev/null
  gt sync --remote backup --push-only >/dev/null
)
backup_refs="$(git --git-dir="$scope_root/backup.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$backup_refs" "refs/gitomi/genesis"
assert_contains "$backup_refs" "refs/gitomi/inbox/bob/desktop"
assert_not_contains "$backup_refs" "refs/gitomi/inbox/alice/laptop"
assert_not_contains "$backup_refs" "refs/gitomi/staging"
assert_not_contains "$backup_refs" "refs/gitomi/quarantine"
assert_not_contains "$backup_refs" "refs/gitomi/snapshots"
assert_not_contains "$backup_refs" "refs/gitomi/runs"

