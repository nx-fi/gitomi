#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="remote reset requires confirmation"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

clear_remote="$ROOT/clear-remote"
mkdir -p "$clear_remote"
git -C "$clear_remote" init --bare remote.git >/dev/null
init_repo "$clear_remote/source"
git -C "$clear_remote/source" remote add origin "$clear_remote/remote.git"
(
  cd "$clear_remote/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Remote clear issue" >/dev/null
  gt sync --push-only >/dev/null
  if printf 'no\n' | gt reset remote --remote origin >/dev/null 2>&1; then
    fail "expected remote reset to abort on mismatched confirmation"
  fi
)
remote_refs="$(git --git-dir="$clear_remote/remote.git" for-each-ref '--format=%(refname)' refs/gitomi)"
assert_contains "$remote_refs" "refs/gitomi/genesis"
assert_contains "$remote_refs" "refs/gitomi/inbox/alice/laptop"
(
  cd "$clear_remote/source"
  printf 'delete remote gitomi refs from origin\n' | gt reset remote --remote origin >/dev/null
)
remote_refs="$(git --git-dir="$clear_remote/remote.git" for-each-ref '--format=%(refname)' refs/gitomi)"
[[ -z "$remote_refs" ]] || fail "expected remote Gitomi refs to be deleted"$'\n'"$remote_refs"

