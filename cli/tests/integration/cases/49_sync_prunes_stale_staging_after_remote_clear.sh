#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="sync prunes stale staging after remote clear"
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

stale_root="$ROOT/stale-staging"
mkdir -p "$stale_root"
git -C "$stale_root" init --bare remote.git >/dev/null
init_repo "$stale_root/source"
init_repo "$stale_root/replica"
git -C "$stale_root/source" remote add origin "$stale_root/remote.git"
git -C "$stale_root/replica" remote add origin "$stale_root/remote.git"
(
  cd "$stale_root/source"
  gt init --repo-id "$REPO_ID" --principal alice --device laptop >/dev/null
  gt issue open --title "Stale staging issue" >/dev/null
  gt sync --push-only >/dev/null
)
(
  cd "$stale_root/replica"
  gt init --repo-id "$REPO_ID" --principal bob --device desktop >/dev/null
  if first_pull="$(gt sync --pull-only 2>&1)"; then
    fail "expected sync to reject conflicting genesis"
  fi
  assert_contains "$first_pull" "conflicting refs/gitomi/genesis"
  assert_contains "$first_pull" "refusing to admit inbox refs"
  staged_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/staging/origin)"
  assert_contains "$staged_refs" "refs/gitomi/staging/origin/genesis"
  refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/inbox)"
  [[ -z "$refs" ]] || fail "expected conflicting pull not to admit inbox refs"$'\n'"$refs"
  gt clear remote --yes >/dev/null
  second_pull="$(gt sync --pull-only 2>&1)"
  assert_contains "$second_pull" "no remote Gitomi genesis ref at origin"
  assert_contains "$second_pull" "no staged Gitomi inbox refs to admit"
  assert_not_contains "$second_pull" "conflicting refs/gitomi/genesis"
  staged_refs="$(git for-each-ref '--format=%(refname)' refs/gitomi/staging/origin)"
  [[ -z "$staged_refs" ]] || fail "expected stale staging refs to be pruned"$'\n'"$staged_refs"
)

